//
//  ContentView.swift
//  AxePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var navigationManager = NavigationManager.shared
    @State private var navigationPath = NavigationPath()
    @State private var showSwipeTestModal = false
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            MainMenuView(showSwipeTestModal: $showSwipeTestModal)
                .navigationDestination(for: String.self) { screen in
                    destinationView(for: screen)
                }
        }
        .fullScreenCover(isPresented: $showSwipeTestModal) {
            SwipeTestView()
        }
        .onAppear {
            // Handle direct launch to specific screen
            if let directScreen = navigationManager.directLaunchScreen {
                if directScreen == "swipe-test" {
                    showSwipeTestModal = true
                } else {
                    navigationPath.append(directScreen)
                }
            }
        }
        .onChange(of: navigationManager.directLaunchScreen) { _, newValue in
            if let screen = newValue {
                if screen == "swipe-test" {
                    showSwipeTestModal = true
                } else {
                    navigationPath.append(screen)
                }
            }
        }
    }
    
    @ViewBuilder
    private func destinationView(for screen: String) -> some View {
        switch screen {
        // Touch & Gestures
        case "tap-test":
            TapTestView()
        case "touch-control":
            TouchControlView()
        case "gesture-presets":
            GesturePresetsView()
            
        // Input & Text
        case "text-input":
            TextInputView()
        case "key-press":
            KeyPressView()
        case "key-sequence":
            KeySequenceView()
            
        // Hardware
        case "button-test":
            ButtonTestView()
        case "batch-test":
            BatchTestView()
        case "batch-login-flow":
            BatchLoginFlowView()

        default:
            Text("Screen not found")
        }
    }
}

struct MainMenuView: View {
    @Binding var showSwipeTestModal: Bool
    
    private let menuSections: [(String, [(String, String, String)])] = [
        ("Touch & Gestures", [
            ("tap-test", "Tap Test", "Displays coordinates of CLI taps"),
            ("touch-control", "Touch Control", "Touch down/up events"),
            ("swipe-test", "Swipe Test", "Shows CLI swipe paths"),
            ("gesture-presets", "Gesture Presets", "Multi-touch gesture display")
        ]),
        ("Input & Text", [
            ("text-input", "Text Input", "Text typed by CLI commands"),
            ("key-press", "Key Press", "Detects CLI key events"),
            ("key-sequence", "Key Sequence", "Detects CLI key sequences")
        ]),
        ("Hardware", [
            ("button-test", "Button Test", "Hardware button press detection")
        ]),
        ("Batch", [
            ("batch-test", "Batch Test", "State changes + delayed element appearance"),
            ("batch-login-flow", "Batch Login Flow", "Multi-step login + loading + post-login action")
        ])
    ]
    
    var body: some View {
        List {            
            ForEach(menuSections, id: \.0) { section in
                Section(section.0) {
                    ForEach(section.1, id: \.0) { item in
                        if item.0 == "swipe-test" {
                            Button(action: {
                                showSwipeTestModal = true
                            }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.1)
                                        .font(.headline)
                                    Text(item.2)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .foregroundColor(.primary)
                            }
                        } else {
                            NavigationLink(value: item.0) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.1)
                                        .font(.headline)
                                    Text(item.2)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            

        }
        .navigationTitle("AXe Playground")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct BatchTestView: View {
    @State private var currentState = "Initial"
    @State private var showStateTarget = false
    @State private var showDelayedTarget = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Batch Playground")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityIdentifier("batch-test-title")

            Text("Current State: \(currentState)")
                .font(.headline)
                .accessibilityIdentifier("batch-current-state")
                .accessibilityValue(currentState)

            Button("Trigger State Change") {
                currentState = "State changed"
                showStateTarget = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("batch-state-change-trigger")

            if showStateTarget {
                Button("State Target") {
                    currentState = "State target tapped"
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("batch-state-target")
            }

            Button("Trigger Delayed Element") {
                currentState = "Waiting for delayed target"
                showDelayedTarget = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    showDelayedTarget = true
                    currentState = "Delayed target visible"
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("batch-delayed-trigger")

            if showDelayedTarget {
                Button("Delayed Target") {
                    currentState = "Delayed target tapped"
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("batch-delayed-target")
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Batch Test")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("batch-test-screen")
    }
}

struct BatchLoginFlowView: View {
    private enum Stage {
        case email
        case password
        case loading
        case dashboard
        case settings

        var title: String {
            switch self {
            case .email: return "Email"
            case .password: return "Password"
            case .loading: return "Loading"
            case .dashboard: return "Dashboard"
            case .settings: return "Settings"
            }
        }
    }

    @State private var stage: Stage = .email
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Fake Login Flow")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityIdentifier("batch-login-title")

            Text("Current Screen: \(stage.title)")
                .font(.headline)
                .accessibilityIdentifier("batch-login-current-screen")
                .accessibilityValue(stage.title)

            switch stage {
            case .email:
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .focused($focusedField, equals: .email)
                    .accessibilityIdentifier("batch-login-email-field")
                    .accessibilityValue(email.isEmpty ? "empty" : email)

                Button("Continue") {
                    stage = .password
                    focusedField = .password
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("batch-login-continue")

            case .password:
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .password)
                    .accessibilityIdentifier("batch-login-password-field")
                    .accessibilityValue(password.isEmpty ? "empty" : "entered")

                Button("Sign In") {
                    stage = .loading
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        stage = .dashboard
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("batch-login-sign-in")

            case .loading:
                ProgressView("Signing in…")
                    .accessibilityIdentifier("batch-login-loading-indicator")
                Text("Please wait")
                    .foregroundColor(.secondary)

            case .dashboard:
                Text("Welcome, \(email.isEmpty ? "User" : email)")
                    .accessibilityIdentifier("batch-login-welcome")
                Button("Open Settings") {
                    stage = .settings
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("batch-login-open-settings")

            case .settings:
                Text("Settings Opened")
                    .font(.headline)
                    .accessibilityIdentifier("batch-login-settings-opened")
                Button("Toggle Preference") {}
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("batch-login-toggle-preference")
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Batch Login")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("batch-login-screen")
        .onAppear {
            focusedField = .email
        }
    }
}

#Preview {
    ContentView()
}
