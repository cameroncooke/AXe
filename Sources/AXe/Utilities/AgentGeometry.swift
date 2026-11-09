import CoreGraphics

extension CGRect {
    /// Finite, with a positive area: a frame an agent action can be planned and checked in.
    /// Missing or malformed geometry never proves where a control is.
    var isUsableAgentFrame: Bool {
        [origin.x, origin.y, size.width, size.height].allSatisfy(\.isFinite) && size.width > 0 && size.height > 0
    }
}
