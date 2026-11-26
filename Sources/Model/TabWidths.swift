import CoreGraphics

/// How wide the viewer's tabs are. Each is as wide as its title, up to a limit. When they don't fit,
/// the others give up room down to `least` (the tab on show keeps its whole title), and past that
/// the strip scrolls. No tab is ever wider than the strip, so the one on show is always whole on
/// screen, its title cut in the middle when the strip is narrower than it.
enum TabWidths {
    static func fit(_ natural: [CGFloat], active: Int?, in width: CGFloat, least: CGFloat) -> [CGFloat] {
        let room = max(0, width)
        let nat = natural.map { min($0, room) }
        let total = nat.reduce(0, +)
        guard total > room, total > 0 else { return nat }
        let give = nat.indices.map { $0 == active ? 0 : max(0, nat[$0] - least) }
        let spare = give.reduce(0, +)
        guard spare > 0 else { return nat }
        let k = min(1, (total - room) / spare)
        return nat.indices.map { nat[$0] - give[$0] * k }
    }
}
