import Foundation

enum CLIOutputText {
    static func render(_ result: CLIOutputValue) -> String {
        if result["schema"]?.stringValue == "axe.output.agent-result" {
            return agent(result)
        }
        var lines: [String] = []
        if let error = result["error"] {
            lines.append("ERROR \(error["code"]?.scalarText ?? "commandFailed"): \(error["message"]?.scalarText ?? "Command failed.")")
        } else {
            lines.append("OK \(result["command"]?.scalarText ?? "axe")")
        }
        if let data = result["data"] { lines += fields(data, indent: "") }
        return lines.joined(separator: "\n")
    }

    private static func agent(_ result: CLIOutputValue) -> String {
        if result["schemaVersion"]?.stringValue == "2" { return adaptiveAgent(result) }
        var lines: [String] = []
        if let error = result["error"] {
            lines.append("ERROR \(error["code"]?.scalarText ?? "commandFailed"): \(error["message"]?.scalarText ?? "Command failed.")")
        }
        let data = result["data"]
        if let capture = data?["capture"] {
            let snapshot = capture["snapshotID"]?.scalarText ?? ""
            let seq = capture["seq"]?.scalarText ?? ""
            let pid = capture["applicationPID"]?.scalarText ?? ""
            lines.append("RS/1 snapshotID=\(snapshot) seq=\(seq) appPID=\(pid)")
            if let context = capture["context"] {
                let screen = context["screenID"]?.scalarText ?? ""
                let rotation = context["rotationDegrees"]?.scalarText ?? ""
                lines.append("screen=\(screen) rotation=\(rotation) hash=\(capture["screenHash"]?.scalarText ?? "")")
            }
            lines.append("rows offset=\(capture["rowOffset"]?.scalarText ?? "0") limit=\(capture["rowLimit"]?.scalarText ?? "") expires=\(capture["expiresInSeconds"]?.scalarText ?? "")")
            for section in ["targets", "scroll", "text"] {
                guard let rows = capture[section]?.arrayValue, !rows.isEmpty else { continue }
                lines.append(section + ":")
                lines += rows.compactMap(\.stringValue)
            }
            let shown: Set<String> = [
                "snapshotID", "seq", "applicationPID", "screenHash", "rowOffset",
                "rowLimit", "expiresInSeconds", "targets", "scroll", "text"
            ]
            let remaining = unhandled(capture, excluding: shown)
            if !remaining.isEmpty {
                lines.append("capture:")
                lines += fields(.object(remaining), indent: "  ")
            }
        }
        if let action = data?["action"] {
            lines.append("action:")
            lines += fields(action, indent: "  ")
        }
        if let batch = data?["batch"] {
            lines.append("batch:")
            lines += fields(batch, indent: "  ")
        }
        if let cache = data?["cache"] {
            var line = "cache: \(cache["status"]?.scalarText ?? "")"
            if let reason = cache["reason"]?.scalarText { line += " reason=\(reason)" }
            line += " requiresRefresh=\(cache["requiresRefresh"]?.scalarText ?? "")"
            lines.append(line)
        }
        if let data {
            let remaining = unhandled(data, excluding: ["capture", "action", "batch", "cache"])
            if !remaining.isEmpty {
                lines.append("details:")
                lines += fields(.object(remaining), indent: "  ")
            }
        }
        for step in result["nextSteps"]?.arrayValue ?? [] {
            if let text = step.stringValue { lines.append("Next: " + text) }
        }
        return lines.isEmpty ? "RS/1" : lines.joined(separator: "\n")
    }

    private static func adaptiveAgent(_ result: CLIOutputValue) -> String {
        var lines: [String] = []
        if let error = result["error"] {
            lines.append("ERROR \(error["code"]?.scalarText ?? "commandFailed"): \(error["message"]?.scalarText ?? "Command failed.")")
        }
        let data = result["data"]
        if let capture = data?["capture"] {
            let unchanged = capture["unchanged"]?.boolValue == true ? " unchanged" : ""
            lines.append("RS/1 v2 snapshotID=\(capture["snapshotID"]?.scalarText ?? "") expires=\(capture["expiresInSeconds"]?.scalarText ?? "")\(unchanged)")
            if let hash = capture["screenHash"]?.scalarText { lines.append("hash=" + hash) }
            lines += (capture["rows"]?.arrayValue ?? []).compactMap(\.stringValue)
            let remaining = unhandled(capture, excluding: ["snapshotID", "expiresInSeconds", "unchanged", "screenHash", "rows"])
            lines += fields(.object(remaining), indent: "")
        }
        if let data {
            lines += fields(.object(unhandled(data, excluding: ["capture"])), indent: "")
        }
        for step in result["nextSteps"]?.arrayValue ?? [] {
            if let text = step.stringValue { lines.append("Next: " + text) }
        }
        return lines.isEmpty ? "RS/1 v2" : lines.joined(separator: "\n")
    }

    private static func unhandled(_ value: CLIOutputValue,
                                  excluding keys: Set<String>) -> [String: CLIOutputValue] {
        guard case let .object(values) = value else { return [:] }
        return values.filter { !keys.contains($0.key) }
    }

    private static func fields(_ value: CLIOutputValue, indent: String) -> [String] {
        switch value {
        case let .object(values):
            return values.keys.sorted().flatMap { key -> [String] in
                guard let child = values[key] else { return [] }
                if let scalar = child.scalarText { return [indent + key + ": " + scalar] }
                return [indent + key + ":"] + fields(child, indent: indent + "  ")
            }
        case let .array(values):
            return values.flatMap { child -> [String] in
                if let scalar = child.scalarText { return [indent + scalar] }
                return [indent + "-"] + fields(child, indent: indent + "  ")
            }
        default: return [indent + (value.scalarText ?? "")]
        }
    }
}
