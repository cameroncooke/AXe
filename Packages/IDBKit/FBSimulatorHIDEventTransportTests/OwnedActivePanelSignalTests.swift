import Darwin
import Testing
@testable import FBSimulatorControl

@Suite("Owned active-panel child signal defaults")
struct OwnedActivePanelSignalTests {
    @Test func resetsOnlyInterruptAndTerminationWithExplicitSpawnFlag() throws {
        var attributes: posix_spawnattr_t?
        try #require(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        try #require(OwnedActivePanelChild.configureSignalDefaults(&attributes) == 0)
        var defaults = sigset_t()
        var flags: Int16 = 0
        try #require(posix_spawnattr_getsigdefault(&attributes, &defaults) == 0)
        try #require(posix_spawnattr_getflags(&attributes, &flags) == 0)
        #expect(sigismember(&defaults, SIGINT) == 1)
        #expect(sigismember(&defaults, SIGTERM) == 1)
        #expect(sigismember(&defaults, SIGPIPE) == 0)
        #expect(flags == Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
    }
}
