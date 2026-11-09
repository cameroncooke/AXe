import ArgumentParser
import Foundation

extension AgentOutputView: ExpressibleByArgument {}

struct AgentModeOptions: ParsableArguments {
    @Flag(name: .customLong("agent"), help: "Use the optional agent snapshot and action layer. The default command path stays stateless.")
    var enabled = false

    @Option(name: .customLong("view"), help: "Agent output: reading (default), navigation, or full canonical detail. Raw commands are unchanged.")
    var view: AgentOutputView?

    @Option(name: .customLong("snapshot-id"), help: "Agent only: UUID of the snapshot that owns this ref or coordinate action.", transform: { raw in
        guard let uuid = UUID(uuidString: raw) else {
            throw ValidationError("--snapshot-id must be a UUID.")
        }
        return uuid
    })
    var snapshotID: UUID?

    @Option(name: .customLong("ref"), help: "Agent only: element ref from the specified snapshot.")
    var elementRef: String?

    func validate() throws {
        guard enabled else {
            guard snapshotID == nil, elementRef == nil, view == nil else {
                throw ValidationError("--snapshot-id, --ref and --view require --agent.")
            }
            return
        }
        CLIOutput.setAgentView(view ?? .reading)
        if let elementRef {
            guard Self.isReference(elementRef) else {
                throw ValidationError("--ref must be a ref from the capture, such as e12.")
            }
            try requireSnapshot()
        }
    }

    /// `e` followed by a positive decimal ordinal without a leading zero, at most 32 bytes: the
    /// form every capture publishes and the broker accepts.
    static func isReference(_ text: String) -> Bool {
        let digits = text.utf8.dropFirst()
        return text.utf8.count <= 32 && text.utf8.first == UInt8(ascii: "e") && !digits.isEmpty
            && digits.first != UInt8(ascii: "0") && digits.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    func requireSnapshot() throws {
        guard snapshotID != nil else {
            throw ValidationError("Agent refs and coordinate actions require --snapshot-id.")
        }
    }
}
