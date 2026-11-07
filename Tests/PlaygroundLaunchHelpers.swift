import Foundation

private indirect enum PlaygroundScreenMarker: CustomStringConvertible {
    case identifier(String)
    case label(String)
    case all([PlaygroundScreenMarker])

    var description: String {
        switch self {
        case .identifier(let value):
            return "identifier '\(value)'"
        case .label(let value):
            return "label '\(value)'"
        case .all(let markers):
            return markers.map(\.description).joined(separator: ", ")
        }
    }

    func isPresent(in state: UIElement) -> Bool {
        switch self {
        case .identifier(let value):
            return UIStateParser.findElement(in: state, withIdentifier: value) != nil
        case .label(let value):
            return UIStateParser.findElementByLabel(in: state, label: value) != nil
        case .all(let markers):
            return markers.allSatisfy { $0.isPresent(in: state) }
        }
    }
}

extension TestHelpers {
    /// A fresh app keeps loading its accessibility runtime for a few seconds after the first
    /// read. On iOS 27.2 the tree still changes then (scroll bars fill in, the navigation bar
    /// moves in the child order) and the app handles touches late, which breaks feedback input
    /// such as a slider value. Settled means two reads, 500 ms apart, describe the same tree.
    static func waitForSettledAccessibility(simulatorUDID: String, description: String,
                                            timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: NSObject?
        var lastObserved = "No raw app state was read."
        repeat {
            do {
                let output = try await runAxeCommand("describe-ui", simulatorUDID: simulatorUDID).output
                lastObserved = output
                let json = output.firstIndex(where: { $0 == "[" || $0 == "{" }).map { output[$0...] } ?? ""
                // Parsed objects compare by content and child order; the raw text does not keep
                // a stable key order.
                let current = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSObject
                if let current, let previous, current.isEqual(previous) { return }
                previous = current
            } catch {
                previous = nil
                lastObserved = String(describing: error)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        throw TestError.unexpectedState("Timed out waiting for a settled accessibility tree on \(description).\n\(lastObserved)")
    }

    static func launchPlaygroundApp(to screen: String, simulatorUDID: String? = nil,
                                    settled: Bool = false) async throws {
        let udid = try simulatorUDID ?? requireSimulatorUDID()
        let marker = try playgroundScreenMarker(for: screen)
        var lastObservedState: UIElement?
        var lastLaunchError: Error?

        for attempt in 0..<2 {
            do {
                _ = try await CommandRunner.run(
                    "xcrun simctl launch --terminate-running-process \(udid) com.cameroncooke.AxePlayground --launch-arg \"screen=\(screen)\""
                )
            } catch {
                lastLaunchError = error
                if attempt == 0 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                throw error
            }

            if try await waitForPlaygroundScreen(
                marker,
                screen: screen,
                simulatorUDID: udid,
                timeout: 10
            ) != nil {
                if settled { try await waitForSettledAccessibility(simulatorUDID: udid, description: "screen \(screen)") }
                return
            } else if let state = try? await getUIState(simulatorUDID: udid) {
                lastObservedState = state
            }
        }

        let observed = lastObservedState.map {
            "type=\($0.type), label=\($0.label ?? "none"), identifier=\($0.identifier ?? "none")"
        } ?? "no accessibility hierarchy"
        let launchFailure = lastLaunchError.map { " Last launch error: \($0.localizedDescription)" } ?? ""
        throw TestError.unexpectedState(
            "Playground fixture '\(screen)' did not become ready with \(marker). Last observed root: \(observed).\(launchFailure)"
        )
    }

    private static func waitForPlaygroundScreen(
        _ marker: PlaygroundScreenMarker,
        screen: String,
        simulatorUDID: String,
        timeout: TimeInterval
    ) async throws -> UIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFocusRequest: Date?

        while Date() < deadline {
            if let state = try? await getUIState(simulatorUDID: simulatorUDID),
               marker.isPresent(in: state) {
                if screen != "text-input" {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    if let confirmedState = try? await getUIState(simulatorUDID: simulatorUDID),
                       marker.isPresent(in: confirmedState) {
                        return confirmedState
                    }
                } else {
                    // The screen shows its own indicator element while the field has focus.
                    // Accessibility does not fold that label into the screen container.
                    let focusIndicator = UIStateParser.findElement(
                        in: state,
                        withIdentifier: "text-input-screen"
                    ).flatMap {
                        UIStateParser.findElement(in: $0, withIdentifier: "typing-active-indicator")
                    }
                    if focusIndicator != nil {
                        return state
                    }

                    let shouldRequestFocus = lastFocusRequest.map {
                        Date().timeIntervalSince($0) >= 1
                    } ?? true
                    if shouldRequestFocus,
                       let textFieldFrame = UIStateParser.findElement(
                        in: state,
                        matching: { $0.type == "TextField" }
                       )?.frame {
                        lastFocusRequest = Date()
                        let centerX = textFieldFrame.x + (textFieldFrame.width / 2)
                        let centerY = textFieldFrame.y + (textFieldFrame.height / 2)
                        _ = try? await runAxeCommand(
                            "tap -x \(centerX) -y \(centerY)",
                            simulatorUDID: simulatorUDID
                        )
                    }
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        return nil
    }

    private static func playgroundScreenMarker(for screen: String) throws -> PlaygroundScreenMarker {
        switch screen {
        case "tap-test":
            return .all([
                .identifier("tap-test-screen"),
                .identifier("BackButton"),
            ])
        case "touch-control": return .identifier("touch-control-screen")
        case "swipe-test": return .identifier("swipe-test-screen")
        case "gesture-presets": return .identifier("gesture-presets-screen")
        case "landscape-coordinate-test": return .identifier("landscape-coordinate-screen")
        case "switch-test": return .identifier("switch-test-screen")
        case "tab-view-test": return .identifier("tab-view-test-screen")
        case "slider-value-test": return .identifier("slider-value-slider")
        case "searchable-test": return .identifier("searchable-test-query")
        case "toolbar-picker-test":
            return .all([
                .identifier("toolbar-picker-test-body"),
                .identifier("BackButton"),
                .label("All"),
                .label("Unread"),
                .label("Read"),
            ])
        case "alert-test": return .identifier("alert-test-show-alert")
        case "sheet-test": return .identifier("sheet-test-open-sheet")
        case "context-menu-test": return .identifier("context-menu-test-target")
        case "modal-navigation-test": return .identifier("modal-navigation-test-open")
        case "long-scroll-test": return .identifier("long-scroll-test-scroll-view")
        case "text-input": return .identifier("text-input-screen")
        case "key-press": return .identifier("key-press-screen")
        case "key-sequence": return .label("Key Sequence Detection")
        case "button-test": return .identifier("button-test-screen")
        case "batch-test": return .identifier("batch-test-screen")
        case "batch-login-flow": return .identifier("batch-login-screen")
        default:
            throw TestError.unexpectedState("Unknown playground fixture '\(screen)'")
        }
    }
}
