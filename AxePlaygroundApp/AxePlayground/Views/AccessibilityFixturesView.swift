import Foundation
import SwiftUI

struct SliderValueTestView: View {
    @State private var sliderValue = 0.25
    @State private var state = "Initial"

    private var percentText: String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), sliderValue * 100.0)
    }

    private var exactValueText: String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), sliderValue)
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Slider Value State: \(state)")
                .accessibilityIdentifier("slider-value-state")
                .accessibilityValue(state)

            Button("Slider Value Button") {
                state = "Tapped"
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("slider-value-button")

            Text("Slider Position: \(sliderValue.formatted(.number.precision(.fractionLength(2))))")
                .accessibilityIdentifier("slider-position-value")
                .accessibilityValue(sliderValue.formatted(.number.precision(.fractionLength(2))))

            Text("Slider Percent State: \(percentText)")
                .accessibilityIdentifier("slider-percent-state")
                .accessibilityValue(percentText)

            Text("Slider Exact Value: \(exactValueText)")
                .accessibilityIdentifier("slider-exact-value-state")
                .accessibilityValue(exactValueText)

            Slider(value: $sliderValue, in: 0...1)
                .accessibilityIdentifier("slider-value-slider")
                .accessibilityLabel("Slider Value Slider")
        }
        .padding()
        .navigationTitle("Slider Value")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SearchableTestView: View {
    @State private var query = ""

    private var rows: [String] {
        let allRows = ["Alpha Row", "Beta Row"]
        guard !query.isEmpty else { return allRows }
        return allRows.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Text("Search Query: \(query.isEmpty ? "empty" : query)")
                .accessibilityIdentifier("searchable-test-query")
                .accessibilityValue(query.isEmpty ? "empty" : query)

            ForEach(rows, id: \.self) { row in
                Text(row)
                    .accessibilityIdentifier("searchable-test-\(row.replacingOccurrences(of: " ", with: "-").lowercased())")
            }
        }
        .navigationTitle("Searchable Test")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search Books"
        )
    }
}

struct ToolbarPickerTestView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case unread = "Unread"
        case read = "Read"

        var id: String { rawValue }
    }

    @State private var filter: Filter = .all

    var body: some View {
        List {
            Text("Toolbar Picker State: \(filter.rawValue)")
                .accessibilityIdentifier("toolbar-picker-test-state")
                .accessibilityValue(filter.rawValue)

            Text("Toolbar Picker Detail Body")
                .accessibilityIdentifier("toolbar-picker-test-body")
        }
        .navigationTitle("Toolbar Picker")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("toolbar-picker-test-filter")
            }
        }
    }
}
