//
//  AxePlaygroundApp.swift
//  AxePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI
import UIKit

@main
struct AxePlaygroundApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Handle launch arguments for direct screen navigation
                    handleLaunchArguments()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Keep manual checks and idle input checks visible while the playground is active.
            UIApplication.shared.isIdleTimerDisabled = phase == .active
        }
    }
    
    private func handleLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        
        // Look for screen launch argument
        if let screenIndex = arguments.firstIndex(of: "--launch-arg"),
           screenIndex + 1 < arguments.count {
            let argument = arguments[screenIndex + 1]
            if argument.hasPrefix("screen=") {
                let screenName = String(argument.dropFirst(7)) // Remove "screen=" prefix
                NavigationManager.shared.navigateToScreen(screenName)
            }
        }
    }
}

/// Demo mode: the app as shown to visitors of a public AXe Mirror demo, who are strangers using
/// the simulator from their own phone. `axe remote mirror --demo` starts the app with `--launch-arg demo=1`.
/// Only screens that take touches and nothing else are offered then. A text field, a web page or
/// a system prompt each lead out of the app (a text field's menu offers Search Web and Share), so
/// every screen that has one is left out.
enum DemoMode {
    static let isOn = ProcessInfo.processInfo.arguments.contains("demo=1")

    static let screens: Set<String> = [
        "tap-test", "touch-monitor", "swipe-test", "gesture-presets", "drawing", "zoom", "switch-test", "tab-view-test",
    ]

    static func allows(_ screen: String) -> Bool { !isOn || screens.contains(screen) }
}

// Singleton to manage navigation state
class NavigationManager: ObservableObject {
    static let shared = NavigationManager()
    
    @Published var directLaunchScreen: String? = nil
    
    private init() {}
    
    func navigateToScreen(_ screenName: String) {
        guard DemoMode.allows(screenName) else { return }
        directLaunchScreen = screenName
    }
}
