import Testing
@testable import AXe

/// `axe --version` prints the version alone on its first line, so tools that read it keep working,
/// then the copyright and licence notice that ADDITIONAL_TERMS.md requires anyone who conveys AXe to keep.
@Suite("Version notice")
struct VersionNoticeTests {
    @Test("axe --version prints the version on the first line, then the copyright and licence notice")
    func versionThenNotice() {
        let lines = Axe.configuration.version.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == VERSION)
        #expect(lines.dropFirst().joined(separator: "\n") == Axe.copyrightNotice)
        #expect(Axe.copyrightNotice.hasPrefix("Copyright © Cameron Cooke and AXe contributors."))
        #expect(Axe.copyrightNotice.contains("ADDITIONAL_TERMS.md"))
    }
}
