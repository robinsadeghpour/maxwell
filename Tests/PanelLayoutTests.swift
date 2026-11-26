import Foundation

/// Tool windows: layouts saved before each plugin panel was its own still load, plugin panels take
/// the old Plugins panel's place, and a side shows one list or document at a time.
func panelLayoutTests() {
    // Saved by 0.1.74: one "plugins" panel, the bottom area maximized. Enum keys encode as flat lists.
    let old = """
    {"place":["sessions","left","viewer","right","usage","bottom","system","bottom","plugins","right"],
     "order":["sessions","viewer","usage","system","plugins"],"hidden":["viewer"],
     "size":["left",300,"right",520,"bottom",220],"bottomMaximized":true}
    """
    guard var l = PanelLayout.decode(Data(old.utf8)) else { return check(false, "a layout saved by 0.1.74 decodes") }
    check(l.place[.viewer] == .right && l.size[.right] == 520 && l.hidden == [.viewer], "a layout saved by 0.1.74 keeps its places, sizes and hidden panels")
    let linear = PanelID.plugin("linear", "tickets"), slack = PanelID.plugin("slack", "inbox")
    l.adopt(linear)
    l.adopt(slack)
    check(l.place[linear] == .right && l.place[slack] == .right, "plugin panels go where the Plugins panel was")
    check(l.order == [.sessions, .viewer, .usage, .system, .legacyPlugins, linear, slack], "next to it in order")
    check(!l.hidden.contains(linear) && l.hidden.contains(slack), "the first takes over the Plugins panel that was on screen; the next waits on the stripe")

    var fresh = PanelLayout()
    fresh.adopt(linear)
    check(fresh.place[linear] == .right && fresh.hidden.contains(linear), "with no Plugins panel saved, a plugin panel starts hidden on the right")

    let present: Set<PanelID> = Set(PanelID.builtIn + [linear, slack])
    fresh.adopt(slack)
    fresh.show(linear, among: present)
    check(!fresh.hidden.contains(linear) && fresh.hidden.contains(.viewer) && fresh.hidden.contains(slack), "showing one on a side hides the other lists and documents there")
    check(fresh.panels(.right, among: present) == [.viewer, linear, slack], "a side lists its panels in order")
    check(fresh.panels(.right, among: Set(PanelID.builtIn)) == [.viewer], "a plugin that is off isn't listed, and keeps its place")
    fresh.move(.usage, to: .right, among: present)
    check(fresh.place[.usage] == .right && !fresh.hidden.contains(.usage) && !fresh.hidden.contains(linear), "a widget moved to a side stacks beside what shows there")

    fresh.treeWidth = 260
    let again = (try? JSONEncoder().encode(fresh)).flatMap(PanelLayout.decode)
    check(again == fresh, "a layout with plugin panels and a tree width survives saving")
    check(again?.place[PanelID("someone.else")] == nil && PanelID("someone.else").isPlugin, "an unknown name is a plugin panel")
}

/// The viewer lives on the right: layouts saved while it could be moved bring it back there, and
/// nothing moves it away.
func viewerPlaceTests() {
    for side in ["left", "bottom"] {
        // As the build before this one saved it, after "Move Viewer to …".
        let saved = """
        {"place":["sessions","left","viewer","\(side)","usage","bottom","system","bottom"],
         "order":["sessions","usage","system","viewer"],"hidden":["usage"],
         "size":["left",300,"right",520,"bottom",220],"treeWidth":240}
        """
        guard let l = PanelLayout.decode(Data(saved.utf8)) else { check(false, "a layout with the viewer on the \(side) decodes"); continue }
        check(l.place[.viewer] == .right, "a layout that put the viewer on the \(side) loads with it on the right")
        check(l.place[.sessions] == .left && l.hidden == [.usage] && l.size[.right] == 520 && l.treeWidth == 240, "and keeps the rest of it (\(side))")
        check(l.panels(.right, among: Set(PanelID.builtIn)) == [.viewer] && l.panels(.left, among: Set(PanelID.builtIn)) == [.sessions], "the viewer is listed on the right only (\(side))")
    }
    var l = PanelLayout()
    l.move(.viewer, to: .left, among: Set(PanelID.builtIn))
    check(l.place[.viewer] == .right && l == PanelLayout(), "the viewer can't be moved")
    check(!PanelID.viewer.movable && PanelID.sessions.movable && PanelID.plugin("linear", "tickets").movable, "every other panel still moves")
}
