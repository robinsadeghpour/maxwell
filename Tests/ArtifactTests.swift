import Foundation

/// Artifact links, what a transcript line says about them, and the per-account browser choice.
func artifactTests() {
    // Links
    let a = ArtifactLink.parse("see https://claude.ai/artifact/Dez5d8DPYa2wrqBrR3W2gs.")
    check(a?.id == "Dez5d8DPYa2wrqBrR3W2gs" && a?.url.absoluteString == "https://claude.ai/artifact/Dez5d8DPYa2wrqBrR3W2gs", "artifact link without trailing dot")
    check(ArtifactLink.parse("(https://claude.ai/code/artifact/667b5c2a-c02c-4f45-80d7-bac8f9540314)")?.id == "667b5c2a-c02c-4f45-80d7-bac8f9540314", "code/artifact uuid link")
    check(ArtifactLink.parse("https://claude.ai/new") == nil && ArtifactLink.parse("https://example.com/artifact/abcdefghij") == nil, "only claude.ai artifact links")
    check(ArtifactLink.all(in: "[x](<https://claude.ai/artifact/AAAAAAAAAA>) and https://claude.ai/artifact/AAAAAAAAAA, https://claude.ai/artifact/BBBBBBBBBB").map(\.id) == ["AAAAAAAAAA", "BBBBBBBBBB"], "all links, in order, no repeats")

    // Claude Code writes transcripts with JSON.stringify, which leaves "/" unescaped.
    func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o, options: .withoutEscapingSlashes), encoding: .utf8)! }
    let url = "https://claude.ai/artifact/JA5Dkn9y6hkXUiYGi4Pd4r"
    // Artifact tool: first publish, then a republish.
    let pub = line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "Published /tmp/plan.html at \(url) (Version 1, version id 1794503742-18fa)"]]],
                    "toolUseResult": ["url": url, "title": "Monday Plan", "updated": false, "version": "1794503742-18fa", "seq": 1]])
    let s1 = ArtifactTranscript.sighting(inLine: pub)
    check(s1?.link.id == "JA5Dkn9y6hkXUiYGi4Pd4r" && s1?.title == "Monday Plan" && s1?.republished == false, "publish result opens the artifact with its title")
    let repub = line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t2", "content": "Updated the Artifact at \(url) (Version 2)"]]],
                      "toolUseResult": ["url": url, "title": "Monday Plan", "updated": true, "version": "1794508745-206b", "seq": 2]])
    check(ArtifactTranscript.sighting(inLine: repub)?.republished == true, "republish result asks for a reload")
    // Older shape: no toolUseResult, only the text.
    let oldRepub = line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t3", "content": [["type": "text", "text": "Updated the Artifact at \(url) (Version 3, version id x)"]]]]]])
    check(ArtifactTranscript.sighting(inLine: oldRepub)?.republished == true, "text-only republish result")
    let opened = line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t4", "content": "Opened the Artifact at \(url) for the user."]]],
                       "toolUseResult": ["url": url, "opened": true, "title": "Monday Plan", "artifact_id": "x"]])
    check(ArtifactTranscript.sighting(inLine: opened)?.link.id == "JA5Dkn9y6hkXUiYGi4Pd4r", "open result opens it")
    // Reads, lists and other tools' results that only mention a link are not the session's own artifact.
    let read = line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t5", "content": "Read 3 files from version x of \(url)"]]],
                     "toolUseResult": ["artifactRead": true, "read": [:], "owned": true]])
    check(ArtifactTranscript.sighting(inLine: read) == nil, "Artifact read result ignored")
    let linear = line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t6", "content": [["type": "text", "text": "{\"body\":\"Design: \(url)\"}"]]]]]])
    check(ArtifactTranscript.sighting(inLine: linear) == nil, "a link inside a Linear result is ignored")
    let bash = line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t7", "content": "notes.md: Timeline \(url)"]]],
                     "toolUseResult": ["stdout": "notes.md: Timeline \(url)", "stderr": "", "interrupted": false]])
    check(ArtifactTranscript.sighting(inLine: bash) == nil, "a link in Bash output is ignored")
    // Claude Docs result: the frame's artifactUrl.
    let docs = line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t8", "content": [["type": "text", "text": "{\"frame\":{\"slug\":\"x\",\"artifactUrl\":\"https://claude.ai/artifact/BLjTTEYMaFVbaj2FYte4JN\"}}"]]]]]])
    check(ArtifactTranscript.sighting(inLine: docs)?.link.id == "BLjTTEYMaFVbaj2FYte4JN", "Claude Docs result opens the doc")
    // The assistant naming a link in its reply: the last one wins. Its tool calls don't count.
    let said = line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Old: https://claude.ai/artifact/OLDOLDOLD1. New: \(url)"]]]])
    check(ArtifactTranscript.sighting(inLine: said)?.link.id == "JA5Dkn9y6hkXUiYGi4Pd4r", "the reply's last link")
    let call = line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t9", "name": "mcp__linear__save_comment", "input": ["body": "see \(url)"]]]]])
    check(ArtifactTranscript.sighting(inLine: call) == nil, "a link in a tool call's input is ignored")
    let typed = line(["type": "user", "message": ["role": "user", "content": "look at \(url)"]])
    check(ArtifactTranscript.sighting(inLine: typed) == nil, "a link Robin typed is not reopened")

    // Settled pages
    check(ArtifactPage.classify(path: "/artifact/X", title: "Sign in – Claude", body: "Sign in to view this page\nSign in\n", frames: 1) == .signedOut, "signed-out artifact page (seen in the spike)")
    check(ArtifactPage.classify(path: "/login", title: "", body: "", frames: 0) == .signedOut, "redirect to login")
    check(ArtifactPage.classify(path: "/artifact/X", title: "Claude", body: "Artifact not found", frames: 0) == .noAccess, "not found")
    check(ArtifactPage.classify(path: "/artifact/X", title: "Plan – Claude", body: "Plan\nShare", frames: 1) == .artifact, "artifact in its iframe")
    check(ArtifactPage.classify(path: "/artifact/X", title: "Claude", body: "", frames: 0) == nil, "still drawing")
    check(ArtifactPage.classify(path: "/new", title: "Claude", body: "How can I help?", frames: 0) == .other, "another claude.ai page")

    // Viewer items: same artifact whatever the title.
    let link = ArtifactLink.parse(url)!
    check(ViewerItem.artifact(link, title: "A").same(as: .artifact(link, title: nil)), "same artifact, different title")
    check(!ViewerItem.artifact(link, title: nil).same(as: .file(URL(fileURLWithPath: "/tmp/a.md"))), "artifact is not a file")

    // Browser choice and config lines
    check(BrowserChoice.parse("zen container Claude Tinkers 2") == BrowserChoice(browser: "zen", kind: .container, name: "Claude Tinkers 2"), "container with spaces")
    check(BrowserChoice.parse("chrome profile Profile 1")?.line == "chrome profile Profile 1", "chrome profile round trip")
    check(BrowserChoice.parse("zen") == BrowserChoice(browser: "zen"), "browser alone")
    check(BrowserChoice.parse("netscape") == nil, "unknown browser")
    let cfg = Config.parse("account = work ~/.claude\naccount = work2 ~/.claude-cldyo2\nartifacts = browser\nbrowser = work2 zen container Claude Tinkers 2\nbrowser = work chrome profile Default\n")
    check(cfg.artifacts == "browser" && cfg.browser(for: "work2").name == "Claude Tinkers 2" && cfg.browser(for: "work").kind == .profile, "config browser lines")
    check(cfg.browser(for: "private") == .systemDefault && Config.parse("").artifacts == "viewer", "defaults: system browser, viewer")
    var text = "notify = true\nbrowser = work zen\nbrowser = work2 zen container A\n"
    text = Config.settingBrowser(account: "work", to: BrowserChoice(browser: "chrome", kind: .profile, name: "Profile 1"), in: text)
    check(text == "notify = true\nbrowser = work chrome profile Profile 1\nbrowser = work2 zen container A\n", "replaces only that account's line, in place")
    text = Config.settingBrowser(account: "work2", to: nil, in: text)
    check(text == "notify = true\nbrowser = work chrome profile Profile 1\n", "nil removes the line")
    text = Config.settingBrowser(account: "private", to: BrowserChoice(browser: "safari"), in: text)
    check(text.hasSuffix("browser = private safari\n"), "appends a new account's line")

    // Discovery from the browsers' own files (names only)
    let ini = "[General]\nStartWithLastProfile=1\n\n[Profile0]\nName=Default (release)\nIsRelative=1\nPath=Profiles/k.Default (release)\n\n[Profile1]\nName=Work\nIsRelative=1\nPath=Profiles/v.Work\nDefault=1\n\n[Install6ED3]\nDefault=Profiles/k.Default (release)\nLocked=1\n"
    check(KnownBrowser.firefoxProfiles(ini: ini) == ["Default (release)", "Work"], "profiles.ini names")
    check(KnownBrowser.firefoxDefaultProfile(ini: ini) == "Profiles/k.Default (release)", "the install's default profile wins")
    check(KnownBrowser.firefoxDefaultProfile(ini: "[Profile0]\nName=A\nPath=Profiles/a\nDefault=1\n") == "Profiles/a", "Default=1 without an install section")
    let containers = #"{"version":5,"identities":[{"userContextId":1,"public":true,"icon":"fingerprint"},{"userContextId":2,"public":true},{"userContextId":5,"public":false,"name":"userContextIdInternal.thumbnail"},{"userContextId":6,"public":true,"name":"Claude Tinkers 2"},{"userContextId":7,"public":true,"l10nID":"userContextShopping.label"}]}"#
    check(KnownBrowser.firefoxContainers(json: Data(containers.utf8)) == ["Personal", "Work", "Claude Tinkers 2", "Shopping"], "containers: built-ins by id, named, l10n, hidden skipped")
    let local = #"{"profile":{"info_cache":{"Default":{"name":"Robin"},"Profile 1":{"name":"Tinkers"}},"profiles_order":["Default","Profile 1"]}}"#
    check(KnownBrowser.chromiumProfiles(localState: Data(local.utf8)).map(\.name) == ["Robin", "Tinkers"], "Chromium profiles in order")
    let cu = KnownBrowser.containerURL(URL(string: url)!, container: "Claude Tinkers 2")?.absoluteString
    check(cu == "ext+container:name=Claude%20Tinkers%202&url=https://claude.ai/artifact/JA5Dkn9y6hkXUiYGi4Pd4r", "ext+container link: \(cu ?? "nil")")
    check(BrowserChoice(browser: "zen", kind: .container, name: "Claude Tinkers 2").title() == "Zen · Claude Tinkers 2 container", "choice title")
}
