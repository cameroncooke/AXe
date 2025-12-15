import Foundation

struct AccessibilityElement: Decodable {
    struct Frame: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    
    let type: String?
    let frame: Frame?
    let children: [AccessibilityElement]?
    
    let AXLabel: String?
    let AXUniqueId: String?
    
    var normalizedLabel: String? {
        AXLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var normalizedUniqueId: String? {
        AXUniqueId?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func flattened() -> [AccessibilityElement] {
        var result: [AccessibilityElement] = [self]
        if let children {
            result.append(contentsOf: children.flatMap { $0.flattened() })
        }
        return result
    }
}
