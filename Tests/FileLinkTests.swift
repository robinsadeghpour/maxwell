import Foundation

/// A path in a session's output opens the file it names, wherever Ghostty's link finder cut it.
func fileLinkTests() {
    let files: Set<String> = ["/p/notes/audit.md", "/p/Sources/App.swift", "/h/todo.txt", "/wt/README.md"]
    func open(_ raw: String, _ bases: [String] = ["/p"]) -> String? {
        FileLink.resolve(raw, bases: bases, home: "/h", isFile: files.contains)?.path
    }
    check(open("notes/audit.md") == "/p/notes/audit.md", "a bare relative path opens from the session's folder")
    check(open("notes/audit.md.") == "/p/notes/audit.md", "the full stop ending the sentence is left off")
    check(open("notes/audit.md),") == "/p/notes/audit.md", "closing brackets and commas after the path are left off")
    check(open("Sources/App.swift:42:7") == "/p/Sources/App.swift", "line and column after the path are left off")
    check(open("Sources/App.swift:42.") == "/p/Sources/App.swift", "a line number and a full stop are both left off")
    check(open("/p/notes/audit.md") == "/p/notes/audit.md", "an absolute path opens as is")
    check(open("file:///p/notes/audit.md") == "/p/notes/audit.md", "a file URL opens its path")
    check(open("~/todo.txt") == "/h/todo.txt", "~ is the home folder")
    check(open("./notes/../notes/audit.md") == "/p/notes/audit.md", "dots in the path are resolved")
    check(open("README.md", ["/p", "/wt"]) == "/wt/README.md", "the next folder is tried when the first has no such file")
    check(open("notes") == nil, "a folder isn't claimed: the viewer shows files")
    check(open("notes/missing.md") == nil, "a path to nothing isn't claimed, so the click goes to Claude Code")
    check(open("https://example.com/a.md") == nil, "web links aren't files")
}

/// The underline covers what opens, not the full stop after it.
func fileLinkUnderlineTests() {
    check(FileLink.withoutTrailingPunctuation("docs/plan.md.") == "docs/plan.md", "the full stop isn't underlined")
    check(FileLink.withoutTrailingPunctuation("App.swift:42") == "App.swift:42", "a line number stays underlined")
    check(FileLink.withoutTrailingPunctuation("(see docs/plan.md)") == "(see docs/plan.md", "only the end is trimmed")
}
