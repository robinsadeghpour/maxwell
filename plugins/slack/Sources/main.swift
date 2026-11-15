import Foundation

// maxwell-slack            the plugin, speaking Maxwell's protocol on stdin/stdout
// maxwell-slack list FILE  prints who is waiting, from a fixture file (for tuning the rules)
// maxwell-slack manifest   prints the Slack app manifest and its "create app" link

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments.dropFirst()
switch args.first {
case "list":
    let url = URL(fileURLWithPath: args.dropFirst().first ?? "fixtures.json")
    let s = try FixtureSource(url: url).fetch(since: .distantPast)
    let now = Date()
    for w in Rules.waiting(s, now: now) {
        print("\(Panel.age(w.since, now: now))\t\(w.who)\t\(w.place)\t\(w.kind.rawValue)\t\(w.ask)\t[\(w.reason)]")
    }
case "manifest":
    let d = try JSONSerialization.data(withJSONObject: Manifest.app, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(data: d, encoding: .utf8)!)
    print(Manifest.createAppURL)
default:
    Plugin(wire: Wire()).start()
}
