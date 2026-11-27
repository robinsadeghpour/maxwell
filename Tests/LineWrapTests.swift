import Foundation

/// Chips that don't fit on one line wrap instead of running off the edge (New session's accounts, the project nav).
func lineWrapTests() {
    // Six account chips in New session: 94 to 586 leaves 492 points.
    let six: [CGFloat] = [120, 130, 150, 120, 130, 120]
    let at = LineWrap.origins(widths: six, left: 94, right: 586, gap: 6, lineHeight: 34)
    check(zip(at, six).allSatisfy { $0.x + $1 <= 586 }, "no account chip runs past the panel's edge")
    check(at.map(\.y) == [0, 0, 0, 34, 34, 34], "six accounts wrap onto a second line")
    check(LineWrap.lines(at, lineHeight: 34) == 2, "and the panel makes room for two lines")
    check(LineWrap.lines(LineWrap.origins(widths: [120, 130], left: 94, right: 586, gap: 6, lineHeight: 34), lineHeight: 34) == 1, "two accounts stay on one line")
    check(LineWrap.lines([], lineHeight: 34) == 1, "no accounts still keep the row")
    let wide = LineWrap.origins(widths: [600, 50], left: 94, right: 586, gap: 6, lineHeight: 34)
    check(wide.map(\.y) == [0, 34] && wide[0].x == 94, "a chip wider than the space gets a line of its own")
}
