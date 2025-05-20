//import ArgumentParser
//import Foundation
//
//struct SimulatorUtils: ParsableCommand {
//    static let configuration = CommandConfiguration(
//        abstract: "A utility to interact with iOS Simulators.",
//        subcommands: [DescribeUI.self, ListSimulators.self] // Added ListSimulators for convenience
//    )
//}
//
//// Helper to print to stderr
//func printStdErr(_ message: String) {
//    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
//}
//
//// Helper function to wait for FBFuture completion
//func awaitFuture<T>(_ future: FBFuture<T>) throws -> Any? {
//    var resultValue: Any?
//    var resultError: Error?
//    let group = DispatchGroup()
//    group.enter()
//    
//    future.onQueue(DispatchQueue.global(), notifyOfCompletion: { future in
//        if let error = future.error {
//            resultError = error
//        } else {
//            resultValue = future.result
//        }
//        group.leave()
//    })
//    
//    group.wait() // Blocks until the future is resolved
//    
//    if let error = resultError {
//        throw error
//    }
//    return resultValue
//}
//
//
//struct DescribeUI: ParsableCommand {
//    static let configuration = CommandConfiguration(abstract: "Describes the UI hierarchy of a booted simulator.")
//
//    @Argument(help: "The UDID of the simulator.")
//    var simulatorUDID: String
//
//    func run() throws {
//        // Create configuration - logger is set internally
//        let controlConfig = FBSimulatorControlConfiguration()
//
//        let control = try FBSimulatorControl.withConfiguration(controlConfig)
//        guard let simulator = control.set.simulator(withUDID: simulatorUDID) else {
//            printStdErr("Simulator with UDID \(simulatorUDID) not found.")
//            throw ExitCode.failure
//        }
//
//        // Ensure simulator is booted
//        if simulator.state != FBiOSTargetState.booted {
//            printStdErr("Simulator \(simulatorUDID) is not booted. Attempting to boot...")
//            let bootConfig = FBSimulatorBootConfiguration()
//            // FBSimulatorControl is Obj-C, futures are not directly Swift async/await
//            // We need to wait for the future to complete.
//            let bootFuture = simulator.boot(bootConfig)
//            do {
//                _ = try awaitFuture(bootFuture)
//                printStdErr("Simulator booted successfully.")
//            } catch {
//                printStdErr("Failed to boot simulator \(simulatorUDID): \(error)")
//                throw ExitCode.failure
//            }
//            // Add a small delay to allow services to start after boot, accessibility might not be immediately available
//            Thread.sleep(forTimeInterval: 5.0)
//        }
//        
////        let _ = try awaitFuture(simulator.connectToHID())
//
//        printStdErr("Fetching UI hierarchy for \(simulator.name) (\(simulatorUDID))...")
//
//        // FBAccessibilityCommands is conformed to by FBSimulator
//        let accessibilityFuture = simulator.accessibilityElements(withNestedFormat: true)
//
//        do {
//            guard let hierarchy = try awaitFuture(accessibilityFuture) as? [Any] else {
//                 printStdErr("Failed to get accessibility hierarchy or result was not in the expected format.")
//                 throw ExitCode.failure
//            }
//
//            let jsonData = try JSONSerialization.data(withJSONObject: hierarchy, options: [.prettyPrinted, .fragmentsAllowed])
//            if let jsonString = String(data: jsonData, encoding: .utf8) {
//                print(jsonString)
//            } else {
//                printStdErr("Error converting JSON data to string for UI hierarchy.")
//                throw ExitCode.failure
//            }
//        } catch {
//            printStdErr("Error fetching or serializing UI hierarchy: \(error)")
//            throw ExitCode.failure
//        }
//    }
//}
//
//// Added a simple command to list simulators for easier UDID lookup
//struct ListSimulators: ParsableCommand {
//    static let configuration = CommandConfiguration(abstract: "Lists all available simulators (UDID and Name).")
//
//    struct SimulatorBasicInfo: Codable {
//        let udid: String
//        let name: String
//        let state: String
//    }
//
//    func run() throws {
//        // Create configuration
//        let controlConfig = FBSimulatorControlConfiguration()
//        
//        let control = try FBSimulatorControl.withConfiguration(controlConfig)
//        let simulators = control.set.allSimulators
//        var infos: [SimulatorBasicInfo] = []
//
//        for sim in simulators {
//            // Convert the state enum to a string representation
//            let stateString = String(describing: sim.state)
//            infos.append(SimulatorBasicInfo(udid: sim.udid, name: sim.name, state: stateString))
//        }
//
//        let encoder = JSONEncoder()
//        encoder.outputFormatting = .prettyPrinted
//        let jsonData = try encoder.encode(infos)
//        if let jsonString = String(data: jsonData, encoding: .utf8) {
//            print(jsonString)
//        }
//    }
//}
//
//
//SimulatorUtils.main()

import Foundation
import FBControlCore
import FBSimulatorControl
import CompanionLib

@objc final class EmptyEventReporter: NSObject, FBEventReporter {
  @objc static let shared = EmptyEventReporter()
  var metadata: [String: String] = [:]
  func report(_ subject: FBEventReporterSubject) {}
  func addMetadata(_ metadata: [String: String]) {}
}

func getSimulatorSet(
    deviceSetPath: String?,
    logger: FBControlCoreLogger,
    reporter: FBEventReporter
) async throws -> FBSimulatorSet {
    let configuration = FBSimulatorControlConfiguration(
        deviceSetPath: deviceSetPath,
        logger: logger,
        reporter: reporter
    )

    do {
        let controlSet = try FBSimulatorControl.withConfiguration(configuration)
        logger.info().log("FBSimulatorControl initialized.")
        return controlSet.set
    } catch {
        logger.info().log("FBSimulatorControl failed to initialize.")
        throw error
    }
}

@MainActor
struct AccessibilityFetcher {
    static let simulatorUDID = "B34FF305-5EA8-412B-943F-1D0371CA17FF"

    static func main(logger: FBIDBLogger) async {
        logger.info().log("IDB Accessibility Info Fetcher started for simulator UDID: \(simulatorUDID)")

        do {
            // Passing nil for deviceSetPath to use the default.
            let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
            let targetSets: [FBiOSTargetSet] = [simulatorSet]
            logger.info().log("FBSimulatorSet obtained.")

            let targetFuture = FBiOSTargetProvider.target(
                withUDID: simulatorUDID,
                targetSets: targetSets,
                warmUp: true,
                logger: logger
            )
            
            let target: FBiOSTarget = try await BridgeFuture.value(targetFuture)
            logger.info().log("Target obtained: \(target.udid) - \(target.name), State: \(FBiOSTargetStateStringFromState(target.state))")

            let storageManager: FBIDBStorageManager
            do  {
                storageManager = try FBIDBStorageManager(for: target, logger: logger)
                logger.info().log("FBIDBStorageManager initialized.")
            } catch {
                logger.info().log("Failed to initialize FBIDBStorageManager.")
                throw error
            }

            let temporaryDirectory = FBTemporaryDirectory(logger: logger)
            logger.info().log("FBTemporaryDirectory initialized")

            // Using 0 for debugserverPort as it's not needed for fetching accessibility info.
            let commandExecutor = FBIDBCommandExecutor(
                for: target,
                storageManager: storageManager,
                temporaryDirectory: temporaryDirectory,
                debugserverPort: 0,
                logger: logger
            )
            logger.info().log("FBIDBCommandExecutor initialized.")

            // Passing nil for point to get info for the whole screen.
            // nestedFormat: true for detailed (legacy) format.
            logger.info().log("Fetching accessibility info for the entire screen (nested format)...")
            let accessibilityInfoFuture = commandExecutor.accessibility_info_(at_point: nil, nestedFormat: true)

            let infoObject: Any = try await BridgeFuture.value(accessibilityInfoFuture)
            logger.info().log("Accessibility info raw object received.")

            // The result is expected to be a JSON-serializable object (NSDictionary or NSArray).
            let jsonData = try JSONSerialization.data(withJSONObject: infoObject, options: [.prettyPrinted, .sortedKeys])
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print("\nAccessibility Information (JSON):\n")
                print(jsonString)
            } else {
                logger.error().log("Failed to convert accessibility info to JSON string.")
            }

            logger.info().log("Accessibility Info Fetcher finished successfully.")

        } catch {
            // Log detailed error information
            let nsError = error as NSError
            logger.error().log("Unhandled error in AccessibilityFetcher: \(error.localizedDescription)")
            logger.error().log("Error Domain: \(nsError.domain), Code: \(nsError.code), UserInfo: \(nsError.userInfo)")
            print("\nAn error occurred:")
            print("Message: \(error.localizedDescription)")
            print("Domain: \(nsError.domain), Code: \(nsError.code)")
            if !nsError.userInfo.isEmpty {
                print("UserInfo: \(nsError.userInfo)")
            }
        }
    }
}

func setupSignalHandlers(cancelRootTask: @escaping () -> Void, logger: FBControlCoreLogger) {
    let signalQueue = DispatchQueue(label: "signal-handler")
    for signalType in [SIGINT, SIGTERM] {
        signal(signalType, SIG_IGN)

        let source = DispatchSource.makeSignalSource(signal: signalType, queue: signalQueue)
        source.setEventHandler {
            logger.debug().log("Received signal \(signalType)")
            cancelRootTask()
        }
        source.resume()
    }
}

struct CLIError: LocalizedError {
    let errorDescription: String
}

let rootTask = Task { @MainActor in
    let userDefaults = UserDefaults.standard;
    let logger = FBIDBLogger(userDefaults: userDefaults);
    
    do {
        let isXcodeAvailable: NSString = try await BridgeFuture.value(FBXcodeDirectory.xcodeSelectDeveloperDirectory())
        if isXcodeAvailable.length == 0 {
            logger.error().log("Xcode is not available, idb will not be able to use Simulators")
            throw CLIError(errorDescription: "Xcode is not available, idb will not be able to use Simulators")
        }
    } catch {
        logger.error().log("Xcode is not available, idb will not be able to use Simulators: \(error.localizedDescription)")
        throw CLIError(errorDescription: "Xcode is not available, idb will not be able to use Simulators")
    }
    
    setupSignalHandlers(
        cancelRootTask: { rootTask.cancel() },
        logger: logger
    )
    
    do {
        try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
    } catch {
        logger.info().log("Essential private frameworks failed to loaded.")
        throw error
    }
    
    await AccessibilityFetcher.main(logger:logger)
}

try await rootTask.value
