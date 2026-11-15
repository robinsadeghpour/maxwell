// maxwell-hook: appends one line to ~/.local/state/maxwell/events.jsonl.
//
//   maxwell-hook               Claude Code hook: stdin is the hook payload. On
//                              SessionStart it also prints <state dir>/session-context.md.
//   maxwell-hook --statusline  status-line tap: stdin is the status-line JSON;
//                              keeps rate_limits and context_window, at most once
//                              per 30 s per account.
//
// It runs inside every Claude Code session on every hook, so it must be fast and
// must never fail the session: every path exits 0. Each line goes out in a single
// write() on an O_APPEND descriptor, so concurrent sessions never interleave lines.

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define MAX_PAYLOAD (512 * 1024)
#define USAGE_INTERVAL_S 30

static char payload[MAX_PAYLOAD + 1];
static char line[MAX_PAYLOAD + 4096];

static size_t read_stdin(void) {
    size_t n = 0;
    ssize_t r;
    while (n < MAX_PAYLOAD && (r = read(0, payload + n, MAX_PAYLOAD - n)) > 0) n += (size_t)r;
    if (n == MAX_PAYLOAD) {  // drain and drop oversized payloads
        char sink[65536];
        while (read(0, sink, sizeof sink) > 0) {}
        return 0;
    }
    payload[n] = 0;
    // Compact JSON has no raw newlines outside strings (inside strings they are
    // escaped), so dropping them keeps the payload valid and on one line.
    size_t w = 0;
    for (size_t i = 0; i < n; i++)
        if (payload[i] != '\n' && payload[i] != '\r') payload[w++] = payload[i];
    payload[w] = 0;
    return w;
}

// JSON-escapes s into out (quotes and backslashes; paths have nothing else).
static void escape(const char *s, char *out, size_t cap) {
    size_t w = 0;
    for (; *s && w + 2 < cap; s++) {
        if (*s == '"' || *s == '\\') out[w++] = '\\';
        out[w++] = *s;
    }
    out[w] = 0;
}

// Finds `"key":` at any depth and returns the span of its value (object or scalar).
static int value_span(const char *json, const char *key, const char **start, size_t *len) {
    char needle[64];
    snprintf(needle, sizeof needle, "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return 0;
    p += strlen(needle);
    while (*p == ' ' || *p == ':') p++;
    const char *s = p;
    if (*p == '{' || *p == '[') {
        int depth = 0, in_str = 0;
        for (; *p; p++) {
            if (in_str) {
                if (*p == '\\' && p[1]) p++;
                else if (*p == '"') in_str = 0;
            } else if (*p == '"') in_str = 1;
            else if (*p == '{' || *p == '[') depth++;
            else if ((*p == '}' || *p == ']') && --depth == 0) { p++; break; }
        }
    } else if (*p == '"') {
        for (p++; *p && *p != '"'; p++) if (*p == '\\' && p[1]) p++;
        if (*p) p++;
    } else {
        while (*p && *p != ',' && *p != '}') p++;
    }
    *start = s;
    *len = (size_t)(p - s);
    return *len > 0;
}

static void ensure_dir(const char *path) {
    char tmp[1024];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++)
        if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; }
    mkdir(tmp, 0755);
}

// True if the account's usage stamp is older than the interval (and touches it).
static int usage_due(const char *dir, const char *config_dir) {
    char stamp[1200], name[512];
    size_t w = 0;
    for (const char *s = config_dir; *s && w + 1 < sizeof name; s++)
        name[w++] = (*s == '/') ? '_' : *s;
    name[w] = 0;
    snprintf(stamp, sizeof stamp, "%s/usage-stamps/%s", dir, name);
    struct stat st;
    time_t now = time(NULL);
    if (stat(stamp, &st) == 0 && now - st.st_mtime < USAGE_INTERVAL_S) return 0;
    char sdir[1100];
    snprintf(sdir, sizeof sdir, "%s/usage-stamps", dir);
    ensure_dir(sdir);
    int fd = open(stamp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) close(fd);
    return 1;
}

// Claude Code adds SessionStart stdout to the session's context: Maxwell's rules for it.
static void print_context(const char *dir) {
    char path[1100], buf[16384];
    snprintf(path, sizeof path, "%s/session-context.md", dir);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return;
    ssize_t r;
    while ((r = read(fd, buf, sizeof buf)) > 0) {
        ssize_t wr = write(1, buf, (size_t)r);
        if (wr < 0) break;
    }
    close(fd);
}

int main(int argc, char **argv) {
    int statusline = argc > 1 && strcmp(argv[1], "--statusline") == 0;
    const char *home = getenv("HOME");
    if (!home) return 0;

    char dir[1024], log[1100], cdir_raw[1024], cdir[2048];
    const char *state = getenv("MAXWELL_STATE_DIR");
    if (state && *state) snprintf(dir, sizeof dir, "%s", state);
    else snprintf(dir, sizeof dir, "%s/.local/state/maxwell", home);
    snprintf(log, sizeof log, "%s/events.jsonl", dir);
    const char *cd = getenv("CLAUDE_CONFIG_DIR");
    if (cd && *cd) snprintf(cdir_raw, sizeof cdir_raw, "%s", cd);
    else snprintf(cdir_raw, sizeof cdir_raw, "%s/.claude", home);
    size_t cl = strlen(cdir_raw);
    while (cl > 1 && cdir_raw[cl - 1] == '/') cdir_raw[--cl] = 0;
    escape(cdir_raw, cdir, sizeof cdir);

    size_t n = read_stdin();
    if (n == 0 || payload[0] != '{') return 0;

    struct timeval tv;
    gettimeofday(&tv, NULL);
    long long ms = (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;

    int len;
    if (statusline) {
        ensure_dir(dir);
        if (!usage_due(dir, cdir_raw)) return 0;
        const char *rl = 0, *cw = 0, *sid = 0;
        size_t rll = 0, cwl = 0, sidl = 0;
        if (!value_span(payload, "rate_limits", &rl, &rll)) return 0;
        if (!value_span(payload, "context_window", &cw, &cwl)) { cw = "null"; cwl = 4; }
        if (!value_span(payload, "session_id", &sid, &sidl)) { sid = "null"; sidl = 4; }
        len = snprintf(line, sizeof line,
                       "{\"ts\":%lld,\"configDir\":\"%s\",\"usage\":{\"session_id\":%.*s,\"rate_limits\":%.*s,\"context_window\":%.*s}}\n",
                       ms, cdir, (int)sidl, sid, (int)rll, rl, (int)cwl, cw);
    } else {
        len = snprintf(line, sizeof line, "{\"ts\":%lld,\"configDir\":\"%s\",\"hook\":%s}\n", ms, cdir, payload);
    }
    if (len <= 0 || (size_t)len >= sizeof line) return 0;

    int fd = open(log, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) {
        ensure_dir(dir);
        fd = open(log, O_WRONLY | O_APPEND | O_CREAT, 0644);
    }
    if (fd >= 0) {
        ssize_t wr = write(fd, line, (size_t)len);
        (void)wr;
        close(fd);
    }

    const char *ev = 0;
    size_t evl = 0;
    if (!statusline && value_span(payload, "hook_event_name", &ev, &evl) && evl == 14 && memcmp(ev, "\"SessionStart\"", 14) == 0)
        print_context(dir);
    return 0;
}
