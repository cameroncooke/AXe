import Foundation

/// Output selection is separate from the simulator command parser.
/// File-path --output options after media commands keep their released meaning.
struct CLIOutputInvocation: Sendable {
    let arguments: [String]
    let format: CLIOutputFormat?
    let command: String
    let agent: Bool
    let explicitFormat: Bool
    let selectionError: String?

    init(arguments original: [String]) {
        var remaining: [String] = []
        var commandName: String?
        var selectedFormat: String?
        var requested = false
        var agentRequested = false
        var failure: String?
        var index = 0
        var afterTerminator = false
        let flags: Set<String> = [
            "--agent", "--stdin", "--continue-on-error", "--verbose", "--force", "--uninstall",
            "--print", "--displays", "--follow-active-display", "--semantic-press", "--down",
            "--up", "--allow-lock", "--json", "--selected", "--no-wait", "--help", "-h", "--help-hidden", "--version"
        ]
        while index < original.count {
            let token = original[index]
            if afterTerminator {
                remaining.append(token)
                index += 1
                continue
            }
            if token == "--" {
                afterTerminator = true
                remaining.append(token)
                index += 1
                continue
            }
            let internalCommand = commandName == "hid-broker" || commandName == "slider-read-worker"
                || commandName == "physical-device-broker"
            let mediaPath = commandName == "screenshot" || commandName == "record-video"
            let outputToken = token == "--output" || token.hasPrefix("--output=")
            if outputToken, !mediaPath, !internalCommand {
                // Do not repair a missing value for another option by taking its next token.
                let previous = index > 0 ? original[index - 1] : nil
                let followsValueOption = previous.map {
                    $0.hasPrefix("-") && Double($0) == nil && !$0.contains("=") && !flags.contains($0)
                } ?? false
                let raw: String?
                let consumed: Int
                if token.hasPrefix("--output=") {
                    raw = String(token.dropFirst("--output=".count))
                    consumed = 1
                } else if index + 1 < original.count, !original[index + 1].hasPrefix("-") {
                    raw = original[index + 1]
                    consumed = 2
                } else {
                    raw = nil
                    consumed = 1
                }
                if requested { failure = "--output must be supplied once." }
                requested = true
                selectedFormat = raw
                if raw == nil { failure = "--output requires text or json." }
                else if CLIOutputFormat(rawValue: raw!) == nil { failure = "--output must be text or json." }
                if followsValueOption {
                    remaining.append(contentsOf: original[index..<(index + consumed)])
                }
                index += consumed
                continue
            }
            if commandName == nil, !token.hasPrefix("-") { commandName = token }
            if !internalCommand, token == "--agent" || token.hasPrefix("--agent=") {
                agentRequested = true
            }
            remaining.append(token)
            index += 1
        }
        arguments = remaining
        command = commandName ?? "axe"
        agent = agentRequested
        explicitFormat = requested
        format = requested ? (selectedFormat.flatMap(CLIOutputFormat.init(rawValue:)) ?? .json)
            : (agentRequested ? .json : nil)
        selectionError = failure
    }
}
