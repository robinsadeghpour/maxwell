import Foundation

/// The title bar's tabs keep their places: new ones open beside the tab on show, visiting never moves one.
func tabRowTests() {
    var row = TabRow()
    row.visit("a", from: nil)
    row.visit("b", from: "a")
    row.visit("c", from: "b")
    check(row.order == ["a", "b", "c"], "each new tab opens after the one on show")
    row.visit("a", from: "c")
    check(row.order == ["a", "b", "c"] && row.recent.first == "a", "visiting a tab doesn't move it")
    row.visit("d", from: "a")
    check(row.order == ["a", "d", "b", "c"], "a new tab opens right after the current one, not at the end")
    row.visit("e", from: nil)
    check(row.order.last == "e", "with nothing on show a new tab goes at the end")

    var full = TabRow()
    for (i, id) in ["1", "2", "3", "4", "5", "6", "7", "8"].enumerated() { full.visit(id, from: i == 0 ? nil : "\(i)") }
    full.visit("1", from: "8")
    full.visit("9", from: "1")
    check(full.order.count == TabRow.cap && !full.contains("2") && full.contains("1") && full.order[1] == "9",
          "a full row drops the tab visited longest ago, and the new one opens beside the current")
    full.visit("10", from: "9")
    check(!full.contains("3") && full.contains("9") && full.contains("10"), "never the tab just opened")

    var hosted = TabRow()
    hosted.visit("a", from: nil)
    hosted.visit("term", from: "a")
    hosted.visit("b", from: "term")
    hosted.replace("term", with: "session")
    check(hosted.order == ["a", "session", "b"] && !hosted.contains("term"), "a terminal that starts claude becomes that session's tab in place")
    hosted.replace("session", with: "term")
    check(hosted.order == ["a", "term", "b"], "and turns back into the terminal when claude exits")
    hosted.replace("a", with: "b")
    check(hosted.order == ["b", "term"] && hosted.recent.count == 2, "an id that already had a tab keeps only one")

    var closing = TabRow()
    closing.visit("a", from: nil)
    closing.visit("b", from: "a")
    closing.visit("c", from: "b")
    closing.visit("a", from: "c")
    closing.visit("c", from: "a")
    check(closing.close("c") == "a", "closing the tab on show shows the one visited most recently")
    check(closing.order == ["a", "b"] && closing.close("b") == "a" && closing.close("a") == nil, "closing the last tab leaves nothing to show")
}
