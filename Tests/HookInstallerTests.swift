import Foundation

/// What install-hooks writes into an account's settings.json, and that uninstall takes it out again.
func hookInstallerTests() {
    func installed(_ text: String) -> OJSON {
        var json = (try? OJSON.parse(text)) ?? .object([])
        HookInstaller.addHooks(&json)
        HookInstaller.addStatusLine(&json)
        return json
    }
    func uninstalled(_ json: OJSON) -> OJSON {
        var json = json
        HookInstaller.removeHooks(&json)
        HookInstaller.removeStatusLine(&json)
        return json
    }

    // Claude Code hands rate_limits only to a status-line command. An account with no status
    // line had nothing for the usage tap to go into, and its usage bars stayed empty.
    let bare = "{\n  \"model\": \"opus\"\n}"
    let withMaxwell = installed(bare)
    check(withMaxwell["statusLine"]?["command"]?.stringValue == HookInstaller.statusLineCommand,
          "an account with no status line gets Maxwell's, so its usage is reported")
    check(withMaxwell["statusLine"]?["type"]?.stringValue == "command", "the status line is a command")
    check(installed(withMaxwell.serialized()) == withMaxwell, "installing twice changes nothing")
    check(uninstalled(withMaxwell).serialized() == bare, "uninstall leaves settings.json as it was")

    let own = "{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \"~/.claude/statusline.sh\"\n  }\n}"
    check(installed(own)["statusLine"]?["command"]?.stringValue == "~/.claude/statusline.sh", "an account's own status line is never replaced")
    check(uninstalled(installed(own)).serialized() == own, "uninstall keeps an account's own status line")

    // After an update, only accounts that already have the hooks get the status line.
    check(!HookInstaller.hasHooks((try? OJSON.parse(bare)) ?? .object([])) && HookInstaller.hasHooks(withMaxwell),
          "hasHooks tells a hooked account from an untouched one")
}
