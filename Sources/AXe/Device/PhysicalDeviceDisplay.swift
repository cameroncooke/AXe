import AXeCore
import Foundation

/// A raw primary-display snapshot plus the point geometry AXe derives from it.
///
/// The digitizer uses a device-portrait frame: the mode size, with its axes swapped when the
/// panel's native orientation is `rot90` or `rot270`. The interface rotation is
/// `(currentOrientation + nativeOrientation) mod 360`. This was verified on an iPhone (native `rot0`)
/// and, with physical rotation and orientation lock, on an iPad Pro (native `rot270`).
///
/// On the iPad a simulated rotation sometimes left `currentOrientation` at its previous value while the
/// interface turned. There, the reported device orientation followed the interface in every check,
/// including under orientation lock, so AXe refuses touches when the two disagree. iPhones are exempt:
/// an iPhone reports `portraitUpsideDown` while its interface stays in landscape.
/// Equality compares the raw snapshot, so callers can detect display changes.
struct PhysicalDeviceDisplay: Codable, Sendable, Equatable {
    private let modeWidth: Double
    private let modeHeight: Double
    private let scale: Double
    private let nativeOrientation: String
    private let currentOrientation: String
    /// The reported non-flat device orientation, recorded only on panels whose native orientation is not `rot0`.
    private let sensorOrientation: String?
    private let orientation: OrientationCoordinateMath.Orientation
    /// The primary display's ID, which the native display stream requests; nil when the reply omits it.
    let displayID: Int64?

    var width: Double {
        get throws { try resolvedOrientation().isLandscape ? portraitHeight : portraitWidth }
    }

    var height: Double {
        get throws { try resolvedOrientation().isLandscape ? portraitWidth : portraitHeight }
    }

    private var swapsAxes: Bool { nativeOrientation == "rot90" || nativeOrientation == "rot270" }
    private var portraitWidth: Double { (swapsAxes ? modeHeight : modeWidth) / scale }
    private var portraitHeight: Double { (swapsAxes ? modeWidth : modeHeight) / scale }

    init(response: [String: RemoteXPCValue]) throws {
        let output = response["CoreDevice.output"]?.dictionaryValue
        let displays = output?["displays"]?.arrayValue ?? []
        let primary = displays.compactMap(\.dictionaryValue).filter {
            $0["primary"] == .bool(true) && $0["external"] == .bool(false)
        }
        guard output?["current"] == .bool(true),
              primary.count == 1, let display = primary.first,
              let native = display["nativeOrientation"]?.stringValue,
              let current = display["currentOrientation"]?.stringValue,
              let mode = display["currentMode"]?.dictionaryValue,
              let size = mode["size"]?.arrayValue, size.count == 2,
              let pixelWidth = size[0].number, let pixelHeight = size[1].number,
              let scale = mode["preferredUIScale"]?.number,
              pixelWidth.isFinite, pixelHeight.isFinite, scale.isFinite,
              pixelWidth > 0, pixelHeight > 0, scale > 0 else {
            throw DeviceServiceError.invalidProtocol("could not read the primary device display")
        }
        guard let nativeDegrees = Self.displayDegrees[native], let currentDegrees = Self.displayDegrees[current] else {
            throw DeviceServiceError.invalidProtocol("the primary device display reported an unknown orientation")
        }
        guard (pixelWidth / scale).isFinite, (pixelHeight / scale).isFinite else {
            throw DeviceServiceError.invalidProtocol("the primary device display reported an invalid scale")
        }
        displayID = display["displayId"]?.integer.flatMap { Int64(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil }
        modeWidth = pixelWidth
        modeHeight = pixelHeight
        self.scale = scale
        nativeOrientation = native
        currentOrientation = current
        orientation = Self.interfaceOrientation[(currentDegrees + nativeDegrees) % 360] ?? .portrait
        sensorOrientation = native == "rot0" ? nil
            : output?["orientation"]?.dictionaryValue?["currentDeviceNonFlatOrientation"]?.stringValue ?? Self.missingSensor
    }

    /// Clockwise degrees that turn a frame in the panel's native orientation, such as native H.264 video,
    /// upright for the current interface.
    var nativeFrameRotation: Int { Self.displayDegrees[currentOrientation] ?? 0 }

    /// Whether the display shows the interface orientation for a reported device orientation.
    func matches(deviceOrientation: String) -> Bool {
        Self.deviceOrientation[deviceOrientation] == orientation
    }

    func normalized(_ point: CGPoint) throws -> RemoteXPCValue {
        let orientation = try resolvedOrientation()
        let width = try width, height = try height
        let x = Double(point.x)
        let y = Double(point.y)
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < width, y < height else {
            throw CLIOutputFailure(code: "pointOutsideDisplay",
                message: "Touch points must lie inside the \(width) × \(height) point device display.")
        }
        let portrait = OrientationCoordinateMath.translateToPhysical(x: x, y: y, orientation: orientation,
            portraitWidth: portraitWidth, portraitHeight: portraitHeight)
        return .dictionary(["x": .double(portrait.x / portraitWidth), "y": .double(portrait.y / portraitHeight)])
    }

    func wireEdge(_ edge: PhysicalTouchEdge) throws -> UInt64 {
        switch (try resolvedOrientation(), edge) {
        case (_, .none), (.portrait, .top), (.portraitUpsideDown, .bottom), (.landscapeFlipped, .left):
            return 0
        case (.portrait, .left), (.landscape, .top), (.landscapeFlipped, .bottom):
            return 1
        case (.portrait, .bottom), (.landscape, .left), (.portraitUpsideDown, .top):
            return 3
        default:
            throw CLIOutputFailure(code: "unsupportedOnDevice",
                message: "This edge gesture is unavailable in the current device display orientation.")
        }
    }

    /// Refuses commands that need the interface orientation when the display state is not trustworthy.
    func requireResolvedOrientation() throws {
        _ = try resolvedOrientation()
    }

    private func resolvedOrientation() throws -> OrientationCoordinateMath.Orientation {
        if sensorOrientation == Self.missingSensor {
            throw CLIOutputFailure(code: "displayOrientationMismatch",
                message: "The device did not report its orientation, so AXe cannot confirm the display orientation. "
                    + "AXe sent no input. Read the screen again.")
        }
        if let sensorOrientation, let reported = Self.deviceOrientation[sensorOrientation], reported != orientation {
            throw CLIOutputFailure(code: "displayOrientationMismatch",
                message: "The device reports \(sensorOrientation), but its display reports a different orientation. "
                    + "This happens after some simulated rotations, or when the app does not support the device "
                    + "orientation. AXe sent no input. Rotate the device again, or to an orientation the app supports.")
        }
        return orientation
    }

    /// Recorded when the reply has no orientation field. A reported value such as `unknown` (flat since
    /// boot) is kept and accepted; only a missing field refuses, because the check cannot run at all.
    private static let missingSensor = "<missing>"
    private static let displayDegrees = ["rot0": 0, "rot90": 90, "rot180": 180, "rot270": 270]
    private static let interfaceOrientation: [Int: OrientationCoordinateMath.Orientation] = [
        0: .portrait, 90: .landscape, 180: .portraitUpsideDown, 270: .landscapeFlipped,
    ]
    /// Device orientation names as CoreDevice reports them, mapped to the matching interface orientation.
    private static let deviceOrientation: [String: OrientationCoordinateMath.Orientation] = [
        "portrait": .portrait, "landscapeRight": .landscape,
        "portraitUpsideDown": .portraitUpsideDown, "landscapeLeft": .landscapeFlipped,
    ]
}
