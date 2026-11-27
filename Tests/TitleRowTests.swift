import Foundation

/// The title bar's row: session tabs keep a readable width and overflow into ⌄; beside a filling
/// session the document on show takes what it needs, never more than leaves one session tab.
func titleRowTests() {
    let all = TitleRow.sessions(count: 4, current: 0, room: 1000)
    check(all.shown == [0, 1, 2, 3] && all.width == TitleRow.sessionMost && !all.overflow, "room for every tab: each as wide as it may be")
    let tight = TitleRow.sessions(count: 6, current: 1, room: 500)
    check(tight.overflow && tight.shown == [0, 1, 2] && tight.width >= TitleRow.sessionLeast, "short of room: as many as fit at their least width, the rest in ⌄")
    let far = TitleRow.sessions(count: 6, current: 5, room: 500)
    check(far.shown == [0, 1, 5], "the tab on show is always among them, in its order")
    let one = TitleRow.sessions(count: 3, current: 2, room: 130)
    check(one.shown == [2] && one.overflow, "at the narrowest, only the tab on show")
    check(TitleRow.sessions(count: 0, current: nil, room: 500).shown.isEmpty, "no tabs, nothing to show")

    check(TitleRow.split(line: 1000, tabsEnd: 700, end: 1340, docsLeast: 250) == 1000, "beside the viewer the line is the pane line while the docs fit")
    check(TitleRow.split(line: 600, tabsEnd: 400, end: 800, docsLeast: 300) == 500, "too narrow: the docs take empty title bar to the left")
    check(TitleRow.split(line: 600, tabsEnd: 560, end: 800, docsLeast: 300) == 560, "but never a session tab, its ⌄ or +")
    check(TitleRow.peekSplit(start: 114, end: 1340, docsLeast: 200, reserve: 30) == 1140, "the waiting document takes what it needs at the right")
    check(TitleRow.peekSplit(start: 114, end: 700, docsLeast: 600, reserve: 30) == 264, "but never more than leaves one session tab and +")
}
