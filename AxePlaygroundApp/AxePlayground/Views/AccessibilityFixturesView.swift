import Foundation
import SwiftUI
import UIKit

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

struct AlertTestView: View {
    @State private var state = "Initial"
    @State private var isShowingAlert = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Alert State: \(state)")
                .accessibilityIdentifier("alert-test-state")
                .accessibilityValue(state)

            Button("Show Alert") {
                isShowingAlert = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("alert-test-show-alert")
        }
        .padding()
        .navigationTitle("Alert Test")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete Draft?", isPresented: $isShowingAlert) {
            Button("Cancel", role: .cancel) {
                state = "Cancelled"
            }
            Button("Delete", role: .destructive) {
                state = "Deleted"
            }
        } message: {
            Text("This alert is used for deterministic automation coverage.")
        }
    }
}

struct SheetTestView: View {
    @State private var state = "Initial"
    @State private var isShowingSheet = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Sheet State: \(state)")
                .accessibilityIdentifier("sheet-test-state")
                .accessibilityValue(state)

            Button("Open Sheet") {
                isShowingSheet = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("sheet-test-open-sheet")
        }
        .padding()
        .navigationTitle("Sheet Test")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingSheet) {
            NavigationStack {
                VStack(spacing: 24) {
                    Text("Sheet Fixture")
                        .font(.title2)
                        .fontWeight(.bold)

                    Button("Run Sheet Action") {
                        state = "Sheet action tapped"
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sheet-test-action")

                    Button("Close Sheet") {
                        isShowingSheet = false
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("sheet-test-close")
                }
                .padding()
                .navigationTitle("Sheet Fixture")
                .navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("sheet-test-sheet")
            }
            .presentationDetents([.medium])
        }
    }
}

struct ContextMenuTestView: View {
    @State private var state = "Initial"

    var body: some View {
        VStack(spacing: 24) {
            Text("Context Menu State: \(state)")
                .accessibilityIdentifier("context-menu-test-state")
                .accessibilityValue(state)

            Button("Long Press Target") {
                state = "Tapped"
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            .buttonStyle(.plain)
            .accessibilityIdentifier("context-menu-test-target")
            .contextMenu {
                Button("Favorite") {
                    state = "Favorited"
                }
                Button("Archive") {
                    state = "Archived"
                }
            }
        }
        .padding()
        .navigationTitle("Context Menu")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ModalNavigationTestView: View {
    @State private var state = "Initial"
    @State private var isShowingModal = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Modal Navigation State: \(state)")
                .accessibilityIdentifier("modal-navigation-test-state")
                .accessibilityValue(state)

            Button("Open Modal Flow") {
                isShowingModal = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("modal-navigation-test-open")
        }
        .padding()
        .navigationTitle("Modal Navigation")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingModal) {
            NavigationStack {
                List {
                    NavigationLink("Open Detail") {
                        VStack(spacing: 24) {
                            Text("Modal Detail")
                                .font(.title2)
                                .accessibilityIdentifier("modal-navigation-test-detail")

                            Button("Mark Complete") {
                                state = "Completed"
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("modal-navigation-test-complete")
                        }
                        .padding()
                        .navigationTitle("Modal Detail")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    .accessibilityIdentifier("modal-navigation-test-detail-link")
                }
                .navigationTitle("Modal Flow")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            isShowingModal = false
                        }
                        .accessibilityIdentifier("modal-navigation-test-done")
                    }
                }
                .accessibilityIdentifier("modal-navigation-test-modal")
            }
        }
    }
}

struct LongScrollTestView: View {
    private let rows = Array(1...80)
    @State private var selectedRow = "None"

    var body: some View {
        VStack(spacing: 0) {
            Text("Long Scroll Selected: \(selectedRow)")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("long-scroll-test-state")
                .accessibilityValue(selectedRow)

            LongScrollTableView(rows: rows, selectedRow: $selectedRow)
        }
        .navigationTitle("Long Scroll")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LongScrollTableView: UIViewRepresentable {
    let rows: [Int]
    @Binding var selectedRow: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedRow: $selectedRow)
    }

    func makeUIView(context: Context) -> UITableView {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.rowHeight = 64
        tableView.accessibilityIdentifier = "long-scroll-test-scroll-view"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Coordinator.cellReuseIdentifier)
        return tableView
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.rows = rows
        context.coordinator.selectedRow = $selectedRow
        tableView.reloadData()
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        static let cellReuseIdentifier = "LongScrollRowCell"

        var rows: [Int] = []
        var selectedRow: Binding<String>

        init(selectedRow: Binding<String>) {
            self.selectedRow = selectedRow
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            rows.count + 2
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellReuseIdentifier, for: indexPath)
            let title = title(for: indexPath.row)
            cell.textLabel?.text = title
            cell.accessibilityLabel = title
            cell.accessibilityIdentifier = identifier(for: indexPath.row)
            cell.accessibilityTraits.insert(.button)
            return cell
        }

        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            guard let row = rowNumber(for: indexPath.row) else { return }
            selectedRow.wrappedValue = "Row \(row)"
        }

        private func title(for index: Int) -> String {
            if index == 0 { return "Long Scroll Start" }
            if index == rows.count + 1 { return "Long Scroll End" }
            return "Long Scroll Row \(rows[index - 1])"
        }

        private func identifier(for index: Int) -> String {
            if index == 0 { return "long-scroll-test-start" }
            if index == rows.count + 1 { return "long-scroll-test-end" }
            return "long-scroll-test-row-\(rows[index - 1])"
        }

        private func rowNumber(for index: Int) -> Int? {
            guard index > 0, index <= rows.count else { return nil }
            return rows[index - 1]
        }
    }
}
