// Changelog entries, newest first. One entry per notable release or day of releases.
// Voice: Maxwell is the subject, present tense, short. Fixes start with a verb or "X now Y", no trailing period.
import * as fig from "./figures.mjs";
import { k } from "./build-helpers.mjs";

export default [
  {
    slug: "2026-11-27-one-row-of-tabs",
    date: "2026-11-27",
    versions: "0.1.84",
    title: "One row of tabs, and one way to go big",
    figure: "",
    body: `The viewer's tabs move up into the title bar, right of the line where the viewer begins, so the window has one row of tabs and the page starts right under it. ${k("⇧ ⌘ ↩")} fills the window with what you're in: the session, the viewer or a plugin panel. A double-click on a session's tab or a document's tab does the same (a double-clicked document is kept), and ${k("⇧ ⌘ ↩")} again brings the split back; ${k("Esc")} does too for the viewer or a plugin panel. Session tabs stay where they opened: a new one goes next to the tab on show, going back to one no longer moves it to the front, and in a narrow window the ones that don't fit wait in ${k("⌄")}. The viewer stays on the right, beside its session.`,
    fixes: [],
  },
  {
    slug: "2026-11-27-continue-on-another-account",
    date: "2026-11-27",
    versions: "0.1.82 – 0.1.83",
    title: "Limited sessions continue on another account, conversation and all",
    figure: "",
    body: "A session at its usage limit now continues on another account as the same session: same row, same name, pin and project, and the whole conversation. Maxwell stops it on its account, picks it up on the other one and sends \"continue\", so it carries on where the limit stopped it. Press ⇧⌘M or the banner's Continue on button for the account with the most room, pick another account from the ▾ beside it or under Continue on in a row's right-click menu, or press the Limited header's button to move every limited session in the list to the account with the most room.",
    fixes: [
      "Moving a session to another account no longer starts a new session that has to read the old one's transcript, and no longer leaves the old one behind at its limit",
      "With many accounts, the account choices in New session now wrap onto a second line instead of running off the panel's edge",
      "Limit reset times further away than today now show the day, like Mon 16:00, in the list and on Resume at. Before, a weekly limit showed only the time",
    ],
  },
  {
    slug: "2026-11-26-file-tree-look",
    date: "2026-11-26",
    versions: "0.1.81",
    title: "A file tree that looks like your editor's",
    figure: "",
    body: "The folder beside the viewer now looks like the project tree in VS Code, JetBrains IDEs and Warp: names in the system font, roomier rows, outlined folders and chevrons.",
    fixes: [],
  },
  {
    slug: "2026-11-26-edge-labels",
    date: "2026-11-26",
    versions: "0.1.80",
    title: "Panel names on the window's edge again",
    figure: "",
    body: "The buttons on the window's edge show each panel's full name again, written along the edge, with the Linear and Slack logos before theirs and the count of what needs you after it. Plugins can ship a logo of their own with the new icon field in plugin.json.",
    fixes: [],
  },
  {
    slug: "2026-11-26-whole-tab",
    date: "2026-11-26",
    versions: "0.1.79",
    title: "The tab on show is never cut off",
    figure: "",
    body: "",
    fixes: [
      "In a narrow viewer, the tab on show now fits the tab strip with its title shortened in the middle. Before, a long title, such as an artifact's, slid the tab off the strip's left edge and cut off the start of its name",
    ],
  },
  {
    slug: "2026-11-26-system-details",
    date: "2026-11-26",
    versions: "0.1.78",
    title: "Which session is using your Mac",
    figure: "",
    body: "Click the System panel, or choose Panels › System Details, and a card opens over it: the last five minutes of CPU for the whole Mac and for Claude Code, then every running session with the CPU and memory it uses, counting the commands and MCP servers it runs. Click a session to open it. The footer shows memory pressure and opens Activity Monitor.",
    fixes: [
      "The claude row in the System panel now counts the commands each session runs, as its tooltip always said",
    ],
  },
  {
    slug: "2026-11-26-calmer-home",
    date: "2026-11-26",
    versions: "0.1.77",
    title: "A calmer screen when no session is open",
    figure: "",
    body: "",
    fixes: [
      "With no session open, Maxwell now shows one centred column: what's left to set up, how many sessions need you, and two buttons, Next that needs you (⌘J) and New session (⌘N). Before, the pane listed every setup step including the finished ones, a row per state with zeros, and the same keys as the status bar",
      "Set up Maxwell now lists only the steps left. Finished steps fill the progress bar instead of taking a row each, and in a short window the steps that don't fit wait in Settings",
      "The count of sessions that need you on the empty screen now covers every project, as ⌘J and the status bar do, and says how many are in the project you're looking at. Before, it counted only that project, so it could say 1 while the status bar said 7",
    ],
  },
  {
    slug: "2026-11-26-tool-windows",
    date: "2026-11-26",
    versions: "0.1.76",
    title: "Tool windows, a better file tree, and artifacts full size",
    figure: "",
    body: "Each plugin's panel is now a tool window of its own, like in JetBrains IDEs: Linear and Slack each get a button beside the viewer, with a count of what needs you. The stripes of words down the window's sides are gone. A side only gets a slim row of icons when it holds two or more panels, Usage and System open from the status bar, and the title bar has a button for each side. Any panel can fill the window: press ⇧⌘↩, click ⤢ in its header, or double-click the header, so an artifact gets big without leaving Maxwell. The session's folder (⇧⌘T) now sits beside the page as a column you drag to size, follows files as they are written, previews a file on click and keeps it on double-click.",
    fixes: [
      "The folder no longer opens or closes by itself when the window gets wider or narrower",
    ],
  },
  {
    slug: "2026-11-26-newest-update",
    date: "2026-11-26",
    versions: "0.1.75",
    title: "Restart to update installs the newest release",
    figure: "",
    body: "",
    fixes: [
      "Restart to update now installs the newest release. Before, once an update had downloaded, Maxwell stopped looking: left open for days, it kept offering that first update while newer ones, with their fixes, came out",
      "Maxwell now deletes the updates it downloaded once they are installed or replaced. Before, each one stayed in the cache, about 45 MB each",
    ],
  },
  {
    slug: "2026-11-26-close-from-the-list",
    date: "2026-11-26",
    versions: "0.1.74",
    title: "⌘⌫ closes from the session list",
    figure: "",
    body: "",
    fixes: [
      "⌘⌫ now closes the session or terminal under the cursor in the session list. Before, the right-click menu showed ⌘⌫ beside Close Session, but only ⇧⌘⌫ closed one. In the terminal ⌘⌫ still deletes the line you're typing, and ⇧⌘⌫ closes from anywhere",
    ],
  },
  {
    slug: "2026-11-25-rail-keeps-projects",
    date: "2026-11-25",
    versions: "0.1.73",
    title: "Projects you keep stay on the rail",
    figure: "",
    body: "",
    fixes: [
      "Projects you keep in the rail now stay there even when none of their sessions ran this week. Before, a kept project with no recent sessions dropped off the rail",
      "A session in a folder outside any project, such as Downloads, now keeps its key on the rail while it is open. Before, the key went away once the session stopped needing you, and the session could only be found under All projects",
      "When the rail is too short for every key, Maxwell now keeps the open project and the ones waiting on you, and the rest stay in the ⋯ menu. Before, keys ran under the ⋯ key",
    ],
  },
  {
    slug: "2026-11-25-steady-usage",
    date: "2026-11-25",
    versions: "0.1.72",
    title: "Usage bars that hold still",
    figure: "",
    body: "",
    fixes: [
      "The usage bars now hold still. Before, they jumped back to an older number now and then, because every session reports the limits it last saw and an idle session sent its old ones again. Maxwell now keeps the newest reading for each 5-hour and weekly window",
    ],
  },
  {
    slug: "2026-11-20-voice-mode",
    date: "2026-11-20",
    versions: "0.1.70 – 0.1.71",
    title: "Answer your sessions out loud",
    figure: "",
    body: "Maxwell has a voice mode. Turn it on in Settings › Voice, press ⌃⌥M from any app, and an orb appears: when a session needs you, Maxwell says its name and what it asks, listens, and types your spoken reply into that session word for word, so it carries on without you touching the keyboard. Say skip, repeat or goodbye to steer it. Hearing happens on your Mac, with the speech model in macOS 26, and what you say is sent nowhere. The voice is your Mac's own, or an ElevenLabs voice once you paste an API key; then the lines Maxwell says go to ElevenLabs. <a href=\"/docs/voice\">How voice mode works</a>",
    fixes: [
      "The name, key and voice fields in Settings › Voice now have a Save button. Before, they saved on Return or a click elsewhere, and nothing said so",
    ],
  },
  {
    slug: "2026-11-20-terminal-keeps-focus",
    date: "2026-11-20",
    versions: "0.1.69",
    title: "Close without being asked",
    figure: "",
    body: "The question Maxwell asks before it closes a session that isn't safe to close now has a Don't ask again box. Tick it and close, and from then on every session closes at once, with the same Undo and the same seven days in Recently closed. Settings › General › Ask before closing unfinished sessions turns the question back on, as does <code>confirm-close = on</code> in the config file.",
    fixes: [
      "A plain terminal now keeps the keyboard while you type. Before, it lost it every time another session reported something, and you had to click into the terminal again",
    ],
  },
  {
    slug: "2026-11-20-usage-without-status-line",
    date: "2026-11-20",
    versions: "0.1.68",
    title: "Usage without a status line",
    figure: "",
    body: "",
    fixes: [
      "Usage now shows for an account that has no status line in Claude Code. Before, its 5-hour and weekly bars stayed empty, because Maxwell reads usage through the status line. Maxwell gives such an account a status line that shows nothing, and takes it out again on uninstall",
    ],
  },
  {
    slug: "2026-11-19-phone-live-activity",
    date: "2026-11-19",
    versions: "0.1.67",
    title: "Needs you on the iPhone's lock screen",
    figure: "",
    body: "Maxwell now keeps the iPhone app's Live Activity current: how many sessions need you, are your turn, are working and are limited, and when the next limit resets, on the lock screen and in the Dynamic Island, even while the app is closed. The counts go to Maxwell's relay unencrypted so it can push them to Apple; session names go too only if you show them in notifications. Turn it off in the phone's settings.",
    fixes: [],
  },
  {
    slug: "2026-11-19-phone-commands",
    date: "2026-11-19",
    versions: "0.1.65 – 0.1.66",
    title: "Messages from the phone after Stop",
    figure: "",
    body: "",
    fixes: [
      "A message sent from the phone right after stopping a turn now goes in on its own. Before, Claude Code had put the stopped prompt back and the message was added to it",
      "A plugin that crashes now always shows why: its last error line no longer goes missing when the Mac is busy",
      "Continue at reset from the phone now only applies to a limited session, and waits for the account's reset when the session's own isn't known. Before, it typed “continue” into any session a few seconds later",
    ],
  },
  {
    slug: "2026-11-19-resume-deleted-folder",
    date: "2026-11-19",
    versions: "0.1.64",
    title: "Resume works after a worktree is removed",
    figure: "",
    body: "",
    fixes: [
      "Fixed Resume on a stopped session whose folder was deleted, such as a worktree removed after its work merged. Claude Code refuses to wake it there, so Maxwell continues the conversation as a copy in the repository and opens it",
    ],
  },
  {
    slug: "2026-11-18-phone-bridge",
    date: "2026-11-18",
    versions: "0.1.63",
    title: "Settings › Phone",
    figure: "",
    body: `
<p>Maxwell can now pair with a phone. Settings › Phone shows a code to scan; once a phone is paired, it sees the same sessions as the Mac, follows a session's conversation and terminal, answers permission prompts, opens artifacts in the right account, starts, closes and moves sessions, and gets a push when a session needs you while you're away from the Mac.</p>
<p>The phone and the Mac meet on a small relay and everything between them is end-to-end encrypted; the relay forwards bytes it can't read. Maxwell connects to it only while a phone is paired or a code is showing, and <code>phone-relay = off</code> turns it off. The iPhone app is in private testing. <a href="https://github.com/robinsadeghpour/maxwell/blob/v1/docs/phone.md">How it works</a>.</p>`,
    fixes: [],
  },
  {
    slug: "2026-11-18-resume-from-any-folder",
    date: "2026-11-18",
    versions: "0.1.62",
    title: "/resume works across folders",
    figure: "",
    body: `
<p>Type <code>/resume</code> in a session and pick a conversation from another folder, and Maxwell now opens it. Claude Code can't switch folders inside a running session, so it only prints a <code>cd … &amp;&amp; claude --resume …</code> command to paste into a terminal. Maxwell reads that command off the session and runs it: the conversation resumes in its own folder as a background session and opens in the pane.</p>
<p>If the session you typed <code>/resume</code> in has no reply yet, Maxwell closes it, since it was only opened to get to the other one. A conversation Maxwell already lists is opened instead of started twice.</p>`,
    fixes: [],
  },
  {
    slug: "2026-11-16-cloud-sessions",
    date: "2026-11-16",
    versions: "0.1.50 – 0.1.61",
    title: "Cloud sessions",
    figure: "",
    body: `
<p>Maxwell now works with Claude Code sessions that run on Anthropic's cloud machines. They sit in the same groups as your other sessions, marked <strong>cloud</strong>, and a question from one shows in Needs you with a notification. Opening one shows its claude.ai page in the middle pane, signed in to its account.</p>
<p>${k("⌥ ⌘ N")} starts a session in the cloud from a project and a task. With <strong>Cloud</strong> picked, the new-session panel says what won't go along, such as commits that aren't pushed. ${k("⌥ ⌘ ↑")} sends a session from your Mac to the cloud: it commits, pushes and writes a brief, and a cloud session continues from there. ${k("⌥ ⌘ ↓")} brings a cloud session back into a fresh worktree. <a href="/docs/cloud">How cloud sessions work</a>.</p>`,
    fixes: [
      "A session you rename with <code>/rename</code> in Claude Code now shows that name within seconds, with Name sessions automatically on or off. Before, it kept its old title until the next prompt, and a one-word name was replaced by a Haiku title",
      "Fixed hovering over text in a session sending Claude Code stray pointer moves while Maxwell looked for a link",
      "A path's underline no longer stays behind under other text when output or scrolling moves the text under a resting pointer",
      "Maxwell now sends a report when it crashes or stops responding, scrubbed of paths, prompts and names, so crashes get fixed without anyone writing in. Settings › General › Send crash reports turns it off. <a href=\"/docs/privacy#crash-reports\">What a report holds</a>",
      "Clicking an artifact link in a session's terminal now opens it in the viewer the first time, also when Maxwell is in the background. Before, the first click only brought the window forward, and the next one counted as a double click and opened the link in the browser",
      "File paths in a session are now links: hover one and it's underlined, click it and the file opens in the viewer, no ⌘ needed",
      "The folder now fills a narrow viewer when no file is open, instead of leaving a dimmed empty strip beside it",
      "Terminals now come back after a restart, in the same folders and order, showing what they showed before, colours included, under a dim “restored” line; one whose folder is gone opens in the nearest folder still there",
      "Terminals can now be renamed: double-click a terminal's row, or right-click it and pick Rename…; the name stays after a restart",
      "Terminals now have tabs, like sessions, and closing a terminal's tab leaves it running in the sidebar",
      "Search (⌘P) now finds terminals by name and folder",
      "Rename… is now in the Session menu and in ⌘K, for the open session or terminal",
      "Closing a terminal now offers Undo, which brings back what it showed, and asks first when a command is still running in it, naming the command",
      "The window's corners are now round, instead of a stepped bevel inside the rim macOS draws",
    ],
  },
  {
    slug: "2026-11-15-safe-to-close-trusts-the-session",
    date: "2026-11-15",
    versions: "0.1.49",
    title: "Safe to close trusts the session's own word",
    figure: "",
    body: `
<p>When a session ends its reply with <strong>Safe to close</strong> and every other check passes (nothing running, git clean and pushed, the PR merged), it now goes straight to Safe to close. Before, Haiku read the reply once more and could hold it back as <em>unsure</em> or <em>pending</em> over a caveat or a note, and it answered differently for the same reply.</p>
<p>Replies without a status line still get the Haiku read.</p>`,
    fixes: [],
    fixes: [],
  },
  {
    slug: "2026-11-15-idle-sessions-free-their-memory",
    date: "2026-11-15",
    versions: "0.1.48",
    title: "Idle sessions free their memory",
    figure: "",
    body: `
<p>Claude Code stops a background session that has been idle for about an hour, to free memory, but only when no terminal is attached to it. Maxwell used to keep every session you opened attached until it quit, so none of them were ever stopped. Now Maxwell lets go of a session's terminal after 10 minutes off screen, and attaches again when you open it.</p>
<p>A session Claude Code stopped while it waited on you stays in Your turn or Needs you. Opening it shows its last reply and a Resume button, so moving through the list doesn't start every session it passes. ${k("⌘ R")} resumes it too. Its conversation is kept, as always.</p>`,
    fixes: [
      "Grey text is easier to read in every theme and now meets WCAG AA contrast",
      "A session waiting on you no longer disappears from the list when Claude Code stops it",
    ],
  },
  {
    slug: "2026-11-15-agents-waiting",
    date: "2026-11-15",
    versions: "0.1.47",
    title: "Agents that wait still count",
    figure: "",
    body: `
<p>A subagent can start a long command, end its turn and wait for it. Claude Code reports that as done for now, so Maxwell stopped counting the agent and the row lost its <em>agents</em> note while the agent was still at work. Maxwell now keeps counting it until the agent really finishes.</p>`,
    fixes: [
      "The header's agents button now stays at the right edge, so a long session title no longer hides it",
    ],
  },
  {
    slug: "2026-11-15-pin-and-mark-sessions",
    date: "2026-11-15",
    versions: "0.1.46",
    title: "Pin sessions, and overrule a verdict",
    figure: "",
    body: `
<p>Right-click a session and choose <strong>Pin to Top</strong>. Pinned sessions are listed first, under Pinned, and Close all leaves them alone.</p>
<p><strong>Mark As</strong> puts a session under Your turn, Safe to close or Idle when you disagree with Maxwell. The mark holds until the session's next turn. A session you mark safe says which checks still fail.</p>
<p>${k("⇧ ⌘ X")} now closes only the safe sessions of the project you're in, so a session from another project never lands in the list.</p>`,
    fixes: [
      "Sessions that started before Maxwell asked for the status line now get the request with your next prompt",
    ],
  },
  {
    slug: "2026-11-15-side-panels-are-tabs",
    date: "2026-11-15",
    versions: "0.1.45",
    title: "Side panels open one at a time",
    figure: "",
    body: `
<p>Panels on the same side now work like tabs. Opening the plugins panel closes the viewer beside it, and opening the viewer closes the plugins panel. The usage and system widgets at the bottom still sit side by side.</p>`,
    fixes: [],
  },
  {
    slug: "2026-11-15-open-a-folder-with-maxwell",
    date: "2026-11-15",
    versions: "0.1.44",
    title: "Start a session from any terminal's folder",
    figure: "",
    body: `
<p>Run <code>open -a Maxwell .</code> in any terminal, or drop a folder on Maxwell in the Dock, and the new-session panel opens with that folder picked. ${k("⏎")} starts the session there, so you don't need a terminal inside Maxwell to start in the right place.</p>`,
    fixes: [],
  },
  {
    slug: "2026-11-15-claude-in-a-maxwell-terminal",
    date: "2026-11-15",
    versions: "0.1.43",
    title: "Claude in a Maxwell terminal is one row",
    figure: "",
    body: `
<p>Run <code>claude</code> in a terminal you opened in Maxwell (${k("⌥ ⌘ T")}) and that terminal's row becomes the session's: its title, its group, Needs you and Your turn. Before, the terminal and the session showed up as two rows, and the session's pane was read-only even though it ran right there.</p>
<p>The pane shows the terminal, live, under the session's project, folder and branch. When Claude exits, the terminal's row comes back where it was. Sessions started in other terminal apps still show as <em>in a terminal</em> and can be brought in as before.</p>`,
    fixes: [
      "A session's row menu offers Close Terminal when it runs in a Maxwell terminal, instead of Bring into Maxwell",
    ],
  },
  {
    slug: "2026-11-15-panel-tabs-stay",
    date: "2026-11-15",
    versions: "0.1.42",
    title: "Panel tabs stay on the edge",
    figure: "",
    body: `
<p>Every panel now keeps its tab on the window's edge. An open panel's tab is lit. Click it to hide the panel, and click again to bring it back. Tabs no longer disappear when you open the panel they belong to.</p>`,
    fixes: [
      "Fixed the Viewer tab showing nothing when no file was open",
    ],
  },
  {
    slug: "2026-11-15-new-sessions-start-in-the-right-project",
    date: "2026-11-15",
    versions: "0.1.41",
    title: "New sessions start in the right project",
    figure: "",
    body: `
<p>${k("⌘N")} now starts with the project. Inside a project, it starts there and ${k("⏎")} goes. From All projects nothing is picked until you pick, so a session no longer lands in the folder of whatever you looked at last.</p>
<p>Type a few letters to find any project: the folders your sessions used, and every git repo in the usual places such as <code>~/projects</code>, <code>~/Developer</code> and <code>~/Documents/GitHub</code>, even ones no session has opened yet. ${k("↑")} ${k("↓")} move, and ${k("⌘O")} still picks any folder.</p>`,
    fixes: [
      "Maxwell now warns before starting a session in your home folder or a folder outside any project, where Claude would see everything below it",
    ],
  },
  {
    slug: "2026-11-15-groups-under-load",
    date: "2026-11-15",
    versions: "0.1.40",
    title: "Groups hold up when sessions get busy",
    figure: "",
    body: `
<p>Maxwell's groups now hold up when sessions run subagents, background shells and permission prompts. We ran scripted sessions through each case and compared Maxwell with Claude Code's own records every quarter second. Every group change now matches, and you get one notification per real change.</p>
<p>If Maxwell can't read Claude Code's own status for a session, the bottom bar now says <strong>! unverified</strong> instead of quietly guessing. <code>Maxwell watch</code> prints every group change as it happens, with where it came from.</p>`,
    fixes: [
      "Fixed a \"done\" notification while a subagent or background shell was still running",
      "Fixed the vaguer permission notification replacing the exact command a session asked to run",
      "Fixed a finished session with a dev server left running staying in Working",
      "Fixed file watchers counting as background work",
      "Fixed a usage limit from an earlier turn sticking after a clean turn",
      "A session that asks the same question again no longer notifies twice",
    ],
  },
  {
    slug: "2026-11-15-tabs-that-keep-your-place",
    date: "2026-11-15",
    versions: "0.1.39",
    title: "Viewer tabs that keep your place",
    figure: "",
    body: `
<p>Going back to a tab now puts you where you were in it. Files keep their scroll position, and the two artifacts you looked at last stay loaded, so switching between them is instant.</p>
<p>A tab that gets something new while you're reading another one shows a purple dot. When the tabs don't fit, ${k("⌄")} at the end of the strip lists them all and turns purple when one out of sight is new. ${k("⌥ ⌘ ←")} and ${k("⌥ ⌘ →")} step through the tabs, closing one takes you back to the tab you had before, and your tabs come back when Maxwell restarts.</p>
<p>The folder now sits beside the page when the viewer is wide. In a narrow viewer it slides over the page for one pick, so the page keeps its full height.</p>`,
    fixes: [
      "TSV and CSV files now show as a table",
      "Squeezed tabs keep their names readable and cut them in the middle, so the extension stays",
      "Plain text files wrap, and code in the light theme is easier to read",
      "An artifact link inside an artifact now opens as a tab of its own",
      "The viewer gets two thirds of the height when it shares the right side with another panel",
    ],
  },
  {
    slug: "2026-11-15-artifact-links-open-in-place",
    date: "2026-11-15",
    versions: "0.1.38",
    title: "Artifact links open beside the session",
    figure: "",
    body: `
<p>Clicking a claude.ai artifact link in a session's terminal now opens the artifact in the viewer, signed in to that session's account. Before, a plain click went to Claude Code, which opened the link in your default browser, and only ${k("⌘")}-click reached the viewer.</p>
<p>Other clicks still go to Claude Code as before, and dragging from a link still selects text.</p>`,
    fixes: [],
  },
  {
    slug: "2026-11-15-settings-you-can-read",
    date: "2026-11-15",
    versions: "0.1.37",
    title: "Settings you can read",
    figure: "",
    body: `
<p>Every page in Settings has been rewritten in plain words. Each setting now says what it is and what it does for you, with its switch or choice on the right. They're grouped under headings that say what the group is for. "Fold into Idle", "Final model check" and "Glass tint" are now "Move quiet sessions to Idle after", "Check finished work with Haiku" (with what it costs and what turning it off means) and "Opacity".</p>
<p>You can tell a setting's state at a glance. A switch that's off is an empty outline, and Reset shows only when you've changed a value. A theme fixed in your config file greys out the choices it overrides. Hooks are listed per account, and an account that shares another's settings.json says so. Plugins waiting for a key say "Not connected" and which key to paste.</p>
<p>Keys has a filter (${k("⌘ F")}). Projects shows each project's logo next to its name. Uninstalling hooks now asks first.</p>`,
    fixes: [
      "Settings no longer shift sideways when a scrollbar appears",
      "Install and uninstall hooks and Restart to Update no longer have a one-click Run button in Keys",
      "Advanced › Open guide now opens the settings reference, and the raw config dump is gone",
    ],
  },
  {
    slug: "2026-11-15-viewer-tabs",
    date: "2026-11-15",
    versions: "0.1.36",
    title: "The viewer has tabs",
    figure: "",
    body: `
<p>The viewer now keeps each session's files and artifacts in tabs, the way VS Code and Cursor do. Before, it showed one at a time.</p>
<p>A file the session opens goes into the preview tab, shown in italics, and its next file replaces it. Double-click the tab, or press ${k("⌥ ⌘ P")}, to keep it. While you're reading a tab you kept, new files wait in a tab behind it.</p>
<p>A path you ${k("⌘")}-click gets a tab of its own. Click × or middle-click to close a tab, or press ${k("⌘ W")} in the viewer. Drag tabs to reorder them, and right-click one for Close Others, Close All, Reveal in Finder and Copy Path.</p>`,
    fixes: [
      "The folder tree no longer squeezes in above an artifact",
      "The viewer's ⋯ and × now sit at the panel's right edge, after the tab's own buttons",
    ],
  },
  {
    slug: "2026-11-15-groups-you-can-trust",
    date: "2026-11-15",
    versions: "0.1.35",
    title: "Working, Needs you and Your turn you can trust",
    figure: "",
    body: `
<p>Maxwell now takes each session's group from Claude Code itself. It reads what the process is doing and, for background sessions, how Claude Code says the last turn ended. Before, a session that had asked you to approve something stayed in <strong>Working</strong> for as long as a background shell it started kept running. It now shows in <strong>Needs you</strong>, in Claude Code's words: "approve the staging deploy in the dashboard, then tell me".</p>
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
