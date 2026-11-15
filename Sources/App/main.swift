import AppKit
import UserNotifications

// Launch marks (process start -> milestone) on stderr, so measure.sh can time them.
func processStartTime() -> Double {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &kp, &size, nil, 0)
    return Double(kp.kp_proc.p_starttime.tv_sec) + Double(kp.kp_proc.p_starttime.tv_usec) / 1e6
}
let launchStart = processStartTime()
func mark(_ what: String) {
    let line = String(format: "[maxwell] %@  %.1f ms\n", what as NSString, (Date().timeIntervalSince1970 - launchStart) * 1000)
    FileHandle.standardError.write(line.data(using: .utf8)!)
}
/// A scripted test run (it quits by itself), or Maxwell Dev started by a Claude session to check
/// its work: no Dock icon, never takes focus, window kept behind the user's windows, no Keychain.
/// Keys and clicks come from --keys and --click, not the real input. Read before
/// ClaudeCLI.scrubOwnEnvironment removes CLAUDECODE.
let quietTest = CommandLine.arguments.contains("--quit-after")
    || (Bundle.main.bundleIdentifier != Updater.releaseID && ProcessInfo.processInfo.environment["CLAUDECODE"] != nil)

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var store: Store!
    var main: MainWindowController!
    private var configWatcher: FileWatcher?
    private var appearanceWatch: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ n: Notification) {
        ClaudeCLI.scrubOwnEnvironment()
        Fonts.register()
        var config = Config.load()
        if let t = arg("--theme") { config.themeOverride = t }
        Metrics.fontSize = CGFloat(config.fontSize - 1)
        let theme = Theme.load(config.theme(systemDark: SystemAppearance.isDark))
        Look.theme = theme
        GhosttyRuntime.shared.start(configText: MainWindowController.ghosttyConfig(theme, fontSize: CGFloat(config.terminalFontSize)))
        mark("ghostty ready")

        Wrap.publish(config.wrapLine)
        if Updater.isRelease { HookInstaller.refreshBinary(bundledHook: bundledHookURL()) }
        store = Store(config: config)
        mark("event log folded (\(store.state.sessions.count) sessions)")
        main = MainWindowController(store: store)
        main.onConfigEdit = { [weak self] k, v in self?.edit(k, v) }
        store.isOnScreen = { [weak self] id in
            guard let self, NSApp.isActive, self.main.window?.isMiniaturized == false else { return false }
            return self.main.current == id
        }
        NSApp.mainMenu = MenuBuilder.build(main.actions)
        if !ClaudeCLI.claudeFound { main.toast("Maxwell can't find claude, so it can't list or start sessions. Put claude on your shell's PATH and reopen Maxwell.") }
        main.window?.appearance = theme.appearance
        main.root.viewerPane.viewer.setTheme(theme, fontSize: Metrics.fontSize, prose: config.viewerFont)
        main.root.viewerPane.showTree = config.showTree
        main.applyLayout(config)
        mark("render start"); main.render(store.state); mark("render end")
        (main.window as? MXWindow)?.present()
        if !quietTest { NSApp.activate(ignoringOtherApps: true) }
        mark("window ordered front (id \(main.window?.windowNumber ?? 0))")
        DispatchQueue.main.async {
            mark("first runloop after window")
            self.store.onNotificationsAnswered = { [weak self] in self?.main.recheckNotifications() }
            self.store.start()
            self.main.refreshSetup()
            self.runTestHooks()
            self.launched = true
            if let f = self.pendingFolder { self.pendingFolder = nil; self.main.showNewSession(folder: f) }
            self.main.updater.start()
            if !Updater.isRelease { NSApp.dockTile.badgeLabel = "dev" }
        }
        UNUserNotificationCenter.current().delegate = self
        if quietTest { handFocusBack() }
        watchConfig()
        // Follow macOS light/dark when the config says appearance = system.
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reloadConfig() }
        }
        IconArt.choice = config.appIcon
        IconArt.apply(dark: theme.dark)
    }

    /// macOS still brings a quiet run to the front when it is `open`ed or reopened (AppKit doesn't
    /// even report it active), so it watches every app switch and gives the front back at once.
    private var userApp = NSWorkspace.shared.frontmostApplication
    private func handFocusBack() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app == .current else { return self.userApp = app }
            guard let back = self.userApp, back != .current else { return }
            NSApp.yieldActivation(to: back)
            mark("front handed back to \(back.localizedName ?? "?"): \(back.activate(from: .current))")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// `open -a Maxwell .` in any terminal, or a folder dropped on the Dock icon: a new session there.
    /// A folder that arrives with the launch waits until the window and sessions are up.
    func application(_ app: NSApplication, open urls: [URL]) {
        guard let dir = urls.first(where: { $0.hasDirectoryPath })?.path else { return }
        guard launched, let main else { pendingFolder = dir; return }
        main.showWindow(nil)
        if !quietTest { NSApp.activate(ignoringOtherApps: true) }
        main.showNewSession(folder: dir)
    }
    private var pendingFolder: String?
    private var launched = false
    func applicationWillTerminate(_ n: Notification) { store?.plugins.shutdownAll() }
    /// `open Maxwell.app` while a run of the same bundle is up reopens that instance. A quiet run
    /// stays quiet and still quits on time: a reopened test run once sat in front for an hour.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if quietTest { mark("reopen ignored: quiet run"); return false }
        main.showWindow(nil)
        return true
    }

    func applicationDidBecomeActive(_ n: Notification) {
        main?.recheckNotifications()
        main?.refreshSetup()
    }

    /// Clicking a notification opens that session.
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        if let id = r.notification.request.content.userInfo["session"] as? String {
            DispatchQueue.main.async { self.main.showWindow(nil); NSApp.activate(ignoringOtherApps: true); self.main.open(id) }  // only from a real click
        }
        done()
    }

    // MARK: config

    private func edit(_ key: String, _ value: String) {
        let url = Paths.configFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? Config.starter
        let new = key.hasPrefix("browser:")
            ? Config.settingBrowser(account: String(key.dropFirst("browser:".count)), to: BrowserChoice.parse(value), in: text)
            : Config.setting(key, to: value, in: text)
        try? new.write(to: url, atomically: true, encoding: .utf8)
        reloadConfig()
    }

    private func watchConfig() {
        let url = Paths.configFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Config.starter.write(to: url, atomically: true, encoding: .utf8)
        }
        configWatcher = FileWatcher(url: url) { [weak self] in self?.reloadConfig() }
    }

    private func reloadConfig() {
        var c = Config.load()
        if let t = arg("--theme") { c.themeOverride = t }
        guard c != store.config || Look.theme.name != c.theme(systemDark: SystemAppearance.isDark) else { return }
        if c.wrapLine != store.config.wrapLine { Wrap.publish(c.wrapLine) }
        store.reloadConfig(c)
        main.refreshSetup()
        main.applyLook(c)
        IconArt.choice = c.appIcon
        IconArt.apply(dark: Look.theme.dark)
    }

    // MARK: test hooks (used by measure.sh and screenshots.sh)

    private func runTestHooks() {
        // A quiet run started without --quit-after (a session checking its work) ends after 10 minutes.
        if let s = arg("--quit-after").flatMap(Double.init) ?? (quietTest ? 600 : nil) {
            mark("quits after \(Int(s)) s")
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { NSApp.terminate(nil) }
        }
        // --retina or --plain: put the window on a 2x or a 1x display for the capture, unless the
        // parked window already has that scale.
        let retina = CommandLine.arguments.contains("--retina")
        if retina || CommandLine.arguments.contains("--plain"), let w = main.window, (w.backingScaleFactor > 1) != retina,
           let s = NSScreen.screens.first(where: { ($0.backingScaleFactor > 1) == retina }) {
            w.setFrameOrigin(NSPoint(x: s.visibleFrame.minX + 20, y: s.visibleFrame.maxY - w.frame.height - 20))
        }
        if let size = arg("--size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2, let w = main.window {
            w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - size[1], width: size[0], height: size[1]), display: true)
            mark("window frame \(NSStringFromRect(w.frame)) on \(w.screen?.localizedName ?? "?")")
        }
        // Full screen takes over a Space on the user's screen, so a quiet run never enters it.
        if CommandLine.arguments.contains("--fullscreen") {
            if quietTest { mark("--fullscreen skipped: quiet run") } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.activate(ignoringOtherApps: true); self.main.window?.toggleFullScreen(nil) }
            }
        }
        if let p = arg("--project") { main.setScope(p == "all" ? nil : p) }
        if let name = arg("--select") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let s = self.store.state.sessions.values.first(where: { $0.title == name || $0.name == name || $0.id.hasPrefix(name) }) else {
                    return mark("select \(name): no such session")
                }
                self.main.open(s.id)
                mark("selected \(name)")
            }
        }
        if let n = arg("--visit-all").flatMap(Int.init) {
            // Visits n background sessions whose name starts with --visit-prefix (default "mxtest"),
            // like clicking through them. The prefix keeps measurement runs off real sessions.
            let prefix = arg("--visit-prefix") ?? "mxtest"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let ids = self.store.state.sessions.values.filter {
                    guard $0.name.hasPrefix(prefix), case .background = $0.reach else { return false }
                    return true
                }.prefix(n).map(\.id)
                for (i, id) in ids.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4) { self.main.open(id) }
                }
                mark("visiting \(ids.count)")
            }
        }
        if let path = arg("--snap") {
            let delays = (arg("--snap-after") ?? "5").split(separator: ",").compactMap { Double($0) }
            for (i, d) in delays.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                    let out = delays.count == 1 ? path : path.replacingOccurrences(of: ".png", with: "-\(i + 1).png")
                    self.snapshot(to: out)
                }
            }
        }
        if let dir = arg("--record") {
            // --record <dir>: window frames, about --record-fps a second (default 30), for --record-for
            // seconds (default 30). Each file is named by its time in ms, so slow frames keep real time;
            // demo/record.sh turns them into a video.
            let fps = Double(arg("--record-fps") ?? "") ?? 30, length = Double(arg("--record-for") ?? "") ?? 30
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let start = Date()
            func next() {
                let t = Date().timeIntervalSince(start)
                guard t < length else { return mark("recorded \(dir)") }
                self.snapshot(to: String(format: "%@/%07d.tiff", dir, Int(t * 1000)), quiet: true)
                let wait = max(0, 1 / fps - (Date().timeIntervalSince(start) - t))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: next)
            }
            mark("recording")
            next()
        }
        if let id = arg("--bring-in") {
            // --bring-in <session id prefix>: the "Bring into Maxwell" button for that session.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if let s = self.store.state.sessions.values.first(where: { $0.id.hasPrefix(id) }) { self.main.bringIn(s.id, force: false) }
                mark("bring-in \(id)")
            }
        }
        if let spec = arg("--keys") {
            // --keys "2:shift shift;3.5:esc": at each time, these keys, as if pressed in this window.
            for step in spec.split(separator: ";") {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let at = Double(parts[0]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    for k in parts[1].split(separator: " ") { self.press(String(k)) }
                    mark("keys \(parts[1])")
                }
            }
        }
        if let spec = arg("--pointer") {
            // --pointer "2:5,400;3:-5,400": the pointer at window point x,y (top left) at each time,
            // as the hover tracking sees it. A negative x leaves the window through the left edge.
            for step in spec.split(separator: ";") {
                let parts = step.split(separator: ":").map(String.init)
                let xy = (parts.last ?? "").split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2, xy.count == 2, let at = Double(parts[0]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    guard let w = self.main.window else { return }
                    let p = NSPoint(x: xy[0], y: w.contentLayoutRect.height - xy[1])
                    let type: NSEvent.EventType = xy[0] < 0 ? .mouseExited : .mouseMoved
                    guard let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
                    if type == .mouseExited { self.main.root.mouseExited(with: e) } else { self.main.root.mouseMoved(with: e) }
                    mark("moved \(xy)")
                }
            }
        }
        if let spec = arg("--click") {
            // --click "3:700,600": a left click at window point x,y (from the top left) at 3 s.
            let parts = spec.split(separator: ":").map(String.init)
            let xy = (parts.last ?? "").split(separator: ",").compactMap { Double($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (parts.count > 1 ? Double(parts[0]) ?? 3 : 3)) {
                guard xy.count == 2, let w = self.main.window else { return }
                let p = NSPoint(x: xy[0], y: w.contentLayoutRect.height - xy[1])
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(e) }
                }
                mark("clicked \(xy)")
            }
        }
        if let text = arg("--type") {
            // Types into the selected session's terminal, as if the user did.
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(arg("--type-after") ?? "4") ?? 4)) {
                (self.main.root.sessionPane.content.subviews.first { !$0.isHidden } as? TerminalView)?.sendLine(text)
                mark("typed")
            }
        }
        if let text = arg("--type-shell") {
            // Types into the plain terminal on screen (New Terminal), never into a session.
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(arg("--type-after") ?? "4") ?? 4)) {
                let shell = self.main.shownShell
                shell?.sendLine(text)
                mark(shell == nil ? "no terminal on screen" : "typed in terminal")
            }
        }
        if let spec = arg("--start") {
            // --start <account|roomiest>:<folder>:<name>: the ⌘N panel's Start, without the panel.
            // Test sessions run on haiku (--model overrides).
            let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let a = parts[0] == "roomiest" ? self.store.state.roomiest(now: Date()) : self.store.state.account(parts[0])
                guard let a, parts.count == 3 else { return mark("bad --start") }
                mark("starting \(parts[2]) on \(a.name)")
                self.main.startSession(account: a, folder: parts[1], name: parts[2], model: arg("--model") ?? "haiku")
            }
        }
        if let d = arg("--detach-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                (self.main.root.sessionPane.content.subviews.first { !$0.isHidden } as? TerminalView)?.sendControl("z", keyCode: 6)
                mark("sent ctrl+z")
            }
        }
        if let d = arg("--reattach-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                if let id = self.main.current { self.main.reattach(id) }
                mark("reattached")
            }
        }
        if let needle = arg("--cmd-click") {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(arg("--click-after") ?? "5") ?? 5)) {
                let t = self.main.root.sessionPane.content.subviews.first { !$0.isHidden } as? TerminalView
                mark("cmd-click \(needle): \(t?.cmdClick(on: needle) ?? false)")
            }
        }
        if let needle = arg("--plain-click") {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(arg("--click-after") ?? "5") ?? 5)) {
                let t = self.main.root.sessionPane.content.subviews.first { !$0.isHidden } as? TerminalView
                mark("plain-click \(needle): \(t?.plainClick(on: needle) ?? "not on screen")")
            }
        }
        func after(_ key: String, _ fallback: Double, _ run: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(arg(key) ?? "") ?? fallback), execute: run)
        }
        func named(_ name: String) -> SessionID? {
            let st = self.store.state
            return (st.sessions.values.map(\.self) + st.closed.values.map(\.session)).first { $0.name == name }?.id
        }
        if let prefix = arg("--close-safe") {
            after("--close-after", 6) {
                self.main.closeAllSafe(onlyNamed: prefix)
                mark("close sheet (\(prefix)*): \(self.main.closeSheet.items.map(\.title))")
            }
        }
        if let prefix = arg("--stop-idle") {
            // Presses the Idle header's stop button, limited to names with this prefix (test runs: "mxtest").
            after("--stop-after", 6) {
                let now = Date(), st = self.store.state
                let ids = st.sessions.values.filter { $0.name.hasPrefix(prefix) && st.group($0, now: now, rules: self.store.config.rules) == .idle }.map(\.id)
                mark("stop idle (\(prefix)*): \(ids)")
                self.main.stopIdle(ids)
            }
        }
        if let spec = arg("--switch-project"), let at = spec.split(separator: "@").last.flatMap({ Double($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { self.main.setScope(String(spec.split(separator: "@")[0])) }
        }
        if let s = arg("--rail-peek").flatMap(Double.init) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { self.main.root.peekRail(for: 30) } }
        if let spec = arg("--move") {
            // --move usage:right,system:right  places panels, like the "Move to" menu.
            for part in spec.split(separator: ",") {
                let kv = part.split(separator: ":").map(String.init)
                if kv.count == 2, let p = PanelID(rawValue: kv[0]), let d = Dock(rawValue: kv[1]) { main.root.panels.move(p, to: d) }
            }
        }
        if let spec = arg("--hide") { for p in spec.split(separator: ",").compactMap({ PanelID(rawValue: String($0)) }) { main.root.setHidden(p, true) } }
        if arg("--confirm-after") != nil { after("--confirm-after", 8) { mark("confirm"); self.main.closeSheet.submit() } }
        if arg("--undo-after") != nil { after("--undo-after", 14) { mark("undo: \(self.main.root.status.runToastAction())") } }
        if let spec = arg("--move-to") {
            // --move-to <session name>=<project>, or =- to move it back.
            let kv = spec.split(separator: "=", maxSplits: 1).map(String.init)
            after("--move-to-after", 4) {
                guard kv.count == 2, let id = named(kv[0]) else { return mark("move-to: no session \(kv[0])") }
                if kv[1] == "-" { self.store.moveProject(id, to: nil) } else { self.main.moveSession(id, to: kv[1]) }
                mark("moved \(kv[0]) -> \(kv[1])")
            }
        }
        if let name = arg("--row-menu") {
            // Opens a row's menu (and its first submenu) so --snap can capture them; menus track modally.
            after("--row-menu-after", 4) {
                guard let id = named(name) else { return mark("row-menu: no session \(name)") }
                if let path = arg("--snap") {
                    let t = Timer(timeInterval: 1.2, repeats: false) { _ in self.snapshot(to: path); self.main.root.sidebar.list.openMenu?.cancelTracking() }
                    RunLoop.main.add(t, forMode: .common)
                }
                self.main.root.sidebar.list.showMenu(id, submenu: CommandLine.arguments.contains("--submenu"))
            }
        }
        if let name = arg("--expand") { after("--expand-after", 4) { if let id = named(name) { self.main.root.sidebar.list.setExpanded(id, true) }; mark("expanded \(name)") } }
        if let name = arg("--reopen") { after("--reopen-after", 4) { if let id = named(name) { self.main.reopen(id) }; mark("reopen \(name)") } }
        if let name = arg("--not-safe") { after("--not-safe-after", 4) { if let id = named(name) { self.main.notSafe(id) }; mark("not safe \(name)") } }
        if arg("--unfold-closed") != nil { after("--unfold-after", 3) { self.main.root.sidebar.list.toggle(.recentlyClosed) } }
        if arg("--expand-idle") != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.main.root.sidebar.list.toggleIdle() } }
        if let list = arg("--action") {
            // --action <id>@<seconds>[,<id>@<seconds>…]: runs actions from the registry, as their shortcuts would.
            for spec in list.split(separator: ",") {
                let parts = spec.split(separator: "@").map(String.init)
                DispatchQueue.main.asyncAfter(deadline: .now() + (parts.count > 1 ? Double(parts[1]) ?? 3 : 3)) {
                    self.main.actions.first { $0.id == parts[0] }?.run()
                    mark("action \(parts[0])")
                }
            }
        }
        // --session-open "<seconds>:<path>[;…]": as if the session on show wrote or named the file.
        if let list = arg("--session-open") {
            for step in list.split(separator: ";") {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let at = Double(parts[0]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    self.main.sessionOpenedForTest(.file(URL(fileURLWithPath: parts[1])))
                    mark("session opened \(parts[1])")
                }
            }
        }
        // --open-artifacts a,b: artifact tabs of their own, as ⌘-clicks would open them.
        if let list = arg("--open-artifacts") {
            after("--open-after", 4) {
                for u in list.split(separator: ",") { if let l = ArtifactLink.parse(String(u)) { self.main.show(.artifact(l, title: nil), for: self.main.current) } }
                mark("opened artifacts")
            }
        }
        // --artifact-switch "work:url1,url2": shows url1, url2, then url1 again as that account, 3 s apart,
        // and logs what the artifact view holds after each (how many pages stay loaded).
        if let spec = arg("--artifact-switch") {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            let links = (parts.last ?? "").split(separator: ",").compactMap { ArtifactLink.parse(String($0)) }
            for (i, l) in (links + links.prefix(1)).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i) * 3) {
                    guard let a = self.store.state.accounts.first(where: { $0.name == parts[0] }) else { return mark("no account \(parts[0])") }
                    self.main.root.setViewer(open: true, animated: false)
                    self.main.root.viewerPane.viewer.openArtifact(l, account: a)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.main.root.viewerPane.viewer.artifact.probe { mark("switch \(i): \($0)") } }
                }
            }
        }
        // --tabs-log 6,9: logs the viewer's tabs at those times.
        if let list = arg("--tabs-log") {
            for t in list.split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { mark("tabs: \(self.main.viewerTabsSummary)") }
            }
        }
        // --viewer-width 700: the right area this wide (not saved).
        if let w = arg("--viewer-width").flatMap(Double.init) { main.root.panels.size[.right] = CGFloat(w) }
        // --viewer-js "<seconds>:<js>[;;…]": runs JS in the file view and logs the result.
        if let list = arg("--viewer-js") {
            for step in list.components(separatedBy: ";;") {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let at = Double(parts[0]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    self.main.root.viewerPane.viewer.evaluate(parts[1]) { mark("viewer js \(parts[1]) = \($0)") }
                }
            }
        }
        // --drag "<seconds>:x1,y1>x2,y2": a press, a drag in steps and a release (window points, as --click).
        if let spec = arg("--drag") {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            let pts = (parts.last ?? "").split(separator: ">").map { $0.split(separator: ",").compactMap { Double($0) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + (parts.count > 1 ? Double(parts[0]) ?? 3 : 3)) {
                guard pts.count == 2, pts.allSatisfy({ $0.count == 2 }), let w = self.main.window else { return }
                let h = w.contentLayoutRect.height
                func ev(_ t: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent? {
                    NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: h - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                // The drag and the release go in the queue first: the press reads them from there.
                for i in 1...8 {
                    let k = Double(i) / 8
                    if let e = ev(.leftMouseDragged, pts[0][0] + (pts[1][0] - pts[0][0]) * k, pts[0][1] + (pts[1][1] - pts[0][1]) * k) { NSApp.postEvent(e, atStart: false) }
                }
                if let up = ev(.leftMouseUp, pts[1][0], pts[1][1]) { NSApp.postEvent(up, atStart: false) }
                if let down = ev(.leftMouseDown, pts[0][0], pts[0][1]) { NSApp.sendEvent(down) }
                mark("dragged \(spec)")
            }
        }
        if let q = arg("--search") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.main.showSearch(query: q == "-" ? "" : q) } }
        if arg("--palette") != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.main.showPalette() } }
        if arg("--new") != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.main.showNewSession() } }
        if let s = arg("--settings") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.main.showSettings(SettingsSection(rawValue: s.capitalized)) } }
        if let spec = arg("--tooltip") {
            // --tooltip "x,y;x,y": the tip a resting pointer at each point (window, top-left origin) would show,
            // one every --tooltip-every seconds (default 1) from --tooltip-after (default 4). Pair with --snap-after.
            // --tooltip-cold 1 keeps the hover delay and warm hand-off, to check their timing.
            let every = Double(arg("--tooltip-every") ?? "") ?? 1
            for (i, pt) in spec.split(separator: ";").enumerated() {
                let xy = pt.split(separator: ",").compactMap { Double($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + (Double(arg("--tooltip-after") ?? "") ?? 4) + Double(i) * every) {
                    mark("tooltip \(pt): \(xy.count == 2 && self.main.showTooltip(at: NSPoint(x: xy[0], y: xy[1]), inSettings: arg("--settings") != nil, cold: arg("--tooltip-cold") != nil))")
                }
            }
        }
        if let png = arg("--viewer-probe") {
            after("--probe-after", 6) { self.main.root.viewerPane.viewer.probe(png: URL(fileURLWithPath: png)) { mark("viewer: \($0)") } }
        }
        // After --select (which waits for the first listing), or the viewer has no session to show it in.
        // --open a,b opens each in a tab of its own; --open-preview c as if the session opened it (the preview tab).
        if let f = arg("--open") {
            after("--open-after", 4) {
                for p in f.split(separator: ",") { self.main.showFile(URL(fileURLWithPath: String(p)), for: self.main.current) }
                if let pv = arg("--open-preview") { self.main.show(.file(URL(fileURLWithPath: pv)), for: self.main.current, keep: false) }
                mark("open \(f) for \(self.main.current ?? "no session")")
            }
        }
        // --open-artifact <url>: as if the selected session published it. --artifact-probe logs what the artifact view shows.
        if let u = arg("--open-artifact") {
            after("--open-after", 4) {
                if let l = ArtifactLink.parse(u) { self.main.show(.artifact(l, title: nil), for: self.main.current) }
                mark("open artifact \(u) for \(self.main.current ?? "no session")")
            }
        }
        // --artifact-accounts work,work2,private: every 8 s, the viewer shows claude.ai's sign-in page for the next
        // account (a page load on that account's data store, no session needed). For measure.sh.
        if let list = arg("--artifact-accounts") {
            for (i, name) in list.split(separator: ",").map(String.init).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i) * 8) {
                    guard let a = self.store.state.accounts.first(where: { $0.name == name }), let l = ArtifactLink.parse("https://claude.ai/artifact/Dez5d8DPYa2wrqBrR3W2gs") else { return mark("no account \(name)") }
                    self.main.root.setViewer(open: true, animated: false)
                    self.main.root.viewerPane.show(ViewerTabs(tabs: [.artifact(l, title: nil)], active: 0), account: a)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.main.root.viewerPane.viewer.artifact.signIn() }
                    mark("artifact page for \(name)")
                }
            }
        }
        if arg("--artifact-probe") != nil {
            after("--probe-after", 10) { self.main.root.viewerPane.viewer.artifact.probe { mark("\($0)") } }
        }
        if let png = arg("--artifact-snap") {
            after("--probe-after", 10) {
                self.main.root.viewerPane.viewer.artifact.snapshot(png: URL(fileURLWithPath: png)) { mark("artifact snapshot: \($0)") }
            }
        }
        if let name = arg("--sign-in-window") {
            after("--sign-in-after", 3) {
                if let a = self.store.state.accounts.first(where: { $0.name == name }) { SignInWindow.show(a, near: self.main.window) }
                mark("sign-in window \(name)")
            }
        }
        if let path = arg("--dump") {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(arg("--dump-after") ?? "6") ?? 6)) {
                let text = self.main.current.flatMap { self.mainTerminalText($0) } ?? ""
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
                mark("dumped viewport")
            }
        }
    }

    /// Captures Maxwell's own window (no screen-recording permission needed for own windows).
    private func snapshot(to path: String, quiet: Bool = false) {
        let target = arg("--settings") != nil ? NSApp.windows.first { $0.title == "Maxwell Settings" && $0.isVisible }
            : main.window
        guard let w = target else { return mark("snapshot failed") }
        // With the screen locked the window server hands back a blank image; render the layer tree instead.
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        guard var img = locked ? renderLayers(w) : CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
            return mark("snapshot failed")
        }
        if locked, let withMenus = overlayMenus(img, on: w) { img = withMenus }
        // Captures carry the display's profile; PNG viewers often ignore it, so store sRGB.
        let raw = NSBitmapImageRep(cgImage: img)
        let rep = raw.converting(to: .sRGB, renderingIntent: .default) ?? raw
        // Recordings write uncompressed TIFF: PNG compression halves the frame rate.
        let type: NSBitmapImageRep.FileType = path.hasSuffix(".tiff") ? .tiff : .png
        try? rep.representation(using: type, properties: [:])?.write(to: URL(fileURLWithPath: path))
        if !quiet { mark("snapshot \(path)") }
    }

    /// Open menus are windows of their own; a locked-screen capture draws them over the window.
    private func overlayMenus(_ base: CGImage, on w: NSWindow) -> CGImage? {
        let menus = NSApp.windows.filter { $0.isVisible && $0 !== w && $0.level.rawValue > w.level.rawValue && NSStringFromClass(type(of: $0)).contains("Menu") }
        guard !menus.isEmpty, let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = w.backingScaleFactor
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for m in menus {
            guard let view = m.contentView else { continue }
            let size = view.bounds.size
            let o = CGPoint(x: (m.frame.minX - w.frame.minX) * scale, y: (m.frame.minY - w.frame.minY) * scale)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            // The menu's material is drawn by the window server, not the view; stand in for it.
            let r = CGRect(x: o.x, y: o.y, width: size.width * scale, height: size.height * scale)
            ctx.setFillColor(NSColor(white: Look.theme.dark ? 0.2 : 0.95, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6 * scale, cornerHeight: 6 * scale, transform: nil)); ctx.fillPath()
            if let ci = rep.cgImage { ctx.draw(ci, in: r) }
        }
        return ctx.makeImage()
    }

    private func renderLayers(_ w: NSWindow) -> CGImage? {
        guard let view = w.contentView, let layer = view.layer else { return nil }
        let scale = w.backingScaleFactor, size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // A stand-in desktop behind the glass, so the capture shows what the tint does.
        ctx.setFillColor(NSColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        if view.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// One key for --keys: "shift" (pressed and released), "esc", "return", "cmd+t", or a letter.
    private func press(_ spec: String) {
        guard let w = main.window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if spec == "shift" {
            for flags in [NSEvent.ModifierFlags.shift, []] {
                if let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: now, windowNumber: w.windowNumber,
                                            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56) { NSApp.sendEvent(e) }
            }
            return
        }
        var mods: NSEvent.ModifierFlags = []
        var key = spec
        for (name, flag) in [("cmd+", NSEvent.ModifierFlags.command), ("shift+", .shift), ("alt+", .option), ("ctrl+", .control)] where key.contains(name) {
            mods.insert(flag); key = key.replacingOccurrences(of: name, with: "")
        }
        let named: [String: (String, UInt16)] = ["esc": ("\u{1b}", 53), "return": ("\r", 36), "down": ("\u{F701}", 125), "up": ("\u{F700}", 126), "left": ("\u{F702}", 123), "right": ("\u{F703}", 124)]
        let (chars, code) = named[key] ?? (key, Self.keyCodes[key] ?? 0)
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: now, windowNumber: w.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                // Menu key equivalents only fire for the active app; a quiet run is never active, so route them the same way.
                if t == .keyDown, !mods.isEmpty, NSApp.mainMenu?.performKeyEquivalent(with: e) == true { continue }
                NSApp.sendEvent(e)
            }
        }
    }
    private static let keyCodes: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21]

    private func mainTerminalText(_ id: SessionID) -> String? {
        (main.root.sessionPane.content.subviews.first { !$0.isHidden } as? TerminalView)?.viewportText()
    }
}

if let code = runCLI(CommandLine.arguments) { exit(code) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(quietTest ? .accessory : .regular)
mark("main")
app.run()
