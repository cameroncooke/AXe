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
    static func launchPlaygroundApp(to screen: String, simulatorUDID: String? = nil) async throws {
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
                    let focusIndicator = UIStateParser.findElement(in: state) { element in
                        element.identifier == "text-input-screen" && element.label == "✏️ Typing active"
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
