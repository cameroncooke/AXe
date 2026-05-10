import Foundation

public enum OrientationCoordinateMath {
    public enum Orientation: String, CaseIterable, Sendable {
        case portrait
        case portraitUpsideDown
        case landscape
        case landscapeFlipped

        public var isLandscape: Bool {
            self == .landscape || self == .landscapeFlipped
        }
    }

    public static func translateToPhysical(
        x: Double,
        y: Double,
        orientation: Orientation,
        portraitWidth: Double,
        portraitHeight: Double
    ) -> (x: Double, y: Double) {
        switch orientation {
        case .portrait:
            return (x, y)

        case .portraitUpsideDown:
            return (x: portraitWidth - x, y: portraitHeight - y)

        case .landscape:
            return (x: y, y: portraitHeight - x)

        case .landscapeFlipped:
            return (x: portraitWidth - y, y: x)
        }
    }

    public static func letterboxToPhysical(
        x: Double,
        y: Double,
        scale: Double,
        offsetX: Double,
        offsetY: Double
    ) -> (x: Double, y: Double) {
        return (
            x: offsetX + x * scale,
            y: offsetY + y * scale
        )
    }

    public static func letterboxParameters(
        logicalWidth: Double,
        logicalHeight: Double,
        physicalWidth: Double,
        physicalHeight: Double
    ) -> (scale: Double, offsetX: Double, offsetY: Double) {
        let scale = min(physicalWidth / logicalWidth, physicalHeight / logicalHeight)
        let offsetX = (physicalWidth - logicalWidth * scale) / 2
        let offsetY = (physicalHeight - logicalHeight * scale) / 2
        return (scale, offsetX, offsetY)
    }
}
