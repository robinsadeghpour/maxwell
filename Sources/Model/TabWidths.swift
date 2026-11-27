import CoreGraphics

/// How wide the viewer's tabs are. Each is as wide as its title, up to a limit. When they don't fit,
/// the others give up room down to `least` (the tab on show keeps its whole title). No tab is ever
/// wider than the strip, so the one on show is always whole on screen, its title cut in the middle
/// when the strip is narrower than it.
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

    struct Layout: Equatable {
        /// The tabs on show, a run of neighbours; the rest wait in ⌄.
        var shown: Range<Int>
        /// Every tab's width; 0 for one out of sight.
        var widths: [CGFloat]
        /// Some tabs wait in ⌄, which takes `list` at the end.
        var overflow: Bool
    }

    /// Which tabs show in `width`, and how wide. All of them while each can keep `least` (the tab on
    /// show its whole title). Otherwise as many neighbours of the tab on show as fit at `least`,
    /// from the first tab when that reaches it, beside ⌄; they share all of that room, so no empty
    /// strip sits next to ⌄.
    static func layout(_ natural: [CGFloat], active: Int?, in width: CGFloat, least: CGFloat, list: CGFloat) -> Layout {
        let n = natural.count
        guard n > 0 else { return Layout(shown: 0..<0, widths: [], overflow: false) }
        let a = active.flatMap { natural.indices.contains($0) ? $0 : nil }
        func need(_ i: Int, _ room: CGFloat) -> CGFloat { i == a ? min(natural[i], room) : min(natural[i], least) }
        if natural.indices.map({ need($0, width) }).reduce(0, +) <= width + 0.5 {
            return Layout(shown: 0..<n, widths: fit(natural, active: a, in: width, least: least), overflow: false)
        }
        let room = max(0, width - list)
        var lo = 0, hi = 0, used: CGFloat = 0
        while hi < n, used + need(hi, room) <= room + 0.5 { used += need(hi, room); hi += 1 }
        if let a, a >= hi {
            lo = a; hi = a + 1; used = need(a, room)
            while lo > 0, used + need(lo - 1, room) <= room + 0.5 { lo -= 1; used += need(lo, room) }
        }
        hi = max(hi, lo + 1)
        let fitted = fit(Array(natural[lo..<hi]), active: a.map { $0 - lo }, in: room, least: least)
        let spare = max(0, room - fitted.reduce(0, +)) / CGFloat(fitted.count)
        var widths = [CGFloat](repeating: 0, count: n)
        for (k, w) in fitted.enumerated() { widths[lo + k] = w + spare }
        return Layout(shown: lo..<hi, widths: widths, overflow: true)
    }
}
