import SwiftUI

struct TabViewTestView: View {
    private enum PlaygroundTab: String, Hashable {
        case home = "Home"
        case settings = "Settings"
    }

    @State private var selectedTab: PlaygroundTab = .home

    var body: some View {
        VStack(spacing: 16) {
            Text("TabView Playground")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityIdentifier("tab-view-test-title")

            Text("Current Tab: \(selectedTab.rawValue)")
                .font(.headline)
                .accessibilityIdentifier("tab-view-current-tab")
                .accessibilityValue(selectedTab.rawValue)

            TabView(selection: $selectedTab) {
                VStack(spacing: 12) {
                    Text("Home panel active")
                        .font(.headline)
                        .accessibilityIdentifier("tab-view-home-panel")
                    Spacer()
                }
                .padding()
                .tag(PlaygroundTab.home)
                .tabItem {
                    Text("Home")
                }

                VStack(spacing: 12) {
                    Text("Settings panel active")
                        .font(.headline)
                        .accessibilityIdentifier("tab-view-settings-panel")
                    Spacer()
                }
                .padding()
                .tag(PlaygroundTab.settings)
                .tabItem {
                    Text("Settings")
                }
            }
        }
        .padding(.top)
        .navigationTitle("TabView Test")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("tab-view-test-screen")
    }
}

#Preview {
    NavigationStack {
        TabViewTestView()
    }
}
