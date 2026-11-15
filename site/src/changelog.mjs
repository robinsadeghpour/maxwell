// Changelog entries, newest first. One entry per notable release or day of releases.
// Voice: Maxwell is the subject, present tense, short. Fixes start with a verb or "X now Y", no trailing period.
import * as fig from "./figures.mjs";
import { k } from "./build-helpers.mjs";

export default [
  {
    slug: "2026-11-15-groups-you-can-trust",
    date: "2026-11-15",
    versions: "0.1.35",
    title: "Working, Needs you and Your turn you can trust",
    figure: "",
    body: `
<p>Maxwell now takes each session's group from Claude Code itself. It reads what the process is doing and, for background sessions, how Claude Code says the last turn ended. Before, a session that had asked you to approve something stayed in <strong>Working</strong> for as long as a background shell it started kept running. It now shows in <strong>Needs you</strong>, in Claude Code's words: "open the Sentry sign-in link above, approve it, then tell me".</p>
<p>A session whose turn is over but whose background work is still running stays in Working. A line under its title says what it waits for. Hover that line on any session to see where its group came from. <code>Maxwell state</code> prints the same for every session.</p>`,
    fixes: [
      "Fixed idle sessions showing as Working when Claude Code expected more work later",
      "Fixed questions in a reply's body, such as an Open questions list, putting a session in Needs you when its status line said Safe to close or Not done",
      "Needs you now clears when the prompt is answered or the turn ends, even without a hook",
      "A turn that ends without a Stop hook (Esc, a queued prompt) no longer stays in Working",
      "Sessions in a repo's main checkout no longer fail worktree clean because of other sessions' worktrees in .claude/worktrees",
    ],
  },
  {
    slug: "2026-11-15-see-your-agents",
    date: "2026-11-15",
    versions: "0.1.34",
    title: "See the agents a session runs",
    figure: "",
    body: `
<p>When a session hands work to subagents, Maxwell now shows it. The row says <em>3 agents</em> (or <em>1 agent · 2 shells</em>), so a session that sits in <strong>Working</strong> tells you why.</p>
<p>The header gets a <strong>3 agents</strong> button. Hover it for what each agent is doing. Click it, or press ${k("⇧ ⌘ G")}, and Claude's own agent list opens in the terminal: pick one with ${k("↑")} ${k("↓")} and ${k("⏎")} to read its chat or message it.</p>`,
    fixes: [
      "Safe to close now names what it's waiting for, like \"2 subagents and 1 background shell running\"",
    ],
  },
  {
    slug: "2026-11-15-terminals-in-sidebar",
    date: "2026-11-15",
    versions: "0.1.33",
    title: "Terminals sit with your sessions",
    figure: "",
    body: `
<p>${k("⌥ ⌘ T")} now opens a terminal inside Maxwell, not in a window of its own. It gets a row under <strong>Terminals</strong> at the top of the sidebar and runs in the middle pane, like a session. The row shows the folder the shell is in, and follows it when you <code>cd</code>.</p>
<p>Open as many as you like: with <strong>new</strong> on the Terminals header, from ${k("⌘ K")}, or by right-clicking a session and choosing <strong>Open Terminal Here</strong>. ${k("J")} ${k("K")} and ${k("⌘ [")} ${k("⌘ ]")} step through them with your sessions. × on the row, ${k("⌘ W")} or <code>exit</code> ends one.</p>`,
    fixes: [
      "Fixed close all and stop all covering a row after launch",
      "Maxwell releases are now built, signed and notarized by GitHub Actions on a clean Mac, one release at a time",
    ],
  },
  {
    slug: "2026-11-15-update-from-the-dmg",
    date: "2026-11-15",
    versions: "0.1.30",
    title: "Updates work when Maxwell runs from the DMG",
    figure: "",
    body: `
<p>If you open Maxwell straight from the DMG without dragging it to Applications first, it runs from a disk macOS won't let it change. <strong>Restart to update</strong> then reopened the same old version and offered the same update again. Maxwell now installs the update into Applications and opens it from there.</p>
<p>Still on an older version and stuck like this? Quit Maxwell, drag it from the DMG to Applications, and open it from there. Updates work from then on.</p>`,
    fixes: [
      "Fixed Restart to update reopening the old version when Maxwell ran from the DMG",
      "Restart to update now says so when no Applications folder can be written, instead of quitting",
    ],
  },
  {
    slug: "2026-11-15-setup-and-all-projects",
    date: "2026-11-15",
    versions: "0.1.29",
    title: "Set up in one place, and All projects adds up",
    figure: fig.setup("Each step checks itself, and the list goes away when everything is done."),
    body: `
<p>With no session open, Maxwell now starts with <strong>Set up Maxwell</strong>. It checks four things: that Claude Code is installed, the session hooks, a claude.ai sign-in for each account so artifacts open beside the session, and notifications. Each step that's left has one button. Steps tick themselves off as you go, and the list goes away once everything is done. <strong>Hide</strong> puts it away early. Everything in it is also in Settings.</p>
<p><strong>All projects</strong> now lists every session, not only the ones waiting on you. Its count matches the bottom bar. Idle and Recently closed stay folded.</p>
<p>A new Maxwell often finds sessions from days ago that are still running. They fold into Idle, and its new <strong>stop all</strong> stops the background ones. Conversations are kept, and <strong>Undo</strong> brings them back. Rows of sessions running in another terminal now say so.</p>`,
    fixes: [
      "A question nobody answered for 3 days now folds into Idle instead of staying in Needs you",
      "The Dock badge now counts the Needs you group",
      "Maxwell now installs with Homebrew: brew install --cask robinsadeghpour/maxwell/maxwell",
    ],
  },
  {
    slug: "2026-11-15-your-own-names",
    date: "2026-11-15",
    versions: "0.1.28",
    title: "Keep the names you give your sessions",
    figure: "",
    body: `
<p>If you name your sessions yourself, turn off <strong>Settings › General › Sessions › Name sessions for me</strong>. Each session then shows what Claude Code shows: the name you gave it with <code>/rename</code>, or its own title. Haiku no longer titles it, and <strong>Bring into Maxwell</strong> keeps its name. <strong>Rename</strong> in Maxwell still works. The setting is on by default, so nothing changes unless you turn it off.</p>`,
    fixes: [
      "New config key: auto-titles",
    ],
  },
  {
    slug: "2026-11-15-terminal-window",
    date: "2026-11-15",
    versions: "0.1.27",
    title: "A plain terminal, one key away",
    figure: "",
    body: `
<p>${k("⌥ ⌘ T")} opens a plain terminal in the folder of the session you're looking at. Right-click any session and choose <strong>Open Terminal Here</strong> to open one in that session's folder.</p>
<p>Maxwell now finds <code>claude</code> wherever your shell does. Installs through npm, nvm, Volta or bun keep it outside the usual folders, and Maxwell then listed no background sessions. It now asks your login shell once. If it still can't find <code>claude</code>, it says so when it opens.</p>`,
    fixes: [
      "Fixed sessions missing from the list when claude was installed with npm, nvm, Volta or bun",
      "Maxwell state now prints the claude it uses and any account whose listing failed",
    ],
  },
  {
    slug: "2026-11-15-notification-sounds",
    date: "2026-11-15",
    versions: "0.1.26",
    title: "Pick a sound for each notification",
    figure: fig.notifications("Each notification has its own sound, and Settings shows whether macOS lets Maxwell notify."),
    body: `
<p><strong>Settings › General › Notifications</strong> now has two notifications, each with its own sound. <strong>Needs you</strong> is on as before. <strong>Turn finished</strong> is new: Maxwell tells you when a session stops and the next move is yours. Choose any macOS sound, or None. Picking one plays it.</p>
<p>Neither one shows for the session you're looking at. The notification sound now comes from Maxwell, so if you set up sounds in Claude Code hooks, you can remove them.</p>
<p>When macOS hasn't allowed Maxwell to notify, its notifications show Script Editor's icon and clicking one opens nothing. Settings now says so and opens <strong>System Settings › Notifications</strong> for you.</p>`,
    fixes: [
      "New config keys: notify-sound, notify-done and notify-done-sound",
    ],
  },
  {
    slug: "2026-11-15-bring-in-for-real",
    date: "2026-11-15",
    versions: "0.1.24 – 0.1.25",
    title: "Terminal sessions move into Maxwell",
    figure: fig.bringIn("A terminal session moves into Maxwell and keeps its conversation."),
    body: `
<p><strong>Bring into Maxwell</strong> now ends the session in your terminal before it continues in Maxwell. Recent Claude Code versions stopped recording which process runs a terminal session, so Maxwell couldn't find it, and the session carried on in Warp or Terminal while a second copy started in Maxwell. Maxwell's hook now notes the process itself.</p>
<p>When Claude Code hasn't been told it may work in a folder, ${k("⌘ T")} and New Session now ask <strong>Let Claude work in this folder?</strong>, the same question Claude asks in a terminal. Click <strong>Trust Folder</strong> and the session starts.</p>
<p>Slack and Linear now start off. Turn them on in <strong>Settings › Plugins</strong> when you want them.</p>`,
    fixes: [
      "Fixed Bring into Maxwell failing for sessions started in the home folder",
      "Fixed the \"Not trusted on default yet\" dead end on ⌘ T",
      "Messages name the account only when you have more than one",
      "When several Claude sessions run in the same folder and Maxwell can't tell which one to move, it says so and leaves them running",
      "Maxwell is now signed and notarized by Apple, so the download opens without the \"could not verify\" warning. Plugin keys ask for Keychain access once more after this update",
    ],
  },
  {
    slug: "2026-11-15-cleaner-panels",
    date: "2026-11-15",
    versions: "0.1.20 – 0.1.23",
    title: "Quieter plugin lists and a tidier Settings",
    figure: fig.panels(),
    body: `
<p>The Linear and Slack lists now read like lists. Ticket keys sit in their own dim column, so titles line up. A ticket with nothing to add is one line tall. Status badges are a dot and a word. A row's buttons show when the pointer is on it, so they no longer crowd the text.</p>
<p>Every Settings tab picks its options from one segmented control, and notes wrap instead of being cut off. Each plugin's description reads in full under its switch.</p>`,
    fixes: [
      "Fixed × on the System or Usage panel closing both. It now closes only its own panel. The bottom panels together still hide with ⌥⌘J",
      "Plugin panel section titles now match the other panel headers",
      "Plugin keys no longer ask for Keychain access again after every update. Allow it once more after this update and it sticks",
      "New session now lists each project's folder instead of its worktrees, and skips folders that no longer exist",
      "Safe to close no longer waits 2 hours. A finished session is safe as soon as every check passes, and the safe-after setting is gone",
    ],
  },
  {
    slug: "2026-11-15-status-line",
    date: "2026-11-15",
    versions: "0.1.19",
    title: "Every reply ends with where the session stands",
    figure: fig.wrapLine(),
    body: `
<p>Sessions now end each reply with a short status line: <strong>Safe to close</strong>, <strong>Not done</strong> or <strong>Needs you</strong>, and a few words on why. Maxwell shows the line on the session's row, so you can read where every session stands without opening it.</p>
<p>The line is also evidence. <strong>Needs you</strong> moves the session to Needs you. <strong>Not done</strong> keeps it out of Safe to close, whatever else passes. Maxwell gives each new session the rule through its SessionStart hook, so nothing changes in your prompts.</p>
<p>Turn it off with <code>wrap-line = off</code> in the config.</p>`,
    fixes: [
      "The installed hook now updates itself when Maxwell updates",
    ],
  },
  {
    slug: "2026-11-15-terminal-keys",
    date: "2026-11-15",
    versions: "0.1.15 – 0.1.18",
    title: "Terminal keys that work like Ghostty",
    figure: fig.keys(),
    body: `
<p>The terminal in Maxwell now edits the way Ghostty and Warp do. ${k("⌘ ⌫")} deletes to the start of the line, ${k("⌥ ⌫")} deletes a word, and ${k("⌘ V")} with a screenshot on the clipboard pastes it into Claude as an image.</p>
<p>Close Session moves to ${k("⇧ ⌘ ⌫")} to make room.</p>
<h3>Permission prompts are off for new sessions</h3>
<p>Sessions Maxwell starts or brings in now run with <code>--dangerously-skip-permissions</code> instead of auto mode, so they don't stop to ask before every command. Turn it off in <strong>Settings › General › Sessions</strong>, or with <code>skip-permissions = off</code> in the config.</p>`,
    fixes: [
      `${k("⌘ C")} in the terminal no longer clears Claude Code's highlighted selection`,
      "Fixed a white strip covering the title bar in full screen. Tabs, new session, search and settings stay visible",
      "Copied files paste as their paths, and files dropped on the terminal paste the same way",
    ],
  },
  {
    slug: "2026-11-15-plugins",
    date: "2026-11-15",
    versions: "0.1.14",
    title: "Plugins: Linear and Slack",
    figure: fig.plugins(),
    body: `
<p>Maxwell now has plugins, and two ship with it. They live in one <strong>Plugins</strong> panel (${k("⌥ ⌘ 6")}) with a tab each, and dock left, right or bottom like every other panel.</p>
<h3>Linear</h3>
<p>Each session's ticket and status show on its row, read from the branch name or the transcript. "Linear ticket done" joins the Safe to close checks, so a session isn't safe until its ticket is. When the work moves, Linear suggests the matching ticket move: In Progress when a session starts, a comment when the PR opens, Done when it merges.</p>
<h3>Slack</h3>
<p>Slack lists who is waiting on a reply from you: DMs, mentions and threads, with bugs and customers first. It only reads. <strong>Start Session</strong> starts a Claude session from a message and links the two, and that session isn't safe to close until you've replied in the thread.</p>
<h3>Write your own</h3>
<p>A plugin is a folder with a manifest and a program in any language. It talks to Maxwell with JSON lines over stdin and stdout, and Maxwell draws its panels with its own components, so every plugin looks native in every theme. A plugin that crashes is shown as stopped with a Restart button. It can't take Maxwell down. <a href="/docs/write-a-plugin">Read the plugin guide</a>.</p>`,
    fixes: [
      "Connect Slack with ⌘K › Connect Slack…, which opens Slack's app page with the manifest filled in",
      "Plugin secrets live in the Keychain and only the plugin that declared them can read them",
      `${k("⇧ ⌘ O")} opens the selected session's Linear ticket`,
    ],
  },
  {
    slug: "2026-11-14-artifacts",
    date: "2026-11-14",
    versions: "0.1.13",
    title: "Artifacts open beside the session",
    figure: fig.artifact(),
    body: `
<p>When a session publishes a claude.ai artifact, it now opens on the right, next to the session that made it, signed in as that session's account. Publishing again reloads it in place, even when it's pinned.</p>
<p>Each account signs in once, on claude.ai's own page, and keeps its own login. Maxwell already knows which account every session runs on, so it always picks the right one. ${k("⇧ ⌘ O")} opens the artifact in that account's browser profile or container instead.</p>
<h3>Bring terminal sessions into Maxwell</h3>
<p>A session running in another terminal now has a <strong>Bring into Maxwell</strong> button. Maxwell ends the terminal's process and resumes the same conversation as a background session, with the same id, account, folder and permission mode. A session in the middle of a turn moves when the turn ends. <strong>Session › Bring Terminal Sessions into Maxwell…</strong> moves all of them at once.</p>`,
    figure2: fig.bringIn(),
    fixes: [
      "Close any session from its right-click menu. If it isn't safe yet, Maxwell says what's still open and asks first",
      "Sessions named only by a slug or their first words get a readable name from Haiku, once, for about $0.0003",
      "Right-click a session to rename it. Your name always wins",
    ],
  },
  {
    slug: "2026-11-14-first-public-release",
    date: "2026-11-14",
    versions: "0.1.12",
    title: "Maxwell is public",
    figure: fig.launch(),
    body: `
<p>Maxwell is a native Mac app for running many Claude Code sessions at once. It reads what every session is doing, sorts them by what they need from you, and only calls a session safe to close when it can prove it.</p>
<p>The first public release covers the core: the six groups, projects on a Dock-style rail, the real Claude session attached in a Ghostty terminal, Markdown files rendered beside it, usage for every account, and search across everything with ${k("⌘ P")}.</p>
<h3>Safe to close means safe</h3>
<p>Unknown is never safe. A session needs proof that its task is finished: nothing running, two quiet hours, a last message that asks nothing, git clean and pushed, the PR merged. Then Haiku reads the last message once and has to answer <code>finished</code>. Closing only runs <code>claude stop</code>, with Undo for 10 seconds. <a href="/docs/safe-to-close">How Safe to close works</a>.</p>`,
    fixes: [
      "Updates come straight from GitHub's public releases. No GitHub login needed",
      "Needs a Mac with Apple silicon and macOS 14 or later",
      "Free and open source under the MIT licence",
    ],
  },
];
