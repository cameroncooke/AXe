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
            guard !elementRef.isEmpty, elementRef.utf8.count <= 4096,
                  elementRef == elementRef.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw ValidationError("--ref must be a nonempty exact snapshot ref.")
            }
            try requireSnapshot()
        }
    }

    func requireSnapshot() throws {
        guard snapshotID != nil else {
            throw ValidationError("Agent refs and coordinate actions require --snapshot-id.")
        }
    }
}
