import SwiftUI

struct StatsView: View {
    enum Period: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case year = "Year"
    }

    @State private var period: Period = .week
    @State private var events: [PromptActionEvent] = []

    var body: some View {
        NavigationStack {
            List {
                pickerSection
                summarySection
                activitySection
            }
            .navigationTitle("Stats")
            .task {
                events = PromptStatusStore.load()
            }
        }
    }

    // MARK: - Sections

    private var pickerSection: some View {
        Section {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(.init())
    }

    private var summarySection: some View {
        Section {
            HStack(spacing: 0) {
                statCell(count: doneCount, label: "Done", color: .green)
                Divider()
                statCell(count: skippedCount, label: "Skipped", color: .secondary)
                Divider()
                statCell(count: doneCount + skippedCount, label: "Total", color: .accentColor)
            }
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        if filteredEvents.isEmpty {
            Section {
                Text("No activity this \(period.rawValue.lowercased()).")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Activity") {
                ForEach(filteredEvents) { event in
                    HStack(spacing: 12) {
                        Image(systemName: event.action == .done
                              ? "checkmark.circle.fill"
                              : "forward.circle.fill")
                            .foregroundStyle(event.action == .done ? .green : .secondary)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.promptText)
                                .lineLimit(2)
                            Text(event.occurredAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Helpers

    private var filteredEvents: [PromptActionEvent] {
        let cal = Calendar.current
        let now = Date()

        let component: Calendar.Component = {
            switch period {
            case .week:  return .weekOfYear
            case .month: return .month
            case .year:  return .year
            }
        }()

        guard let interval = cal.dateInterval(of: component, for: now) else {
            return events
        }

        return events.filter { interval.contains($0.occurredAt) }
    }

    private var doneCount: Int {
        filteredEvents.filter { $0.action == .done }.count
    }

    private var skippedCount: Int {
        filteredEvents.filter { $0.action == .skipped }.count
    }

    @ViewBuilder
    private func statCell(count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.system(.title, design: .rounded).bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

#Preview {
    StatsView()
}
