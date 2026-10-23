import Foundation

enum SliderValueFailure: Error, CustomStringConvertible {
    case rejected(String)
    var description: String {
        switch self { case .rejected(let reason): return reason }
    }
}
