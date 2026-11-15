# Design direction

Only what Robin has said or picked. Each entry has his words and the reason. Newest first.

## 13 Nov 2026, late night: picked the Slack-style rail (variant A), with changes

- **Rail: yes to the idea, no to how it was drawn.** "I like the slack rail on the left, though the way you designed it doesn't fit the rest, like it wastes a lot of space ... doesn't fit the rest of the style with the roundness".
  So: a narrow rail in the same density, hairlines and corner radius as the rest; no big rounded tiles, no extra padding.
- **Behaves like the macOS Dock.** It shows when the mouse goes to that edge, and each project can be pinned or not. "usually I just work on one project and I don't need to see all of them all the time. But ... different users might ... just pin or not pin like similar to how a dock works on Mac or Windows."
- **Project logos, restyled.** "add like logos, or if it smartly could understand the logos of the projects ... not the PNGs or SVGs as is, but fitting the style and the theme and the glassy look."
- **Smart search** to find the right session.
- **Details: "smooth transitions and animations, scrollbar nice".**
- **The vertical usage meter is ugly** (`references/rejected-usage-meter.png`).
- **Tool windows left, right and bottom, movable, like JetBrains or VS Code.** "You can even move the bottom to the right." A toggleable bottom panel for RAM/CPU, account usage, "more ways to show things".

## 13 Nov 2026, night: "safe to close" must be trustworthy

- **"I need to be able to trust this thing because otherwise I'm going to close a session that's working or that still needs things ... super painful ... safe to close needs to really really be safe to close."**
  So: unknown is never safe; every check shown as evidence; re-checked at the moment of closing; closing only stops the session (`claude stop`, conversation kept) with Undo and a Recently closed list to reopen; a "Not safe" button records false positives as tests.

## 13 Nov 2026, night: learn layout and window management from IDEs

- **"we can learn also a lot from IDEs like the jetbrains ones in terms of layout and window management, also warp isnt too bad, cursor, vim"**; "I always loved jetbrains but stopped using them since claude code and cursor"; "not saying we should take their style ... but layouts, window management".
  So: borrow structure, not looks. JetBrains tool windows (dock, collapse to a stripe, float, tear off; saved layouts; Search Everywhere, Recent, Switcher), Warp's blocks, panes and launch configs, Cursor's panels, and vim/tmux keyboard-first splits.

## 13 Nov 2026, evening: from the voice interview (full answers in INTERVIEW.md)

- **Scope: small first.** "just the main issues, fix them, and then iterate from there", or "we might end up building too much that starts annoying me".
  So: v1 is orchestration only (Q11). Everything else in the interview is backlog.
- **The v1 job, in his words:** "which session was working on which feature ... who is waiting on what? which sessions can I close? which account should I use? ... together with Slack, who is waiting for me ... have I replied everybody".
- **Files open on the right, by themselves.** "if Claude needs to show me a thing, just open it on the right. In the same thing on the right." Never in Xcode or another app. He rarely reads or corrects plans; no hunting through a file tree ("I would never do that").
- **Done = one glance.** "even just the color ... there's nothing left for me here ... the ticket in Linear is done": live, no open questions, no follow-ups, ticket closed.
- **Notifications:** native Mac notifications are enough for v1 ("serves its purpose"). Notch and phone come later.
- **Choices between options:** "I'm a very visual person": show visual choices as artifacts side by side.

## 13 Nov 2026, late: picked the icon

- **Pixel demon (round 2, #2), in a light and a dark version.** Square ink pixels on a flat material, no gradients. "yup its great!!"
- **The icon is a setting:** all six variants ship (light silver, dark gunmetal, paper, graphite, amber eyes on each) and users pick one in Settings.

## 13 Nov 2026, late: reaction to the first five icon concepts

- **Favourites: Silver and Paper.** "phosphor one kinda but not in that colors."
- **Throw out the Phosphor theme.**
- **"The gradients look really cheap somehow, I see just lots of circles."** So: no glossy gradients and no circles. Flat materials (paper grey, brushed silver as fine line texture), square pixels, hairlines, engraving.
- **Direction for the next round:** "technical and silver and paper themed, arch linux like."

## 13 Nov 2026, late: windows and a name

- **Pop-out windows:** "we can think have poppable windows because I have multiple monitors etc to be flexible." So: any tab or pane (a session, the queue, tasks) can be torn off into its own window, like dragging a tab out in Ghostty or a browser, and layouts per monitor are remembered.
- **Name:** asked for "a cool niche reference name ... it's not purely a terminal." Open; candidates offered, his to pick.

## 13 Nov 2026, late: the goal behind the UI

- **"maybe we can create like an agent or many agents or meta agents that oversee the other Claude sessions"**, built from understanding "how I work ... the way I think ... what my taste is", by going through his sessions and interviewing him.
- **The goal:** "make it easier for me to work on multiple tasks in parallel while every bit of it or every output is still great or at least at the same quality or even better quality." Even at 20 things in parallel, a UI alone may not be enough to keep the overview.
- **Scope:** "we don't need to build the perfect thing right now ... if we get a solid base and can customize it ... over time, even that's great."
  So: the product is a supervisor that knows his rules and taste, with the Workbench as its surface for what still needs him. Start small and make it his to tune.

## 13 Nov 2026, late: on the Ghostty pass, and what the tool is for

- **Feel: "goes into the right direction but not quite there yet."**
- **The real question: "is this the best world class thing to make it super optimal for me to scale doing even more in parallel?"** and "how much can I work in parallel on tasks with low mental brain load being used to keep track?"
  So: judge every design by how little Robin has to keep in his head, not by how it looks. The tool keeps track; he only sees what needs him.
- **Colour coding by state:** "session is done and can be closed safely, session is working, session needs input."
- **Customisation:** "as for terminals we can introduce customization and theme options." Themes, glass amount, font and size are settings, like a terminal's config.
- Asked for research "with a world class product team": which other fields and products solve the same problem (one person, many parallel processes), productivity apps or beyond.

## 13 Nov 2026, night: picked Workbench from the compact round

- **"now more terminal ghostty look of workbench bit glassy"**
  So: Workbench (sessions | terminal | tasks) is the layout. Push it toward Ghostty: the terminal look reaches the whole window (mono type, terminal-style selection, splits with thin dividers, an unfocused pane slightly dimmed like Ghostty's unfocused splits, tabs in the title bar), with a translucent, blurred window over the desktop. "Bit glassy": the glass shows, but text contrast comes first.

## 13 Nov 2026, evening: reaction to the Console riff (Workbench, Tiles, Cross, Ledger)

- **"This is too much, think terminal, more practicality over big wasteful paddings and stuff and all needs to be coherent."** Asked whether it is "world class UI/UX that an Apple designer or someone working at IntelliJ/JetBrains would do": it is not.
  So: density of a pro tool (IntelliJ, Xcode, Ghostty). Hairline panes instead of floating rounded cards; small, consistent row and control heights; one type scale; padding only where it separates things. Every part uses the same few components so the whole reads as one system. Glass and the Sony touch belong to the chrome and selection states, never at the cost of space.

## 13 Nov 2026: reaction to the first five session-board directions (Notch, Menu bar, Board, Console, Queue)

- **Console comes closest**, but: "I dont want the default view be a terminal or something that solely feels and is usable like a terminal. I like clicking around and I like having keyboard shortcuts."
  So: the density and technical feel of Console, in an interface that is fully usable with the mouse. Every action has a visible, clickable control and a keyboard shortcut. A terminal is something the app contains, not what the app is.
- **Glassy.**
- **Light mode should feel like `references/light-mode-frosted-glass.png`.** What is in that image: soft grey frosted panels layered on a grey ground, thick rounded outer shells with a thin inner edge, low contrast with dark type, one dark vertical rail for navigation, small mono labels set vertically on the shell ("REAGLE 2025 NAV"), counts in small pills, a selected row that looks like a raised glass key.
- **Dark mode: "the 2000 sony aesthetic, inspired/touch, with a modern technical feel."** He has no UI reference for it; the object reference is `references/dark-mode-sony-2000s-psp.jpg` (a silver PSP in a clear case, the XMB menu on screen). What is in that image: brushed silver and clear polycarbonate, engraved line art and lettering, small labelled hardware keys (SELECT, START, VOL), a serial number, a single green power light, the XMB's horizontal row of icons over a dark photographic ground. It is a touch of that era, not a costume.
- **Who it is for:** "This tool should feel like for technical people and not casuals, because casuals dont have this problem and they just use codex or claude app."

## 13 Nov 2026, later: what the core is

- **The terminal is part of the app, not a panel bolted on.** "Cursor/vscode had a built in terminal but it didnt feel like a cool terminal and it also felt different than the whole app." "I think Warp goes into the right direction."
  So: the terminal and the rest of the app are one design, same type, same surfaces, same controls. Warp is the reference for a terminal treated as a product.
- **Notch and menu bar are add-ons, not the core.** "Notch nook cool idea, but these are like nice add-ons."
- **Not a Linear clone.** "We dont really need a linear clone because I already use linear maybe? but something else? or some todo'ish thing or linear integration." Open question, his to decide: a light local checklist, a Linear integration, or both. Show options; do not build a tracker.
- **The look he called "crazy cool":** "ghostty look, arch linux, sony silver psp modded look." Ghostty's plain, fast, native terminal; the Arch Linux / riced-desktop culture (tiling, mono type, status bars, customisation as a feature); and the modded silver PSP.
- **GitKraken:** "git kraken looks not bad." A dense, graphical developer tool he finds acceptable-looking; add it to the references (the commit graph, the panel layout, the dark theme).
