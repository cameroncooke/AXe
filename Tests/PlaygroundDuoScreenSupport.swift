import Foundation
import Testing

/// Prepare one measured Duo display and keep its app launches on that same target.
func withDuoPlaygroundScreen(
    pose: DuoPlaygroundPose, rotation: Int, check: () async throws -> Void
) async throws {
    try #require([0, 90, 180, 270].contains(rotation))
    let app = try DuoPlaygroundSession()
    let original = try await app.catalogue()
    let current = try await app.position(pose, rotation: rotation, boot: original.bootIdentity)
    let preparedRotation = try current.activePanel.rotationDegrees()
    try #require(preparedRotation == rotation)
    print("Duo screen prepared: pose=\(pose.rawValue), rotation=\(rotation), catalogue=\(String(reflecting: current))")
    let target = DuoPlaygroundLaunchTarget(bootIdentity: current.bootIdentity, panel: current.activePanel)
    do {
        try await DuoPlaygroundLaunchTarget.$current.withValue(target) { try await check() }
    } catch {
        let originalFailure = error
        do {
            let observed = try await app.catalogue(boot: original.bootIdentity)
            print("Duo catalogue after failed check: \(String(reflecting: observed))")
        } catch {
            print("Duo catalogue read after failure also failed: \(error)")
        }
        throw originalFailure
    }
    let after = try await app.catalogue(boot: original.bootIdentity)
    print("Duo catalogue after check: \(String(reflecting: after))")
    try #require(after.activePanel == current.activePanel, "The check changed its measured display or geometry.")
}
