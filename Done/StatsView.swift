import SwiftUI
import Charts
import UserNotifications

struct StatsView: View {
    enum Period: String, CaseIterable {
        case day   = "Day"
        case week  = "Week"
        case month = "Month"
        case year  = "Year"
    }

    @EnvironmentObject private var notesVM: TimerNotesViewModel
    @EnvironmentObject private var rewardsVM: RewardsViewModel
    @StateObject private var alertEditor = PromptAlertEditorModel()

    @State private var period: Period = .week
    @State private var events: [PromptActionEvent] = []
    @State private var focusExpanded = false
    @State private var timerFocusExpanded = false
    @State private var importantGeneral: [PromptItem] = []
    @State private var importantWork: [PromptItem] = []
    @State private var rules: [String: PromptRule] = [:]
    @State private var doneTodayPromptIDs: Set<UUID> = []
    @State private var skippedTodayPromptIDs: Set<UUID> = []

    @State private var rewardMessage: String? = nil
    @State private var rewardColor: Color = .blue

    var body: some View {
        ZStack {
            NavigationStack {
                List {
                    pickerSection
                    summarySection
                    chartSection
                    focusSection
                    timerSummarySection
                    timerChartSection
                    timerFocusSection
                    importantGeneralSection
                    importantWorkSection
                }
                .navigationTitle("Stats")
                .task {
                    events = PromptStatusStore.load()
                    loadImportantPrompts()
                    refreshDoneTodaySet()
                }
                .onAppear {
                    loadImportantPrompts()
                    refreshDoneTodaySet()
                }
                .onChange(of: period) { focusExpanded = false; timerFocusExpanded = false }
                .sheet(isPresented: $alertEditor.isPresented) {
                    PromptAlertEditorSheet(editor: alertEditor)
                }
            }

            if let message = rewardMessage {
                RewardOverlay(message: message, color: rewardColor) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        rewardMessage = nil
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: rewardMessage != nil)
    }

    private func triggerReward() {
        guard let msg = rewardsVM.triggerRandomReward() else { return }
        rewardColor = RewardOverlay.colors.randomElement() ?? .blue
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            rewardMessage = msg
        }
    }

    // MARK: - Prompt sections

    private var pickerSection: some View {
        Section {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
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

    private var chartSection: some View {
        Section {
            if filteredEvents.isEmpty {
                Text("No activity this \(period.rawValue.lowercased()).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                Chart(chartData) { point in
                    BarMark(
                        x: .value("Date", point.date, unit: xUnit),
                        y: .value("Count", point.count)
                    )
                    .foregroundStyle(by: .value("Action", point.actionLabel))
                    .cornerRadius(4)
                }
                .chartForegroundStyleScale([
                    "Done":    Color.green,
                    "Skipped": Color(.systemGray4)
                ])
                .chartLegend(position: .top, alignment: .trailing)
                .chartXAxis {
                    AxisMarks(values: .stride(by: xStride, count: xStrideCount)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: xFormat, centered: true)
                    }
                }
                .frame(height: 180)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var focusSection: some View {
        let top = topPrompts
        if !top.isEmpty {
            Section("Where your focus went") {
                ForEach(visibleFocusPrompts, id: \.text) { item in
                    HStack(spacing: 10) {
                        Text(item.text)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.green.opacity(0.2))
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.green)
                                        .frame(width: geo.size.width * CGFloat(item.count) / CGFloat(top[0].count))
                                }
                        }
                        .frame(width: 80, height: 6)

                        Text("\(item.count)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }

                if top.count > 5 {
                    Button {
                        withAnimation { focusExpanded.toggle() }
                    } label: {
                        Text(focusExpanded ? "Show less" : "Show all \(top.count)")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    // MARK: - Timer sections

    private var timerSummarySection: some View {
        Section("Timer") {
            if filteredNotes.isEmpty {
                Text("No timer sessions this \(period.rawValue.lowercased()).")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 0) {
                    statCellText("\(filteredNotes.count)", label: "Sessions", color: .accentColor)
                    Divider()
                    statCellText(formatDuration(totalSeconds), label: "Total", color: .accentColor)
                    Divider()
                    statCellText(formatDuration(averageSeconds), label: "Avg Session", color: .accentColor)
                }
            }
        }
    }

    @ViewBuilder
    private var timerChartSection: some View {
        if !filteredNotes.isEmpty {
            Section {
                Chart(timerChartData) { point in
                    BarMark(
                        x: .value("Date", point.date, unit: xUnit),
                        y: .value("Minutes", point.minutes)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: xStride, count: xStrideCount)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: xFormat, centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let mins = value.as(Double.self) {
                                Text(formatMinutes(mins))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 160)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Timer focus section

    @ViewBuilder
    private var timerFocusSection: some View {
        let all = topTimerFocus
        if !all.isEmpty {
            Section("Where your time went") {
                ForEach(visibleTimerFocus, id: \.text) { item in
                    HStack(spacing: 10) {
                        Text(item.text)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.2))
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor)
                                        .frame(width: geo.size.width * CGFloat(item.totalSeconds) / CGFloat(all[0].totalSeconds))
                                }
                        }
                        .frame(width: 80, height: 6)

                        Text(formatDuration(item.totalSeconds))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }

                if all.count > 5 {
                    Button {
                        withAnimation { timerFocusExpanded.toggle() }
                    } label: {
                        Text(timerFocusExpanded ? "Show less" : "Show all \(all.count)")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    // MARK: - Important prompt sections

    @ViewBuilder
    private var importantGeneralSection: some View {
        if !importantGeneral.isEmpty {
            Section("Important General") {
                ForEach(importantGeneral) { item in
                    importantPromptRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var importantWorkSection: some View {
        if !importantWork.isEmpty {
            Section("Important Work") {
                ForEach(importantWork) { item in
                    importantPromptRow(item)
                }
            }
        }
    }

    /// Same row + Alert/Done/Skip functionality as the Prompts screen, minus the
    /// Mark/Remove Important toggle — every prompt shown here is already important.
    @ViewBuilder
    private func importantPromptRow(_ item: PromptItem) -> some View {
        PromptRow(
            item: item,
            alertLabel: PromptAlertEditorModel.label(for: rules[item.id.uuidString]),
            isImportant: true,
            isDoneToday: doneTodayPromptIDs.contains(item.id),
            isSkippedToday: skippedTodayPromptIDs.contains(item.id),
            onAlertTap: {
                alertEditor.begin(rule: rules[item.id.uuidString]) { newRule in
                    persistRuleChange(for: item, newRule: newRule)
                }
            },
            onDone: { markImportantPrompt(item, action: .done) },
            onSkip: { markImportantPrompt(item, action: .skipped) }
        )
    }

    /// Marks an important prompt done/skipped directly from the Stats page, mirroring
    /// `PromptsView.markPrompt(_:action:)` since Stats only holds a read-only snapshot
    /// of the prompt lists rather than the live `@State` arrays PromptsView mutates.
    private func markImportantPrompt(_ item: PromptItem, action: PromptAction) {
        PromptStatusStore.append(
            PromptActionEvent(promptID: item.id, promptText: item.text, action: action)
        )
        events = PromptStatusStore.load()

        Task {
            let center = UNUserNotificationCenter.current()
            async let pendingAsync = center.pendingNotificationRequests()
            async let deliveredAsync = center.deliveredNotifications()
            let (pending, delivered) = await (pendingAsync, deliveredAsync)
            let toCancel = pending
                .filter { $0.identifier.contains(item.id.uuidString) }
                .map { $0.identifier }
            let toRemove = delivered
                .filter { $0.request.identifier.contains(item.id.uuidString) }
                .map { $0.request.identifier }
            if !toCancel.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: toCancel)
            }
            if !toRemove.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: toRemove)
            }
        }

        if action == .skipped {
            skippedTodayPromptIDs.insert(item.id)
        }

        guard action == .done else { return }

        doneTodayPromptIDs.insert(item.id)
        NotificationsManager.shared.scheduleMorningUpdateIfNeeded()
        triggerReward()   // everything in this list is important by definition

        // Greys the prompt out for the rest of the day; one-off prompts are purged
        // overnight by PromptsView.purgeCompletedOneOffPrompts, mirroring markPrompt(_:action:).
        guard let state = PromptsStore.loadSafe() else { return }

        RandomPromptScheduler.shared.refreshScheduleToday(
            allPrompts: state.allItems,
            workPromptIDs: Set(state.workLists.allItems.map(\.id)),
            forceRebuild: true
        )

        loadImportantPrompts()
    }

    /// Persists an alert-rule edit made from the Stats page's Alert sheet. Stats doesn't
    /// keep a live `@State` rules dict wired to autosave like PromptsView does, so this
    /// reads the freshest rules from disk, applies the change, and saves directly.
    private func persistRuleChange(for item: PromptItem, newRule: PromptRule?) {
        var latestRules = PromptRulesStore.load()
        latestRules[item.id.uuidString] = newRule
        PromptRulesStore.save(latestRules)
        loadImportantPrompts()
    }

    private static let promptListKeyPaths: [WritableKeyPath<PromptsState, [PromptList]>] = [
        \.dailyLists, \.weeklyLists, \.workLists, \.monthlyLists,
        \.yearlyLists, \.eventsLists, \.studyLists, \.mentalHealthLists
    ]

    private func refreshDoneTodaySet() {
        let events = PromptStatusStore.load()
        doneTodayPromptIDs = Set(
            events
                .filter { $0.action == .done && Calendar.current.isDateInToday($0.occurredAt) }
                .map { $0.promptID }
        )
        skippedTodayPromptIDs = Set(
            events
                .filter { $0.action == .skipped && Calendar.current.isDateInToday($0.occurredAt) }
                .map { $0.promptID }
        )
    }

    private func loadImportantPrompts() {
        guard let state = PromptsStore.loadSafe() else { return }
        let loadedRules = PromptRulesStore.loadMigratingIfNeeded(using: state.allItems)
        rules = loadedRules

        let nonWork = state.dailyLists.allItems + state.weeklyLists.allItems + state.monthlyLists.allItems
            + state.yearlyLists.allItems + state.eventsLists.allItems + state.studyLists.allItems
            + state.mentalHealthLists.allItems

        importantGeneral = nonWork
            .filter { loadedRules[$0.id.uuidString]?.isImportant == true }

        importantWork = state.workLists.allItems
            .filter { loadedRules[$0.id.uuidString]?.isImportant == true }
    }

    private var topTimerFocus: [(text: String, totalSeconds: Int)] {
        var totals: [String: Int] = [:]
        for note in filteredNotes where !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            totals[note.text, default: 0] += note.durationSeconds
        }
        return totals.sorted { $0.value > $1.value }.map { (text: $0.key, totalSeconds: $0.value) }
    }

    private var visibleTimerFocus: [(text: String, totalSeconds: Int)] {
        let all = topTimerFocus
        return timerFocusExpanded ? all : Array(all.prefix(5))
    }

    // MARK: - Timer helpers

    private struct TimerChartPoint: Identifiable {
        let id = UUID()
        let date: Date
        let minutes: Double
    }

    private var filteredNotes: [TimerNote] {
        let cal = Calendar.current
        let now = Date()
        let component: Calendar.Component = {
            switch period {
            case .day:   return .day
            case .week:  return .weekOfYear
            case .month: return .month
            case .year:  return .year
            }
        }()
        guard let interval = cal.dateInterval(of: component, for: now) else { return notesVM.notes }
        return notesVM.notes.filter { interval.contains($0.createdAt) }
    }

    private var totalSeconds: Int { filteredNotes.reduce(0) { $0 + $1.durationSeconds } }

    private var averageSeconds: Int {
        filteredNotes.isEmpty ? 0 : totalSeconds / filteredNotes.count
    }

    private var timerChartData: [TimerChartPoint] {
        let cal = Calendar.current
        let now = Date()

        let bucketStarts: [Date]
        switch period {
        case .day:
            guard let dayStart = cal.dateInterval(of: .day, for: now)?.start else { return [] }
            bucketStarts = (0..<24).compactMap { cal.date(byAdding: .hour, value: $0, to: dayStart) }
        case .week:
            guard let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
            bucketStarts = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        case .month:
            guard let monthStart = cal.dateInterval(of: .month, for: now)?.start,
                  let dayRange = cal.range(of: .day, in: .month, for: now) else { return [] }
            bucketStarts = (0..<dayRange.count).compactMap { cal.date(byAdding: .day, value: $0, to: monthStart) }
        case .year:
            guard let yearStart = cal.dateInterval(of: .year, for: now)?.start else { return [] }
            bucketStarts = (0..<12).compactMap { cal.date(byAdding: .month, value: $0, to: yearStart) }
        }

        return bucketStarts.compactMap { bucketStart -> TimerChartPoint? in
            guard let bucketInterval = cal.dateInterval(of: xUnit, for: bucketStart) else { return nil }
            let seconds = filteredNotes
                .filter { bucketInterval.contains($0.createdAt) }
                .reduce(0) { $0 + $1.durationSeconds }
            return TimerChartPoint(date: bucketStart, minutes: Double(seconds) / 60.0)
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "0m" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private func formatMinutes(_ minutes: Double) -> String {
        if minutes < 1 { return "0m" }
        let h = Int(minutes) / 60
        let m = Int(minutes) % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    // MARK: - Prompt chart helpers

    private struct ChartPoint: Identifiable {
        let id = UUID()
        let date: Date
        let count: Int
        let actionLabel: String
    }

    private var xUnit: Calendar.Component {
        switch period {
        case .day:          return .hour
        case .week, .month: return .day
        case .year:         return .month
        }
    }

    private var xStride: Calendar.Component {
        switch period {
        case .day:   return .hour
        case .week:  return .day
        case .month: return .day
        case .year:  return .month
        }
    }

    private var xStrideCount: Int {
        switch period {
        case .day:   return 6
        case .week:  return 1
        case .month: return 7
        case .year:  return 1
        }
    }

    private var xFormat: Date.FormatStyle {
        switch period {
        case .day:   return .dateTime.hour()
        case .week:  return .dateTime.weekday(.abbreviated)
        case .month: return .dateTime.day()
        case .year:  return .dateTime.month(.abbreviated)
        }
    }

    private var chartData: [ChartPoint] {
        let cal = Calendar.current
        let now = Date()

        let bucketStarts: [Date]
        switch period {
        case .day:
            guard let dayStart = cal.dateInterval(of: .day, for: now)?.start else { return [] }
            bucketStarts = (0..<24).compactMap { cal.date(byAdding: .hour, value: $0, to: dayStart) }
        case .week:
            guard let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
            bucketStarts = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        case .month:
            guard let monthStart = cal.dateInterval(of: .month, for: now)?.start,
                  let dayRange = cal.range(of: .day, in: .month, for: now) else { return [] }
            bucketStarts = (0..<dayRange.count).compactMap { cal.date(byAdding: .day, value: $0, to: monthStart) }
        case .year:
            guard let yearStart = cal.dateInterval(of: .year, for: now)?.start else { return [] }
            bucketStarts = (0..<12).compactMap { cal.date(byAdding: .month, value: $0, to: yearStart) }
        }

        return bucketStarts.flatMap { bucketStart -> [ChartPoint] in
            guard let bucketInterval = cal.dateInterval(of: xUnit, for: bucketStart) else { return [] }
            let bucketEvents = filteredEvents.filter { bucketInterval.contains($0.occurredAt) }
            return [
                ChartPoint(date: bucketStart, count: bucketEvents.filter { $0.action == .done }.count,    actionLabel: "Done"),
                ChartPoint(date: bucketStart, count: bucketEvents.filter { $0.action == .skipped }.count, actionLabel: "Skipped")
            ]
        }
    }

    // MARK: - Focus helpers

    private var topPrompts: [(text: String, count: Int)] {
        var counts: [String: Int] = [:]
        for event in filteredEvents where event.action == .done {
            counts[event.promptText, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { (text: $0.key, count: $0.value) }
    }

    private var visibleFocusPrompts: [(text: String, count: Int)] {
        let top = topPrompts
        return focusExpanded ? top : Array(top.prefix(5))
    }

    // MARK: - Filtered events + counts

    private var filteredEvents: [PromptActionEvent] {
        let cal = Calendar.current
        let now = Date()
        let component: Calendar.Component = {
            switch period {
            case .day:   return .day
            case .week:  return .weekOfYear
            case .month: return .month
            case .year:  return .year
            }
        }()
        guard let interval = cal.dateInterval(of: component, for: now) else { return events }
        return events.filter { interval.contains($0.occurredAt) }
    }

    private var doneCount:    Int { filteredEvents.filter { $0.action == .done }.count }
    private var skippedCount: Int { filteredEvents.filter { $0.action == .skipped }.count }

    // MARK: - Stat cells

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

    @ViewBuilder
    private func statCellText(_ value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title, design: .rounded).bold())
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
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
        .environmentObject(TimerNotesViewModel())
}
