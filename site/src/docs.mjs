// Docs pages, in sidebar order. Each page: one-sentence lede, then task-first sections.
// Headings are sentence case. Steps are numbered and name UI paths in bold.
import * as fig from "./figures.mjs";
import { k } from "./build-helpers.mjs";

const GH = "https://github.com/robinsadeghpour/maxwell";

export const sections = [
  { title: "Getting started", blurb: "Install Maxwell, connect it to Claude Code and open your first session.",
    pages: ["install", "first-session"] },
  { title: "Sessions", blurb: "How Maxwell sorts sessions, names them, and decides what's safe to close.",
    pages: ["groups", "safe-to-close", "session-names", "projects", "search"] },
  { title: "Workspace", blurb: "Panels, the viewer, artifacts, accounts and themes.",
    pages: ["panels", "viewer", "accounts", "appearance"] },
  { title: "Plugins", blurb: "Linear and Slack ship with Maxwell. Anyone can write another.",
    pages: ["linear", "slack", "write-a-plugin"] },
  { title: "Reference", blurb: "Every key, every config line, and what Maxwell touches on your Mac.",
    pages: ["keyboard-shortcuts", "configuration", "command-line", "privacy"] },
];

export const pages = {
  install: {
    title: "Install and update",
    lede: "Maxwell runs on a Mac with Apple silicon and macOS 14 or later. You also need Claude Code.",
    body: `
<h2>Install</h2>
<ol class="steps">
<li><a href="${GH}/releases/latest/download/Maxwell.dmg">Download Maxwell</a>, open the DMG and drag Maxwell to Applications. Older versions are on <a href="${GH}/releases">Releases</a>.</li>
<li>Maxwell isn't notarized by Apple yet, so macOS blocks it the first time. Open <strong>System Settings › Privacy &amp; Security</strong> and click <strong>Open Anyway</strong>, or run this once:<pre><code>xattr -dr com.apple.quarantine /Applications/Maxwell.app</code></pre></li>
<li>Choose <strong>Maxwell › Install Hooks</strong> (${k("⇧ ⌘ H")}). That's how Maxwell learns what your sessions are doing.</li>
</ol>
<p class="note">Install Hooks backs up each account's <code>settings.json</code> before it adds anything. <code>Maxwell uninstall-hooks</code> restores them exactly. See <a href="/docs/privacy">What Maxwell touches</a>.</p>
<h2>Updates</h2>
<p>Maxwell checks GitHub for a new release every few hours. When one is ready, the bottom bar shows <strong>Restart to update</strong>. Nothing changes until you click it. Then Maxwell quits, swaps in the new version and opens again.</p>
<p>Your Claude sessions keep running the whole time, because they are background sessions. <strong>Maxwell › Check for Updates…</strong> checks right away. Every release is listed in the <a href="/changelog">changelog</a>.</p>`,
  },

  "first-session": {
    title: "Start and bring in sessions",
    lede: "Sessions you start in Maxwell are Claude Code background sessions. They keep running when Maxwell closes or crashes.",
    figure: fig.bringIn("A terminal session moves into Maxwell and keeps its conversation."),
    body: `
<h2>Start a session</h2>
<p>${k("⌘ T")} starts a session in the folder of the project on screen, on the account with the most room. ${k("⌘ N")} asks for the folder and the account first.</p>
<p>Maxwell runs <code>claude --bg</code>, attaches the session in the middle pane, and selects it. Closing Maxwell detaches the terminal. The session goes on.</p>
<h2>Bring in a terminal session</h2>
<p>Sessions running in another terminal show up too, read-only. To move one into Maxwell, select it and click <strong>Bring into Maxwell</strong>. To move every one with a live process, choose <strong>Session › Bring Terminal Sessions into Maxwell…</strong>.</p>
<p>Maxwell ends the terminal's <code>claude</code>, waits for it to exit, and resumes the same conversation with <code>claude --bg --resume</code>, under the same id, account, folder and permission mode. A session in the middle of a turn moves when the turn ends.</p>
<h2>Permission prompts</h2>
<p>Sessions Maxwell starts or brings in run with <code>--dangerously-skip-permissions</code> by default, so they don't stop before every command. To keep Claude's own permission mode, turn off <strong>Settings › General › Sessions › Skip permission prompts</strong>, or add this line to the config:</p>
<pre><code>skip-permissions = off</code></pre>`,
  },

  groups: {
    title: "Session groups",
    lede: "Every session is in exactly one group, picked by what it needs from you. You only have to look at the first two.",
    figure: fig.groups(),
    body: `
<h2>The six groups</h2>
<table><thead><tr><th>Group</th><th>Meaning</th></tr></thead><tbody>
<tr><td>Needs you</td><td>The session asked you something or needs a permission. You get a notification.</td></tr>
<tr><td>Your turn</td><td>It answered and is waiting, or it offered a next step.</td></tr>
<tr><td>Working</td><td>It's running. Leave it alone.</td></tr>
<tr><td>Limited</td><td>It hit a usage limit. Resume when the window resets, or move it to the account with the most room.</td></tr>
<tr><td>Safe to close</td><td>Every check passed. Expand the row to see each one.</td></tr>
<tr><td>Idle</td><td>Stopped and quiet for a day. Folded away.</td></tr>
</tbody></table>
<h2>Move through sessions</h2>
<p>${k("J")} and ${k("K")} move up and down the list, and ${k("⏎")} opens a session. ${k("⌘ J")} jumps to the next session that needs you, across every project.</p>
<p>${k("⇧ ⌘ I")} shows or hides Idle. How long a stopped session waits before it folds into Idle is set by <code>idle-after</code>, 24 hours by default.</p>
<h2>Right-click a session</h2>
<p>The row menu opens, renames, moves the session to another project, brings it in from a terminal, or closes it.</p>`,
  },

  "safe-to-close": {
    title: "Safe to close",
    lede: "Closing a session that's still working, or waiting on you, costs you work. So Maxwell only calls a session safe when it can prove it.",
    figure: fig.safe("Each check says what it found and where the answer came from."),
    body: `
<h2>The rules</h2>
<ol class="steps">
<li><strong>Unknown is never safe.</strong> If Maxwell can't check something, the session isn't safe.</li>
<li><strong>It needs proof of a finished task.</strong> Nothing is running, including background tasks and subagents. The session has been quiet for 2 hours. Its last message asks nothing and offers nothing. Git is clean and pushed, and the PR is merged if there is one.</li>
<li><strong>A final read by a small model.</strong> Only for sessions that passed everything else, Haiku reads the last message once and has to answer <code>finished</code>. Each read costs about $0.0002.</li>
<li><strong>You see the evidence.</strong> Each safe session lists every check and where its result came from.</li>
<li><strong>Checked again at the moment of closing.</strong> If anything changed, that session is skipped.</li>
<li><strong>Closing never deletes.</strong> Maxwell only runs <code>claude stop</code>, which keeps the conversation.</li>
<li><strong>"Not safe" teaches it.</strong> Mark a wrong call and it becomes a test case, so the mistake can't repeat.</li>
</ol>
<h2>The status line</h2>
<p>Every new session is asked to end each reply with one line: <strong>Safe to close</strong>, <strong>Not done</strong> or <strong>Needs you</strong>, and a few words. Maxwell shows it on the row. <strong>Needs you</strong> moves the session to Needs you, and <strong>Not done</strong> keeps it out of Safe to close. A <strong>Safe to close</strong> line is one more piece of evidence, never enough alone. <code>wrap-line = off</code> turns it off.</p>
<h2>Close sessions</h2>
<p>${k("⇧ ⌘ X")} closes every safe session. It shows the list and asks first. ${k("⇧ ⌘ ⌫")} closes the selected session: at once when it's safe, otherwise after saying what's still open.</p>
<p>${k("⌘ Z")} undoes a close for 10 seconds. Anything closed in the last 7 days can be reopened from <strong>Recently closed</strong>.</p>
<h2>Plugin checks</h2>
<p>Plugins can add checks, and the same rules apply. A plugin that isn't running can't vouch, so its checks turn unknown. A check from before the session's last activity doesn't count. The Linear plugin adds "Linear ticket done". The Slack plugin adds "Replied on Slack" to sessions started from a message.</p>
<h2>Tune it</h2>
<pre><code>safe-after = 2h   <span class="c"># quiet time before a session can be safe</span>
judge = on        <span class="c"># off skips the model read, so nothing is ever safe</span></code></pre>
<p>Run <code>Maxwell state</code> in a terminal to audit every session and see which check holds each one back.</p>`,
  },

  "session-names": {
    title: "Session names",
    lede: "A session keeps Claude's title when that title says something. Otherwise Maxwell names the task once, so every row reads at a glance.",
    body: `
<h2>Where a name comes from</h2>
<p>Claude Code titles some sessions with only a slug (<code>acme-75</code>), something generic ("Continue Previous Task") or the first words of the prompt ("hi, do I need to do"). For those, Haiku reads the start of the session and names the task. It happens once per session and costs about $0.0003.</p>
<h2>Rename a session</h2>
<p>Right-click the row and choose <strong>Rename</strong>. Your name always wins. Maxwell never renames a session you named.</p>
<h2>See every title</h2>
<p><code>Maxwell titles</code> lists every session's title and where it came from: Claude, Haiku or you.</p>`,
  },

  projects: {
    title: "Projects and the rail",
    lede: "Each session belongs to a project, its git repo by default. A rail on the left, like the macOS Dock, switches between them.",
    figure: fig.rail("Pinned projects stay on the rail. Others appear when something there needs you."),
    body: `
<h2>Switch projects</h2>
<p>Rest the pointer at the left edge and the rail slides in. Click a project, or press ${k("⌘ 1")} to ${k("⌘ 9")}. ${k("⌘ 0")} shows every project. ${k("⌃ ⌘ P")} keeps the rail shown.</p>
<p>Pin the projects you work on, in <strong>Settings › Projects</strong> or with <code>project-pin</code> lines. Unpinned projects only appear on the rail while one of their sessions needs you.</p>
<h2>Logos</h2>
<p>Each project shows its own logo, redrawn in Maxwell's style. Maxwell looks in the project's folders for an app icon, an <code>apple-touch-icon</code>, an <code>icon</code>, a <code>logo</code> or a favicon, shallower first. With none, it draws a two-letter monogram. <strong>Settings › Projects › Choose…</strong> picks one by hand.</p>
<pre><code>project-logo-style = engraved   <span class="c"># engraved | pixel | monogram</span>
project-logo = Acme ~/projects/acme/apps/web/app/icon.png</code></pre>
<h2>Group folders into a project</h2>
<p>Worktrees count as their repo. To group other folders, add a <code>project</code> line with a path glob:</p>
<pre><code>project = Orbit ~/projects/orbit*</code></pre>
<h2>Move a session</h2>
<p>Right-click a session and choose <strong>Move to Project</strong>, or drag the row onto a project on the rail. When a session's transcript points at another project, its row suggests the move.</p>`,
  },

  search: {
    title: "Search and actions",
    lede: "One box finds any session, project or action. Press ⌘P, or Shift twice.",
    figure: fig.search(),
    body: `
<h2>Find a session</h2>
<p>${k("⌘ P")} or ${k("⇧ ⇧")} opens search. It matches a session's title, project, branch, account, last message and every file it touched. ${k("↑")} ${k("↓")} move, ${k("⏎")} opens, ${k("Esc")} or a click outside closes.</p>
<h2>Run an action</h2>
<p>${k("⌘ K")} shows actions only: every menu command, plus the actions plugins add. Each shows its shortcut, and every shortcut can be changed in <strong>Settings › Keys</strong>.</p>`,
  },

  panels: {
    title: "Panels and layout",
    lede: "Sessions, viewer, usage, system and plugins are panels. Each can sit left, right or bottom, and collapse to a stripe.",
    figure: fig.panels(),
    body: `
<h2>Move a panel</h2>
<p>Drag a panel's header to another side. A panel collapses to a thin stripe and opens again with one click. Panels remember their place on each screen, like tool windows in JetBrains IDEs.</p>
<h2>Toggle sides</h2>
<table><thead><tr><th>Key</th><th>Action</th></tr></thead><tbody>
<tr><td>${k("⌘ B")}</td><td>Left panels</td></tr>
<tr><td>${k("⌥ ⌘ B")}</td><td>Right panels</td></tr>
<tr><td>${k("⌥ ⌘ J")}</td><td>Bottom panels</td></tr>
<tr><td>${k("⌥ ⌘ 6")}</td><td>Plugins</td></tr>
</tbody></table>
<p>Prefer ${k("⌘ J")} for the bottom panel, VS Code style? Rebind it:</p>
<pre><code>keybind = cmd+j=toggle-bottom
keybind = cmd+shift+j=next-needs-you</code></pre>
<h2>The middle pane</h2>
<p>The middle is always the attached Claude session, in a Ghostty terminal. ${k("⌘ −")} and ${k("⌘ =")} change the terminal's text size without touching the rest of the window.</p>`,
  },

  viewer: {
    title: "Files and artifacts",
    lede: "Files and claude.ai artifacts a session writes open on the right, beside the session that made them.",
    figure: fig.artifact("An artifact opens signed in to the account its session runs on."),
    body: `
<h2>Markdown files</h2>
<p>When a session writes or mentions a Markdown file, it opens in the viewer, rendered. ${k("⌘")}-click any path in the terminal to open it. ${k("⌥ ⌘ P")} pins the current file so the next one doesn't replace it.</p>
<h2>Artifacts</h2>
<p>When a session publishes a claude.ai artifact, it opens in the viewer signed in as that session's account. Publishing it again reloads it in place, even when it's pinned. ${k("⌘")}-click an artifact link to open it the same way.</p>
<table><thead><tr><th>Key</th><th>Action</th></tr></thead><tbody>
<tr><td>${k("⌥ ⌘ R")}</td><td>Reload the artifact</td></tr>
<tr><td>${k("⇧ ⌘ O")}</td><td>Open it in the account's browser</td></tr>
<tr><td>${k("⌥ ⌘ P")}</td><td>Pin the file or artifact</td></tr>
</tbody></table>
<h2>Sign in once per account</h2>
<ol class="steps">
<li>Open <strong>Settings › Accounts</strong> (${k("⌘ ,")} then ${k("⌘ 3")}). Each account has a claude.ai row with the email it uses in Claude Code.</li>
<li>Click <strong>Sign in…</strong>. claude.ai's own page opens. Sign in with that email, using Google or email.</li>
<li>The window closes by itself and the row says <strong>Signed in</strong>. Repeat for your other accounts.</li>
</ol>
<p class="note">Sign in with Apple doesn't load inside Maxwell. If Google refuses the page, use "Continue with email". If the email has a sign-in link, copy it and click <strong>Paste link</strong> above the page.</p>
<p>Or skip Settings: the first artifact from an account shows <strong>Sign in to claude.ai</strong> right in the viewer. Logins stay separate and survive restarts. <strong>Sign out</strong> removes one.</p>
<h2>Open artifacts in a browser instead</h2>
<pre><code>artifacts = browser
browser = work firefox container Work   <span class="c"># &lt;account&gt; &lt;browser&gt; [profile|container &lt;name&gt;]</span></code></pre>
<p>Browsers: <code>default</code>, <code>zen</code>, <code>firefox</code>, <code>chrome</code>, <code>brave</code>, <code>edge</code>, <code>vivaldi</code>, <code>arc</code>, <code>safari</code>. Firefox-family profiles go by name, Chromium profiles by folder (<code>Default</code>, <code>Profile 1</code>).</p>`,
  },

  accounts: {
    title: "Accounts and usage",
    lede: "Maxwell reads every Claude Code account on your Mac and shows how much room each one has left.",
    figure: fig.usage(),
    body: `
<h2>Add an account</h2>
<p>Each account is a Claude Code config folder. Add one in <strong>Settings › Accounts</strong>, or with a line per account:</p>
<pre><code>account = work ~/.claude
account = personal ~/.claude-personal</code></pre>
<p>Run <strong>Maxwell › Install Hooks</strong> again after adding one, so its sessions report in.</p>
<h2>Usage</h2>
<p>The Usage panel shows 5-hour and weekly use for every account, with reset times. The System panel shows CPU and memory for your Claude processes.</p>
<p>New sessions from ${k("⌘ T")} go to the account with the most room. A session that hits its limit moves to <strong>Limited</strong>. Resume it when the window resets, or press ${k("⇧ ⌘ M")} to move it to the account with the most room.</p>`,
  },

  appearance: {
    title: "Themes and appearance",
    lede: "Themes come in a light and dark pair and follow macOS. Graphite, Silver and Paper ship with Maxwell.",
    body: `
<h2>Switch light and dark</h2>
<p>${k("⇧ ⌘ L")} switches between the pair, or use <strong>View › Appearance</strong>: Light, Dark, Follow System.</p>
<pre><code>appearance = system      <span class="c"># system | light | dark</span>
theme-light = paper      <span class="c"># paper | silver-light | your own</span>
theme-dark = graphite    <span class="c"># graphite | silver | your own</span></code></pre>
<h2>Glass</h2>
<p><strong>Settings › Appearance</strong> has sliders for the glass tint and blur. They preview live. Panes with text never go below 72% tint, so text stays readable at either extreme.</p>
<pre><code>background-opacity = 0.74   <span class="c"># 0.3 … 1</span>
background-blur = 20        <span class="c"># 0 (clear) … 64</span>
motion = on                 <span class="c"># off: no slides or fades</span></code></pre>
<h2>Your own theme</h2>
<p>Themes are small token files. Copy one from <a href="${GH}/tree/main/Resources/themes">Resources/themes</a> into <code>~/.config/maxwell/themes/</code>, change it, and name it in <code>theme-light</code> or <code>theme-dark</code>.</p>
<h2>App icon</h2>
<p><strong>Settings › Appearance</strong> shows every app icon as a picture. <code>auto</code> follows the appearance.</p>`,
  },

  linear: {
    title: "Linear",
    lede: "The Linear plugin shows which ticket each session works on, and keeps its status current.",
    figure: fig.linear("Suggested moves come first. One click each."),
    body: `
<h2>Connect</h2>
<ol class="steps">
<li>In Linear, open <strong>Settings › Security &amp; access</strong> and create a personal API key.</li>
<li>In Maxwell, paste it in <strong>Settings › Plugins › Linear › API key</strong>. It's stored in the Keychain, and only this plugin can read it.</li>
</ol>
<p>Without a key the plugin still shows ticket ids from branch names, and adds no check.</p>
<h2>How a session links to a ticket</h2>
<p>First by branch: <code>robin/acme-56-billing-totals</code> is ACME-56. Linear's own branch format works, or any branch segment that starts with one of your team keys. When the branch says nothing, the plugin reads the transcript and links the ticket the session clearly worked on.</p>
<h2>What it shows</h2>
<ul>
<li><strong>Row badge</strong>, like <code>ACME-56 · In Progress</code>. Green when done, amber when a move is suggested. Click opens the ticket, and so does ${k("⇧ ⌘ O")}.</li>
<li><strong>Safe to close</strong> gets "Linear ticket done". It passes when the ticket is Done, Canceled or Duplicate.</li>
<li><strong>Linear panel</strong>: suggested moves first, then your tickets by status. Each line says how its sessions stand.</li>
</ul>
<h2>Status moves</h2>
<table><thead><tr><th>When</th><th>It suggests</th></tr></thead><tbody>
<tr><td>A session works on a ticket in Backlog or Todo</td><td>Move to In Progress</td></tr>
<tr><td>The session's PR is open</td><td>Comment with the PR link</td></tr>
<tr><td>The PR merged and the ticket isn't done</td><td>Move to Done</td></tr>
</tbody></table>
<pre><code>linear.sync = suggest    <span class="c"># suggest | auto | off</span>
linear.writes = live     <span class="c"># dry-run logs moves instead of sending them</span></code></pre>`,
  },

  slack: {
    title: "Slack",
    lede: "The Slack plugin lists who is waiting on a reply from you. It reads only, and never posts, reacts or drafts.",
    figure: fig.plugins(),
    body: `
<h2>Connect</h2>
<ol class="steps">
<li>Press ${k("⌘ K")} and choose <strong>Connect Slack…</strong>. Slack's "create app" page opens with the manifest filled in: a user token with read-only scopes, no bot, no events.</li>
<li>Click <strong>Create</strong>, then <strong>Install to Workspace</strong>. If your workspace needs an admin to approve apps, they approve it there.</li>
<li>Copy the <strong>User OAuth Token</strong> (<code>xoxp-…</code>) from OAuth &amp; Permissions into <strong>Settings › Plugins › Slack</strong>. Maxwell keeps it in the Keychain.</li>
</ol>
<h2>The list</h2>
<ul>
<li><strong>Answer first</strong>: bugs, customers, and anyone who asked again.</li>
<li><strong>Questions and requests</strong>: everything else that waits on you, oldest first.</li>
<li><strong>You said you'd do it</strong>: you replied "on it" or reacted 👀. It comes back on top if they ask again.</li>
</ul>
<p>Click a row to open the message in Slack. <strong>Handled</strong> hides it until they write again. ${k("⇧ ⌘ S")} opens the next message waiting on you.</p>
<h2>Start a session from a message</h2>
<p><strong>Start Session</strong> starts a Claude session with the message, its thread and the link, and links the two. The session row shows <strong>Slack · Mara</strong>, and its Safe to close list gets <strong>Replied on Slack</strong>, which fails until you've answered in that thread. When the session finishes, the row moves to the top as <strong>Session done, reply</strong>.</p>
<p class="note">The plugin's Slack client allows five read methods and throws on anything else before a request is made. Handled and snooze marks live on your Mac, never in Slack.</p>`,
  },

  "write-a-plugin": {
    title: "Write a plugin",
    lede: "A plugin is a folder with a manifest and a program, in any language. It talks to Maxwell with JSON lines over stdin and stdout.",
    body: `
<h2>What a plugin can add</h2>
<table><thead><tr><th>Where</th><th>What</th></tr></thead><tbody>
<tr><td>Session row</td><td>Badges, like <code>ACME-56 · In Progress</code>, with tooltip fields</td></tr>
<tr><td>Safe to close</td><td>Checks, shown with the built-in ones</td></tr>
<tr><td>Menus, ⌘K, keys</td><td>Actions, global or per session</td></tr>
<tr><td>Panels</td><td>Lists and empty states, drawn natively</td></tr>
<tr><td>Notifications</td><td>A macOS notification</td></tr>
<tr><td>Settings</td><td>Fields and secrets</td></tr>
</tbody></table>
<p>There's no HTML and no custom drawing. A panel is data, sections of rows, and Maxwell draws it with the same components as the rest of the window, in every theme.</p>
<h2>The folder</h2>
<pre><code>~/.config/maxwell/plugins/hello/
  plugin.json    <span class="c"># the manifest: id, settings, actions, panels</span>
  hello          <span class="c"># the program: a binary, or a script with a #! line</span></code></pre>
<p>Installing is copying the folder in. Maxwell picks it up without a restart. A user plugin with the same id replaces a bundled one.</p>
<h2>The wire</h2>
<p>Newline-delimited JSON-RPC 2.0. Maxwell sends <code>initialize</code>, then <code>sessions/changed</code> with every session. The plugin answers with <code>session/annotate</code>, <code>panel/set</code> and <code>notify</code>.</p>
<pre><code>→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{…}}
← {"jsonrpc":"2.0","id":1,"result":{}}
→ {"jsonrpc":"2.0","method":"sessions/changed","params":{…}}
← {"jsonrpc":"2.0","method":"session/annotate","params":{…}}</code></pre>
<h2>When it fails</h2>
<p>A plugin that exits, hangs or floods is shown as stopped, its checks turn unknown, and Maxwell restarts it after 1, 5 and 30 seconds. After three failures in five minutes it stays stopped, with <strong>Restart</strong> and <strong>Open Log</strong> in Settings › Plugins.</p>
<h2>Start from the example</h2>
<p><a href="${GH}/tree/main/examples/plugins">examples/plugins/hello</a> is a complete plugin in Python. It badges every session with its branch and adds a panel and an action. The full protocol is in <a href="${GH}/blob/main/docs/plugins.md">docs/plugins.md</a>.</p>`,
  },

  "keyboard-shortcuts": {
    title: "Keyboard shortcuts",
    lede: "Every action has a key, and every key can be changed in Settings › Keys or with a keybind line.",
    body: `
<h2>Sessions</h2>
<table><thead><tr><th>Key</th><th>Action</th></tr></thead><tbody>
<tr><td>${k("⌘ P")} or ${k("⇧ ⇧")}</td><td>Search sessions, projects and actions</td></tr>
<tr><td>${k("⌘ K")}</td><td>Actions only</td></tr>
<tr><td>${k("J")} ${k("K")}, ${k("⏎")}</td><td>Move through sessions, open one</td></tr>
<tr><td>${k("⌘ J")}</td><td>Next session that needs you</td></tr>
<tr><td>${k("⌘ T")}</td><td>New session in the current folder, on the account with the most room</td></tr>
<tr><td>${k("⌘ N")}</td><td>New session, choosing folder and account</td></tr>
<tr><td>${k("⇧ ⌘ ⌫")}</td><td>Close the session: at once when it's safe, otherwise after saying what's still open</td></tr>
<tr><td>${k("⇧ ⌘ X")}</td><td>Close all safe (asks first)</td></tr>
<tr><td>${k("⌘ Z")}</td><td>Undo the last close</td></tr>
<tr><td>${k("⇧ ⌘ I")}</td><td>Show or hide Idle</td></tr>
<tr><td>${k("⇧ ⌘ M")}</td><td>Move a limited session to the account with the most room</td></tr>
</tbody></table>
<h2>Projects</h2>
<table><thead><tr><th>Key</th><th>Action</th></tr></thead><tbody>
<tr><td>${k("⌘ 0")}</td><td>All projects</td></tr>
<tr><td>${k("⌘ 1")} – ${k("⌘ 9")}</td><td>One project</td></tr>
<tr><td>${k("⌃ ⌘ P")}</td><td>Keep the projects rail shown</td></tr>
</tbody></table>
<h2>Terminal</h2>
<table><thead><tr><th>Key</th><th>Action</th></tr></thead><tbody>
<tr><td>${k("⌘ ⌫")}</td><td>Delete to the start of the line</td></tr>
<tr><td>${k("⌥ ⌫")}</td><td>Delete a word</td></tr>
<tr><td>${k("⌘ V")}</td><td>Paste text, copied files as paths, or a screenshot as an image</td></tr>
<tr><td>${k("⌘ −")} ${k("⌘ =")}</td><td>Terminal text size</td></tr>
</tbody></table>
<h2>Panels and viewer</h2>
<table><thead><tr><th>Key</th><th>Action</th></tr></thead><tbody>
<tr><td>${k("⌘ B")}, ${k("⌥ ⌘ B")}, ${k("⌥ ⌘ J")}</td><td>Toggle left, right, bottom panels</td></tr>
<tr><td>${k("⌥ ⌘ 6")}</td><td>Plugins panel</td></tr>
<tr><td>${k("⌥ ⌘ P")}</td><td>Pin the current file or artifact</td></tr>
<tr><td>${k("⌥ ⌘ R")}</td><td>Reload the artifact</td></tr>
<tr><td>${k("⇧ ⌘ O")}</td><td>Open the artifact in the account's browser, or the session's Linear ticket</td></tr>
<tr><td>${k("Esc")}</td><td>Close search, the palette or a panel</td></tr>
</tbody></table>
<h2>App</h2>
<table><thead><tr><th>Key</th><th>Action</th></tr></thead><tbody>
<tr><td>${k("⇧ ⌘ L")}</td><td>Switch light and dark</td></tr>
<tr><td>${k("⌘ ,")}</td><td>Settings (${k("⌘ 1")} – ${k("⌘ 7")} for each section)</td></tr>
</tbody></table>
<h2>Change a key</h2>
<p>In <strong>Settings › Keys</strong>, click a shortcut and press the new keys. ${k("⌫")} clears it, ${k("Esc")} cancels. It writes a line to the config. <code>none</code> removes a default.</p>
<pre><code>keybind = cmd+shift+n=new-session</code></pre>`,
  },

  configuration: {
    title: "Configuration",
    lede: "One plain text file, one key = value per line. Maxwell reloads it the moment you save, and the Settings window writes the same file.",
    body: `
<h2>Where it lives</h2>
<pre><code>~/.config/maxwell/config</code></pre>
<h2>Common keys</h2>
<pre><code>appearance = system           <span class="c"># system | light | dark</span>
theme-light = paper
theme-dark = graphite
font-size = 13                <span class="c"># lists, panels and the viewer</span>
terminal-font-size = 12       <span class="c"># ⌘− and ⌘= change this one</span>
account = work ~/.claude      <span class="c"># &lt;name&gt; &lt;CLAUDE_CONFIG_DIR&gt;, one line per account</span>
project-pin = Acme            <span class="c"># projects kept on the rail, in order</span>
rail = auto                   <span class="c"># auto slides in at the left edge, shown keeps it visible</span>
safe-after = 2h               <span class="c"># quiet time before a session can be safe to close</span>
idle-after = 24h              <span class="c"># quiet time before a stopped session folds into Idle</span>
judge = on                    <span class="c"># off skips the model read, so nothing is ever safe</span>
skip-permissions = on         <span class="c"># off keeps Claude's own permission mode</span>
wrap-line = on                <span class="c"># off: replies don't end with a status line</span>
notify = true
auto-open = true              <span class="c"># open .md files and artifacts a session writes</span>
artifacts = viewer            <span class="c"># viewer | browser</span></code></pre>
<h2>Plugin settings</h2>
<p>Each plugin's settings are lines named after it. Secrets such as API keys go in the Keychain, never here.</p>
<pre><code>linear.enabled = true
linear.sync = suggest</code></pre>
<p>The full list of keys, with defaults, is in <a href="${GH}/blob/main/docs/config.md">docs/config.md</a>.</p>`,
  },

  "command-line": {
    title: "Command line",
    lede: "The Maxwell binary answers a few commands in a terminal, for auditing and undoing.",
    body: `
<p>Run them with the binary inside the app:</p>
<pre><code>/Applications/Maxwell.app/Contents/MacOS/Maxwell state</code></pre>
<table><thead><tr><th>Command</th><th>What it does</th></tr></thead><tbody>
<tr><td><code>state</code></td><td>Every session by group, and for each stopped one, every Safe to close check with its result and source</td></tr>
<tr><td><code>titles</code></td><td>Every session's title and where it came from</td></tr>
<tr><td><code>accounts</code></td><td>The accounts Maxwell knows and their config folders</td></tr>
<tr><td><code>install-hooks</code></td><td>The same as Maxwell › Install Hooks</td></tr>
<tr><td><code>uninstall-hooks</code></td><td>Restores each account's settings from the backup</td></tr>
</tbody></table>`,
  },

  privacy: {
    title: "What Maxwell touches",
    lede: "Everything stays on your Mac. Maxwell sends nothing anywhere, apart from the Haiku reads, which go through your own Claude account, and what plugins you turn on.",
    figure: fig.pipeline("Hooks write one log. One pure reducer turns it into the state of every session."),
    body: `
<h2>Files and settings</h2>
<table><thead><tr><th>What</th><th>Where</th><th>Undo</th></tr></thead><tbody>
<tr><td>Hook entries for 6 events</td><td>each account's <code>settings.json</code>, backed up first</td><td><code>uninstall-hooks</code></td></tr>
<tr><td>One line that samples usage</td><td>your status-line script, backed up first</td><td>same</td></tr>
<tr><td>The hook program</td><td><code>~/.local/share/maxwell/</code></td><td>delete the folder</td></tr>
<tr><td>Event log</td><td><code>~/.local/state/maxwell/events.jsonl</code></td><td>delete the folder</td></tr>
<tr><td>Config</td><td><code>~/.config/maxwell/config</code></td><td>delete the file</td></tr>
<tr><td>claude.ai logins</td><td>Maxwell's own WebKit storage, one per account</td><td>Settings › Accounts › Sign out</td></tr>
<tr><td>Plugins</td><td><code>~/.config/maxwell/plugins/</code></td><td>delete the folder</td></tr>
<tr><td>Plugin secrets</td><td>Keychain, "Maxwell plugin &lt;id&gt;"</td><td>Settings › Plugins › Remove</td></tr>
</tbody></table>
<h2>How it works</h2>
<p>Hooks append each session event to one log file, from every account, whether Maxwell is open or not. The hook is a small C program that takes about 2 ms and always exits 0, so it can never block Claude Code.</p>
<p>One pure reducer turns that log into the state of every session. The app folds it at launch and follows it live. Nothing else changes session state.</p>
<h2>What leaves your Mac</h2>
<ul>
<li><strong>Haiku reads</strong>, through your own Claude account: the final Safe to close check, and names for sessions without a readable title.</li>
<li><strong>Linear</strong>, once you add a key: reads tickets and makes the moves you accept.</li>
<li><strong>Slack</strong>, once you add a token: reads your DMs, mentions and threads.</li>
</ul>`,
  },
};
