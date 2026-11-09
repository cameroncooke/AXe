import Foundation
import Testing

@Suite("Playground Duo Hinge and Window E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoHingeWindowTests {
    @Test("Use moved controls beside or above the real fold region", arguments: [0, 90, 180, 270])
    func hingeRearrangesControls(rotation: Int) async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: rotation) {
            let app = try CorePlaygroundSession()
            let device = try DuoPlaygroundSession()
            let beforeLaunch = try await device.catalogue()
            let pid = try await device.launch(screen: "hinge-layout")
            _ = try await app.waitFor("hinge document") { app.value("hinge-layout-status", in: $0) == "single" }
            _ = try await DuoPlaygroundLaunchTarget.prepareIfNeeded()
            let reader = try await PlaygroundDocumentReader<HingeDocument>(udid: TestHelpers.requireSimulatorUDID(), pid: pid, fileName: "hinge-layout.json")
            let flat = try await reader.waitFor("flat document and hinge update") { $0.mode == "single" && $0.hingeUpdates > 0 }
            let half = try await device.setPose(.tabletop, boot: beforeLaunch.bootIdentity)
            print("Hinge layout context: rotation=\(rotation), phase=before, boot=\(beforeLaunch.bootIdentity), activePanel=\(String(reflecting: beforeLaunch.activePanel))")
            print("Hinge layout context: rotation=\(rotation), phase=partial, boot=\(half.bootIdentity), activePanel=\(String(reflecting: half.activePanel))")
            let moved = try await reader.waitFor("real fold region rearranged the app") {
                $0.generation == flat.generation && $0.layoutRevision > flat.layoutRevision
                    && $0.hingeUpdates > flat.hingeUpdates && $0.mode.hasPrefix("split-")
                    && $0.divisions.contains(where: \.active) && $0.field != flat.field
            }
            let roots = try await app.state()
            let field = try app.element("hinge-layout-field", in: roots)
            let fieldFrame = try app.frame(of: field)
            try #require(abs(fieldFrame.x - moved.field.x) <= 2 && abs(fieldFrame.y - moved.field.y) <= 2,
                "Fresh accessibility coordinates do not match the moved app control.")
            let selected = screenArguments(half) + ["--expected-pid", String(pid)]
            try await app.run(["tap", "--id", "hinge-layout-button", "--tap-style", "physical"] + selected)
            _ = try await reader.waitFor("the moved button callback") { $0.marks == flat.marks + 1 }
            try await app.run(["tap", "--id", "hinge-layout-field", "--tap-style", "physical"] + selected)
            _ = try await reader.waitFor("moved field focused") { $0.focused }
            try await app.run(["type", "hinge note", "--focus-id", "hinge-layout-field"] + selected)
            _ = try await reader.waitFor("text in the moved field") { $0.text == "hinge note" && $0.textChanges > flat.textChanges }
            try await app.run(["tap", "--id", "hinge-layout-dismiss", "--tap-style", "physical"] + selected)
            let scrollState = try await app.state()
            let scroll = try app.frame(of: app.element("hinge-layout-document", in: scrollState))
            let start = app.point(in: scroll, x: 0.5, y: 0.8)
            let end = app.point(in: scroll, x: 0.5, y: 0.2)
            try await app.run(["swipe", "--start-x", String(start.x), "--start-y", String(start.y),
                "--end-x", String(end.x), "--end-y", String(end.y), "--duration", "0.5"])
            _ = try await reader.waitFor("document scrolled in the rearranged layout") { $0.scrollOffsetY > moved.scrollOffsetY + 10 }
            _ = try await device.setPose(.open, boot: beforeLaunch.bootIdentity)
            let reopened = try await reader.waitFor("flat layout restored without relaunch") {
                $0.mode == "single" && $0.layoutRevision > moved.layoutRevision && $0.generation == flat.generation
            }
            try #require(reopened.text == "hinge note" && reopened.marks == flat.marks + 1)
            print("Hinge rearrangement: rotation=\(rotation), mode=\(moved.mode), samePID=\(pid), oldField=\(flat.field), movedField=\(moved.field)")
        }
    }

    @Test("Numeric hinge targets reject an old screen after a switch and permit fresh input")
    func numericHingeAngles() async throws {
        try await verifyDuoDiscoveryReadInterval()
        let device = try DuoPlaygroundSession()
        let original = try await device.catalogue()
        _ = try await device.setPose(.open, boot: original.bootIdentity)
        let controls = try await PlaygroundControlsSession()
        let app = try CorePlaygroundSession()
        var previous = try await device.catalogue(boot: original.bootIdentity)
        var switches = 0
        // Repeat the prior measured sweep. Display switching remains an observed result.
        let targets = [1, 5, 10, 20, 45, 90, 105, 113, 114, 115, 120, 135, 112, 110, 90, 0, 115, 114]
        for (index, degrees) in targets.enumerated() {
            let before = try controls.documents.read()
            let output = try await app.run(["hinge", "set", String(degrees), "--expected-boot", original.bootIdentity, "--tolerance", "0.1",
                "--no-wait", "--verbose"])
            let receipt = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(output.utf8))
            try receipt.requireSuccess("observedMechanicalTarget")
            let samples = try #require(receipt.hinge?.receipt?.matchingSamples)
            try #require(samples.count == 2 && samples.allSatisfy { abs($0.mechanicalDegrees - Double(degrees)) <= 0.1 })
            let fresh = try await app.run(["hinge", "read", "--expected-boot", original.bootIdentity, "--verbose"])
            let measured = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(fresh.utf8))
            try measured.requireSuccess("observedHinge")
            let angle = try #require(measured.hinge?.readback?.sample.mechanicalDegrees)
            try #require(abs(angle - Double(degrees)) <= 0.1)
            var current = try await device.catalogue(boot: original.bootIdentity)
            var stable = false
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 100_000_000)
                let next = try await device.catalogue(boot: original.bootIdentity)
                if next.activePanel == current.activePanel { stable = true; current = next; break }
                current = next
            }
            try #require(stable, "The active screen did not settle after the hinge target.")
            if current.activePanel.identity != previous.activePanel.identity {
                switches += 1
                let refused = try await app.command(["tap", "--id", "feature.tap", "--tap-style", "physical",
                    "--expected-pid", String(controls.pid)] + screenArguments(previous), allowFailure: true)
                let line = try #require(refused.output.split(separator: "\n").first)
                let rejection = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(line.utf8))
                try #require(refused.exitCode != 0 && rejection.outcome == "failedBeforeInput"
                    && rejection.enqueuedEventCount == 0 && rejection.cleanup == "notNeeded" && rejection.quarantine == nil)
                try #require(try controls.documents.read().count("tap") == before.count("tap"))
            }
            let roots = try await app.state()
            _ = try app.frame(of: app.element("feature.tap", in: roots))
            _ = try await app.run(["tap", "--id", "feature.tap", "--tap-style", "physical",
                "--expected-pid", String(controls.pid)] + screenArguments(current))
            let after = try await controls.documents.waitFor("fresh tap at numeric hinge target") {
                $0.count("tap") == before.count("tap") + 1 && $0.activeWindowTouches == 0
            }
            try after.requireClear()
            try #require(after.generation == before.generation && after.pid == before.pid)
            try controls.preserveState("hinge-\(index)-\(degrees)")
            previous = current
        }
        try #require(switches > 0, "The sweep did not exercise a display switch.")
        print("Numeric hinge targets=\(targets.count), measured display switches=\(switches), same app PID=\(controls.pid)")
    }

    @Test("Find and use controls inside a real smaller window", arguments: [false, true])
    func insetWindow(inner: Bool) async throws {
        try await withDuoPlaygroundScreen(pose: inner ? .open : .closed, rotation: inner ? 90 : 0) {
            try await verifyInsetWindow()
        }
    }
}

@Suite("Playground Window E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundWindowTests {
    @Test("Use a real smaller window on ordinary iPhone")
    func insetWindow() async throws { try await verifyInsetWindow() }
}

private func verifyInsetWindow() async throws {
    let app = try CorePlaygroundSession()
    let device = try DuoPlaygroundSession()
    let pid = try await device.launch(screen: "inset-window")
    _ = try await app.waitFor("smaller-window page") { app.value("inset-window-open", in: $0) != nil || UIStateParser.findElement(in: $0, withIdentifier: "inset-window-open") != nil }
    _ = try await DuoPlaygroundLaunchTarget.prepareIfNeeded()
    try await app.run(["tap", "--id", "inset-window-open"])
    _ = try await app.waitFor("real inset window") { UIStateParser.findElement(in: $0, withIdentifier: "inset-window-button") != nil }
    let reader = try await PlaygroundDocumentReader<InsetDocument>(udid: TestHelpers.requireSimulatorUDID(), pid: pid, fileName: "inset-window.json")
    let before = try await reader.waitFor("nonzero window offset") {
        $0.window.x > 0 && $0.window.y > 0 && $0.window.width < $0.scene.width && $0.window.height < $0.scene.height
    }
    let fresh = try await app.state()
    let frame = try app.frame(of: app.element("inset-window-button", in: fresh))
    let point = app.point(in: frame, x: 0.5, y: 0.5)
    try await app.run(["tap", "-x", String(point.x), "-y", String(point.y)])
    _ = try await reader.waitFor("coordinate tap in smaller window") { $0.taps == before.taps + 1 }
    let agent = try AgentPlaygroundSession()
    let captured = try await agent.timedCapture(pid: pid)
    let reference = try captured.capture.target(id: "inset-window-button")
    try captured.requireUnexpired("before the smaller-window reference tap")
    let result = try await agent.tap(reference.ref, snapshot: captured.capture.snapshotID, pid: pid)
    let action = try #require(result.data.action)
    try #require(action.kind == "tap" && action.outcome == "enqueuedAndDrained"
        && action.enqueuedEventCount == 2 && action.cleanup != "uncertain" && !action.replayed)
    _ = try await reader.waitFor("one agent reference tap in the smaller window") { $0.taps == before.taps + 2 }
    try await app.run(["tap", "--id", "inset-window-field"])
    try await app.run(["type", "window note"])
    _ = try await reader.waitFor("typing in smaller window") { $0.text == "window note" && $0.textChanges > before.textChanges }
    try await app.run(["tap", "--id", "inset-window-close"])
    _ = try await app.waitFor("original window restored") { UIStateParser.findElement(in: $0, withIdentifier: "inset-window-open") != nil }
}

func screenArguments(_ catalogue: DuoCatalogue) -> [String] {
    // --verbose prints the full JSON receipt that refusal checks decode.
    ["--input-mode", "selected", "--screen-id", String(catalogue.activePanel.identity.displayID),
        "--screen-uuid", catalogue.activePanel.identity.uniqueID.uuidString, "--verbose"]
}

private struct HingeDocument: PlaygroundObservedDocument {
    let generation: UUID
    let processIdentifier: Int32
    var pid: Int32 { processIdentifier }
    let sequence: Int
    let layoutRevision: Int
    let mode: String
    let hingeUpdates: Int
    let divisions: [HingeDivision]
    let field: ObservedLayoutRect
    let marks: Int
    let text: String
    let textChanges: Int
    let focused: Bool
    let scrollOffsetY: Double
}

private struct HingeDivision: Decodable { let active: Bool }
private struct InsetDocument: PlaygroundObservedDocument {
    let generation: UUID
    let processIdentifier: Int32
    var pid: Int32 { processIdentifier }
    let window: ObservedLayoutRect
    let scene: ObservedLayoutRect
    let taps: Int
    let text: String
    let textChanges: Int
}

private struct ObservedLayoutRect: Decodable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private func verifyDuoDiscoveryReadInterval() async throws {
    let app = try CorePlaygroundSession()
    let started = ProcessInfo.processInfo.systemUptime
    let output = try await app.run(["displays", "--verbose"])
    let finished = ProcessInfo.processInfo.systemUptime
    let data = Data(output.utf8)
    let catalogue = try JSONDecoder().decode(DuoCatalogue.self, from: data)
    let metadata = try JSONDecoder().decode(DuoDiscoveryMetadata.self, from: data)
    try #require(metadata.readInterval.startedUptime >= started && metadata.readInterval.finishedUptime <= finished)
    try #require(metadata.readInterval.finishedUptime >= metadata.readInterval.startedUptime)
    try #require(metadata.sourceCommandType == "com.apple.coredevice.action.displayinfo" && metadata.sourceJSONVersion == 0
        && !metadata.sourceVersion.isEmpty && metadata.selectionBasis == "explicitActiveFlag")
    let udid = try TestHelpers.requireSimulatorUDID()
    try #require(catalogue.requestedSimulatorUDID == UUID(uuidString: udid))
    try #require(catalogue.panels.count == 2 && Set(catalogue.panels.map { $0.identity.displayID }) == Set([UInt32(1), UInt32(3)]))
    try #require(Set(catalogue.panels.map { $0.identity.uniqueID }).count == 2)
    try #require(catalogue.panels.filter { $0.active == true }.map(\.identity) == [catalogue.activePanel.identity])
    for panel in catalogue.panels {
        _ = try panel.rotationDegrees()
        try #require([panel.nativePixelWidth, panel.nativePixelHeight, panel.boundsWidth, panel.boundsHeight].allSatisfy { $0.isFinite && $0 > 0 })
        try #require(panel.pointScale > 0)
    }
}

private struct DuoDiscoveryMetadata: Decodable {
    let sourceCommandType: String
    let sourceJSONVersion: Int
    let sourceVersion: String
    let selectionBasis: String
    let readInterval: Interval
    struct Interval: Decodable { let startedUptime: Double; let finishedUptime: Double }
}
