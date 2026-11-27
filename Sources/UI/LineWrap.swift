import Foundation

/// Lays items left to right and starts a new line when the next one would cross `right`.
/// A line always takes at least one item, so an item wider than the space still shows.
enum LineWrap {
    static func origins(widths: [CGFloat], left: CGFloat, right: CGFloat, gap: CGFloat, lineHeight: CGFloat) -> [CGPoint] {
        var x = left, y: CGFloat = 0, out: [CGPoint] = []
        for w in widths {
            if x > left, x + w > right { x = left; y += lineHeight }
            out.append(CGPoint(x: x, y: y))
            x += w + gap
        }
        return out
    }

    /// How many lines `origins` uses; one when there is nothing to lay out.
    static func lines(_ origins: [CGPoint], lineHeight: CGFloat) -> Int {
        Int(((origins.last?.y ?? 0) / lineHeight).rounded()) + 1
    }
}
