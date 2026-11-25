import AppKit

/// A tool window around the terminal, JetBrains style: Maxwell's own four, and one per panel a
/// plugin contributes ("linear.tickets"). Saved by name, so a layout keeps a plugin's place while
/// it is switched off and gets it back when it returns.
struct PanelID: RawRepresentable, Hashable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    static let sessions = PanelID("sessions"), viewer = PanelID("viewer"), usage = PanelID("usage"), system = PanelID("system")
    static let builtIn: [PanelID] = [.sessions, .viewer, .usage, .system]
    /// Before 0.1.73 every plugin panel was a tab of one panel with this name; layouts saved then
    /// still name it, and plugin panels take its place.
    static let legacyPlugins = PanelID("plugins")
    static func plugin(_ plugin: PluginID, _ panel: String) -> PanelID { PanelID("\(plugin).\(panel)") }

    var isPlugin: Bool { !Self.builtIn.contains(self) && self != Self.legacyPlugins }
    /// ⌥⌘ and this number shows, focuses or hides the panel (⌥⌘2 is the terminal, ⌥⌘6 the first plugin panel).
    var key: Int? { [Self.sessions: 1, .viewer: 3, .usage: 4, .system: 5][self] }
    /// Lists and documents take what room there is; widgets take what they need.
    var flexible: Bool { self != .usage && self != .system }
    /// Documents and plugin lists fill the window; the session list and the widgets don't need to.
    var canFill: Bool { flexible && self != .sessions }
    /// Maxwell's own panels' names; a plugin panel's comes from its manifest.
    var builtInTitle: String? { Self.builtIn.contains(self) ? rawValue.capitalized : nil }
}

enum Dock: String, CaseIterable, Codable {
    case left, right, bottom
    var title: String { rawValue.capitalized }
}

/// Where every panel sits, which are hidden, and how big each area is.
/// Saved per screen, so the laptop and the external display keep their own arrangement.
struct PanelLayout: Codable, Equatable {
    var place: [PanelID: Dock] = [.sessions: .left, .viewer: .right, .usage: .bottom, .system: .bottom]
    var order: [PanelID] = PanelID.builtIn
    var hidden: Set<PanelID> = []
    var size: [Dock: CGFloat] = [.left: Metrics.side, .right: Metrics.viewer, .bottom: 220]
    /// Share of the first of two lists or documents stacked in one area (sessions over viewer).
    var split: [Dock: CGFloat]?
    /// Height of a bottom area that holds only widgets, once dragged; nil fits the widgets.
    var widgetBottom: CGFloat?
    /// Width of the file tree beside the viewer's page, once dragged; nil is the default.
    var treeWidth: CGFloat?

    /// Panels placed in an area, in order. Only those that exist right now: a plugin panel whose
    /// plugin is off keeps its place in the saved layout but isn't listed.
    func panels(_ d: Dock, among present: Set<PanelID>) -> [PanelID] {
        order.filter { place[$0] == d && present.contains($0) }
    }

    /// A list or document shown in a side area hides the others there: they take turns, like tabs.
    mutating func show(_ p: PanelID, among present: Set<PanelID>) {
        hidden.remove(p)
        if let d = place[p], d != .bottom, p.flexible {
            hidden.formUnion(panels(d, among: present).filter { $0 != p && $0.flexible })
        }
    }

    mutating func move(_ p: PanelID, to d: Dock, among present: Set<PanelID>) {
        place[p] = d
        order.removeAll { $0 == p }
        order.append(p)
        show(p, among: present)
    }

    /// A plugin panel seen for the first time: it goes where the old shared Plugins panel was
    /// (the right by default), next to it in order, and starts hidden unless it takes over the
    /// Plugins panel that was on screen.
    mutating func adopt(_ p: PanelID) {
        guard place[p] == nil else { return }
        let legacy = place[.legacyPlugins]
        place[p] = legacy ?? .right
        let firstHeir = legacy != nil && !order.contains(where: \.isPlugin)
        if let i = order.firstIndex(of: .legacyPlugins) {
            let after = order[i...].lastIndex(where: \.isPlugin) ?? i
            order.insert(p, at: after + 1)
        } else {
            order.append(p)
        }
        if !(firstHeir && !hidden.contains(.legacyPlugins)) { hidden.insert(p) }
    }

    private static func key(_ screen: String) -> String { "Maxwell.layout.\(screen)" }
    static func load(screen: String) -> PanelLayout {
        guard let d = UserDefaults.standard.data(forKey: key(screen)) else { return PanelLayout() }
        return decode(d) ?? PanelLayout()
    }
    static func decode(_ d: Data) -> PanelLayout? {
        guard var l = try? JSONDecoder().decode(PanelLayout.self, from: d) else { return nil }
        for p in PanelID.builtIn where l.place[p] == nil { l.place[p] = PanelLayout().place[p]; l.order.append(p) }
        return l
    }
    func save(screen: String) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key(screen)) }
    }
}

/// A panel's content: where its header is, so the header can be dragged to another area.
protocol PanelContent: NSView {
    var gripRect: NSRect { get }
    /// Height (side areas) or width (bottom) a widget needs; flexible panels return nil.
    func preferredExtent(along d: Dock) -> CGFloat?
    /// Room the panel's own header buttons take on the right; the panel controls sit left of them.
    var controlsInset: CGFloat { get }
}

extension PanelContent {
    var controlsInset: CGFloat { 0 }
}
