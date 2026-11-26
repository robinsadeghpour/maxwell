import Foundation

/// Which projects the rail shows: kept ones always, the others while a session there is open.
func railPlanTests() {
    let pinned = ["Orbit", "Acme"]
    let names = RailPlan.order(live: ["Zephyr", "Downloads", "Orbit"], pinned: pinned, ruleOrder: [])
    check(names == ["Orbit", "Acme", "Downloads", "Zephyr"], "kept projects first in their order, with or without sessions; then the rest by name")
    check(RailPlan.order(live: ["b", "a"], pinned: [], ruleOrder: ["b"]) == ["b", "a"], "a config rule orders before the name")
    check(RailPlan.order(live: [], pinned: [], ruleOrder: []).isEmpty, "with no pins, a project whose sessions are gone is gone")
    check(RailPlan.Counts([.working, .idle, .recentlyClosed, .needsYou]) == .init(needsYou: 1, yourTurn: 0, open: 3), "recently closed sessions are not open")

    check(RailPlan.spelled(["maxwell", "Maxwell", "Gone"], like: ["Maxwell"]) == ["Maxwell", "Gone"], "a kept name matches its project whatever the case, once")
    var counts: [String: RailPlan.Counts] = [
        "Orbit": .init(needsYou: 0, yourTurn: 0, open: 2),
        "Zephyr": .init(needsYou: 0, yourTurn: 0, open: 0),        // only recently closed sessions
        "Downloads": .init(needsYou: 0, yourTurn: 0, open: 1),     // a loose folder, quiet
    ]
    check(RailPlan.onRail(names, pinned: pinned, counts: counts, scope: nil) == ["Orbit", "Acme", "Downloads"],
          "a kept project with no sessions stays; a loose folder with an open session shows; one with only closed sessions doesn't")
    check(RailPlan.onRail(names, pinned: pinned, counts: counts, scope: "Zephyr").contains("Zephyr"), "the open scope stays on the rail")
    counts["Zephyr"] = .init(needsYou: 1, yourTurn: 0, open: 1)
    check(RailPlan.onRail(names, pinned: pinned, counts: counts, scope: nil) == ["Orbit", "Acme", "Zephyr", "Downloads"],
          "among the others, those waiting on you come first")
}
