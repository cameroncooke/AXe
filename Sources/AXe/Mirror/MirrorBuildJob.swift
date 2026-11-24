#if AXE_MIRROR
import Foundation

/// One archive and export of an app for registered devices, in a folder of its own under the
/// store: the archive, the IPA, the export options used and a log for each step. Two builds at
/// once never share anything. The folder is some hundreds of megabytes, so it goes once the build
/// is published (`discard`) unless it was asked for; a failed build's stays, for its logs.
struct MirrorBuildJob {
    let folder: URL
    private let archive: [String]
    private let export: [String]
    private let workingFolder: URL

    init(store: MirrorBuildStore, project: String?, workspace: String?, scheme: String, configuration: String,
         teamID: String?, exportOptions: String?, allowProvisioningUpdates: Bool) throws {
        let source = URL(fileURLWithPath: ((workspace ?? project ?? "") as NSString).expandingTildeInPath).standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw CLIError(errorDescription: "There is no project or workspace at \(source.path).", code: .invalidArguments)
        }
        workingFolder = source.deletingLastPathComponent()
        folder = store.root.appendingPathComponent(".jobs", isDirectory: true).appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Says whose this is while it is being made, so that no other command's clean-up takes it.
        try String(getpid()).write(to: folder.appendingPathComponent(MirrorBuildStore.runningMarker), atomically: true, encoding: .utf8)

        var options: [String: Any] = ["method": "release-testing", "destination": "export", "thinning": "<none>", "signingStyle": "automatic"]
        if let teamID { options["teamID"] = teamID }
        if let exportOptions {
            let file = URL(fileURLWithPath: (exportOptions as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: file), let given = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CLIError(errorDescription: "The export options at \(file.path) cannot be read.", code: .invalidArguments)
            }
            // Anything else would export a build iOS will not install over the air on a registered device.
            guard given["method"] as? String == "release-testing", (given["destination"] as? String ?? "export") == "export",
                  (given["thinning"] as? String ?? "<none>") == "<none>" else {
                throw CLIError(errorDescription: "The export options must use the method release-testing, the destination export and no thinning.", code: .invalidArguments)
            }
            options = given
        }
        let optionsFile = folder.appendingPathComponent("ExportOptions.plist")
        try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0).write(to: optionsFile)

        let archivePath = folder.appendingPathComponent("App.xcarchive").path
        var archive = ["archive", workspace == nil ? "-project" : "-workspace", source.path, "-scheme", scheme, "-configuration", configuration,
                       "-destination", "generic/platform=iOS", "-archivePath", archivePath, "-derivedDataPath", folder.appendingPathComponent("DerivedData").path]
        var export = ["-exportArchive", "-archivePath", archivePath, "-exportPath", folder.appendingPathComponent("Export").path, "-exportOptionsPlist", optionsFile.path]
        if let teamID { archive.append("DEVELOPMENT_TEAM=" + teamID) }
        if allowProvisioningUpdates {
            archive.append("-allowProvisioningUpdates")
            export.append("-allowProvisioningUpdates")
        }
        self.archive = archive
        self.export = export
    }

    /// Archives and exports. Returns the IPA.
    func run() throws -> URL {
        for (step, arguments) in [("archive", archive), ("export", export)] {
            let log = folder.appendingPathComponent(step + ".log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xcodebuild"] + arguments
            process.currentDirectoryURL = workingFolder
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CLIError(errorDescription: "The \(step) failed. \(Self.lastErrors(in: log))Read \(log.path).", code: .commandFailed)
            }
        }
        let exported = folder.appendingPathComponent("Export", isDirectory: true)
        guard let ipa = (try? FileManager.default.contentsOfDirectory(at: exported, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "ipa" }) else {
            throw CLIError(errorDescription: "The export made no IPA. Read \(folder.appendingPathComponent("export.log").path).", code: .commandFailed)
        }
        return ipa
    }

    /// Removes the folder: the archive, the exported IPA and the logs.
    func discard() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Marks the folder as kept on purpose: the clean-up each later build does leaves it alone, and
    /// only `axe remote builds --clean` removes it.
    func keep() throws {
        try Data().write(to: folder.appendingPathComponent(MirrorBuildStore.keptMarker))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(MirrorBuildStore.runningMarker))
    }

    /// How long a failed build's folder is kept for its logs before the next build removes it.
    static let keepFailedFor: TimeInterval = 3 * 24 * 3600

    /// The last few lines of a log that say what went wrong, for the message.
    private static func lastErrors(in log: URL) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n").filter { $0.contains("error:") }.suffix(3).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.isEmpty ? "" : lines.joined(separator: " ") + " "
    }
}
#endif
