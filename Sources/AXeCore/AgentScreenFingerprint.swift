import Foundation

public enum AgentScreenFingerprint {
    /// Accessibility traversal order is not stable for every hierarchy (SpringBoard icon grids
    /// reorder siblings between reads), so lines are sorted before hashing to ignore ordering.
    public static func make(
        screenTextLines: [String],
        elements: [AgentObservedElement]
    ) -> String {
        let material = (screenTextLines.sorted() + [""] + elements.map(elementMaterial).sorted())
            .joined(separator: "\n")
        return hash(material)
    }

    /// 64-bit FNV-1a hash rendered as 16 hex digits.
    public static func hash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func elementMaterial(_ element: AgentObservedElement) -> String {
        [
            element.stableKey,
            element.type ?? "",
            element.label ?? "",
            element.identifier ?? "",
            element.value ?? "",
            String(element.frame.x),
            String(element.frame.y),
            String(element.frame.width),
            String(element.frame.height),
        ].joined(separator: "|")
    }
}
