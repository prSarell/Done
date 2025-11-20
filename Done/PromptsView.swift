import SwiftUI

// MARK: - Shared models

// Codable-friendly model
struct PromptItem: Identifiable, Hashable, Codable {
    var id: UUID
    var text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

enum PromptCategory: String, CaseIterable, Identifiable, Codable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case yearly = "Yearly"
    case events = "Events"
    case study = "Study"
    case mentalHealth = "Mental Health"

    var id: String { rawValue }
}

// MARK: - Small subviews

/// Small extracted view to keep the compiler happy
private struct CategoryTabButton: View {
    let category: PromptCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(category.rawValue)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 40)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor.opacity(0.18)
                                         : Color.secondary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.accentColor
                                           : Color.secondary.opacity(0.35),
                                lineWidth: 1)
                )
        }
    }
}

/// Single row for a prompt, with optional Alert pill(s)
private struct PromptRow: View {
    let item: PromptItem
    let category: PromptCategory

    let dailyLabel: String
    let weeklyLabel: String
    let monthlyLabel: String
    let yearlyLabel: String

    let onDailyTap: () -> Void
    let onWeeklyTap: () -> Void
    let onMonthlyTap: () -> Void
    let onYearlyTap: () -> Void

    var body: some View {
        HStack {
            Text(item.text)
                .lineLimit(2)
            Spacer()

            switch category {
            case .daily:
                Button(action: onDailyTap) {
                    Text(dailyLabel)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(Color.accentColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

            case .weekly:
                Button(action: onWeeklyTap) {
                    Text(weeklyLabel)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(Color.accentColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

            case .monthly:
                Button(action: onMonthlyTap) {
                    Text(monthlyLabel)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(Color.accentColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

            case .yearly:
                Button(action: onYearlyTap) {
                    Text(yearlyLabel)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(Color.accentColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Main view

struct PromptsView: View {
    @State private var selectedCategory: PromptCategory = .daily

    // Separate lists per category
    @State private var dailyItems:        [PromptItem] = []
    @State private var weeklyItems:       [PromptItem] = []
    @State private var monthlyItems:      [PromptItem] = []
    @State private var yearlyItems:       [PromptItem] = []
    @State private var eventsItems:       [PromptItem] = []
    @State private var studyItems:        [PromptItem] = []
    @State private var mentalHealthItems: [PromptItem] = []

    // Draft input for the single-line add row
    @State private var draftText: String = ""

    // Rules (keyed by prompt text to match PromptRulesStore)
    @State private var rules: [String: PromptRule] = [:]

    // DAILY alert editing
    @State private var editingDailyPromptText: String?
    @State private var showingDailySheet = false
    @State private var dailyTempTime: Date = Date()

    // WEEKLY alert editing
    @State private var editingWeeklyPromptText: String?
    @State private var showingWeeklySheet = false
    @State private var weeklyTempWeekday: Int = 2   // 1=Sun..7=Sat (Calendar), default Monday
    @State private var weeklyTempTime: Date = Date()

    // MONTHLY alert editing
    @State private var editingMonthlyPromptText: String?
    @State private var showingMonthlySheet = false
    @State private var monthlyTempDay: Int = 1
    @State private var monthlyIsLastDay: Bool = false

    // YEARLY alert editing
    @State private var editingYearlyPromptText: String?
    @State private var showingYearlySheet = false
    @State private var yearlyTempMonth: Int = 1
    @State private var yearlyTempDay: Int = 1

    // Grid layout for two visible rows (4 on first row, remaining wrap to second)
    private let tabColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // ---- Two-line tab grid ----
                let categories = PromptCategory.allCases
                LazyVGrid(columns: tabColumns, alignment: .center, spacing: 8) {
                    ForEach(categories, id: \.self) { cat in
                        CategoryTabButton(
                            category: cat,
                            isSelected: selectedCategory == cat,
                            action: { selectedCategory = cat }
                        )
                    }
                }
                .padding(.horizontal)

                List {
                    addSection
                    listSection
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Prompts")
            .toolbar { EditButton() }
            .task {
                await loadFromDisk()
                loadRules()
            }
            // Save prompts when any category changes
            .onChange(of: dailyItems)        { _, _ in saveToDisk() }
            .onChange(of: weeklyItems)       { _, _ in saveToDisk() }
            .onChange(of: monthlyItems)      { _, _ in saveToDisk() }
            .onChange(of: yearlyItems)       { _, _ in saveToDisk() }
            .onChange(of: eventsItems)       { _, _ in saveToDisk() }
            .onChange(of: studyItems)        { _, _ in saveToDisk() }
            .onChange(of: mentalHealthItems) { _, _ in saveToDisk() }
            // Save rules when changed
            .onChange(of: rules) { _, _ in saveRules() }
            // Sheets
            .sheet(isPresented: $showingDailySheet) {
                dailyAlertSheet()
            }
            .sheet(isPresented: $showingWeeklySheet) {
                weeklyAlertSheet()
            }
            .sheet(isPresented: $showingMonthlySheet) {
                monthlyAlertSheet()
            }
            .sheet(isPresented: $showingYearlySheet) {
                yearlyAlertSheet()
            }
        }
    }

    // MARK: - Sections

    private var addSection: some View {
        Section(header: Text("Add \(selectedCategory.rawValue) Item")) {
            HStack(spacing: 8) {
                TextField(placeholderText, text: $draftText)
                    .textInputAutocapitalization(.sentences)

                Button("Add") { addDraft() }
                    .disabled(addDisabled)
            }
        }
    }

    private var listSection: some View {
        Section("\(selectedCategory.rawValue) List") {
            let binding = itemsBinding(for: selectedCategory)
            let itemsToShow = binding.wrappedValue

            if itemsToShow.isEmpty {
                Text("No items yet. Add one above.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(itemsToShow) { item in
                    PromptRow(
                        item: item,
                        category: selectedCategory,
                        dailyLabel: dailyAlertLabel(for: item),
                        weeklyLabel: weeklyAlertLabel(for: item),
                        monthlyLabel: monthlyAlertLabel(for: item),
                        yearlyLabel: yearlyAlertLabel(for: item),
                        onDailyTap: { startEditingDaily(for: item) },
                        onWeeklyTap: { startEditingWeekly(for: item) },
                        onMonthlyTap: { startEditingMonthly(for: item) },
                        onYearlyTap: { startEditingYearly(for: item) }
                    )
                }
                .onDelete { indexSet in
                    deleteItems(at: indexSet, in: selectedCategory)
                }
            }
        }
    }

    // MARK: - Add / Delete

    private var addDisabled: Bool {
        draftTextTrimmed.isEmpty
    }

    private func addDraft() {
        guard !draftTextTrimmed.isEmpty else { return }
        let newItem = PromptItem(text: draftTextTrimmed)

        switch selectedCategory {
        case .daily:        dailyItems.append(newItem)
        case .weekly:       weeklyItems.append(newItem)
        case .monthly:      monthlyItems.append(newItem)
        case .yearly:       yearlyItems.append(newItem)
        case .events:       eventsItems.append(newItem)
        case .study:        studyItems.append(newItem)
        case .mentalHealth: mentalHealthItems.append(newItem)
        }

        draftText = ""
    }

    private func deleteItems(at indexSet: IndexSet, in category: PromptCategory) {
        func clearRules(for texts: [String]) {
            texts.forEach { rules[$0] = nil }
        }

        switch category {
        case .daily:
            let texts = indexSet.map { dailyItems[$0].text }
            dailyItems.remove(atOffsets: indexSet)
            clearRules(for: texts)
        case .weekly:
            let texts = indexSet.map { weeklyItems[$0].text }
            weeklyItems.remove(atOffsets: indexSet)
            clearRules(for: texts)
        case .monthly:
            let texts = indexSet.map { monthlyItems[$0].text }
            monthlyItems.remove(atOffsets: indexSet)
            clearRules(for: texts)
        case .yearly:
            let texts = indexSet.map { yearlyItems[$0].text }
            yearlyItems.remove(atOffsets: indexSet)
            clearRules(for: texts)
        case .events:
            let texts = indexSet.map { eventsItems[$0].text }
            eventsItems.remove(atOffsets: indexSet)
            clearRules(for: texts)
        case .study:
            let texts = indexSet.map { studyItems[$0].text }
            studyItems.remove(atOffsets: indexSet)
            clearRules(for: texts)
        case .mentalHealth:
            let texts = indexSet.map { mentalHealthItems[$0].text }
            mentalHealthItems.remove(atOffsets: indexSet)
            clearRules(for: texts)
        }
    }

    // MARK: - DAILY Alert helpers (time-only, 00:00 = non time-specific)

    private func dailyAlertLabel(for item: PromptItem) -> String {
        let key = item.text
        guard let rule = rules[key] else {
            return "Alert"
        }

        if let h = rule.timeHour, let m = rule.timeMinute {
            // A real time has been set
            var comps = DateComponents()
            comps.hour = h
            comps.minute = m
            let cal = Calendar.current
            let d = cal.date(from: comps) ?? Date()
            let df = DateFormatter()
            df.timeStyle = .short
            return df.string(from: d)
        } else {
            // Rule exists but we treat as "non time-specific"
            return "Any time"
        }
    }

    private func startEditingDaily(for item: PromptItem) {
        let key = item.text
        editingDailyPromptText = key

        let cal = Calendar.current
        let now = Date()

        if let rule = rules[key],
           let h = rule.timeHour,
           let m = rule.timeMinute,
           let d = cal.date(bySettingHour: h, minute: m, second: 0, of: now) {
            dailyTempTime = d
        } else {
            // Default to midnight when there is no time,
            // since 00:00 is our "non time-specific" sentinel.
            dailyTempTime = cal.date(bySettingHour: 0, minute: 0, second: 0, of: now) ?? now
        }

        showingDailySheet = true
    }

    @ViewBuilder
    private func dailyAlertSheet() -> some View {
        NavigationStack {
            Form {
                Section("Daily time") {
                    DatePicker("Time",
                               selection: $dailyTempTime,
                               displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)

                    Text("Tip: set the time to 00:00 if you want this prompt to be non time-specific.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Daily Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingDailySheet = false
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if let key = editingDailyPromptText, rules[key] != nil {
                        Button("Clear") {
                            if let key = editingDailyPromptText {
                                var rule = rules[key] ?? PromptRule()
                                rule.timeHour = nil
                                rule.timeMinute = nil
                                rules[key] = rule
                            }
                            showingDailySheet = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let key = editingDailyPromptText else {
                            showingDailySheet = false
                            return
                        }
                        let cal = Calendar.current
                        let comps = cal.dateComponents([.hour, .minute], from: dailyTempTime)
                        var rule = rules[key] ?? PromptRule()

                        // 00:00 is our "no specific time" sentinel
                        if let h = comps.hour, let m = comps.minute, (h != 0 || m != 0) {
                            rule.timeHour = h
                            rule.timeMinute = m
                        } else {
                            rule.timeHour = nil
                            rule.timeMinute = nil
                        }

                        rules[key] = rule
                        showingDailySheet = false
                    }
                }
            }
        }
    }

    // MARK: - WEEKLY Alert helpers

    private func weekdayName(for weekday: Int) -> String {
        // 1=Sunday ... 7=Saturday (Calendar style)
        let symbols = Calendar.current.weekdaySymbols
        guard weekday >= 1, weekday <= symbols.count else { return "Day" }
        return symbols[weekday - 1]
    }

    private func weeklyAlertLabel(for item: PromptItem) -> String {
        let key = item.text
        guard let rule = rules[key],
              let wd = rule.weekday else {
            return "Alert"
        }

        let name = weekdayName(for: wd)
        if let h = rule.timeHour, let m = rule.timeMinute {
            var comps = DateComponents()
            comps.hour = h
            comps.minute = m
            let cal = Calendar.current
            let d = cal.date(from: comps) ?? Date()
            let df = DateFormatter()
            df.timeStyle = .short
            let timeString = df.string(from: d)
            return "\(name) \(timeString)"
        } else {
            return name
        }
    }

    private func startEditingWeekly(for item: PromptItem) {
        let key = item.text
        editingWeeklyPromptText = key

        let cal = Calendar.current
        let now = Date()

        if let rule = rules[key] {
            weeklyTempWeekday = rule.weekday ?? cal.component(.weekday, from: now)

            if let h = rule.timeHour, let m = rule.timeMinute,
               let d = cal.date(bySettingHour: h, minute: m, second: 0, of: now) {
                weeklyTempTime = d
            } else {
                weeklyTempTime = now
            }
        } else {
            weeklyTempWeekday = cal.component(.weekday, from: now)
            weeklyTempTime = now
        }

        showingWeeklySheet = true
    }

    @ViewBuilder
    private func weeklyAlertSheet() -> some View {
        NavigationStack {
            Form {
                Section("Weekly schedule") {
                    Picker("Day of week", selection: $weeklyTempWeekday) {
                        ForEach(1...7, id: \.self) { wd in
                            Text(weekdayName(for: wd)).tag(wd)
                        }
                    }
                    .pickerStyle(.wheel)

                    DatePicker("Time",
                               selection: $weeklyTempTime,
                               displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                }
            }
            .navigationTitle("Weekly Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingWeeklySheet = false
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if let key = editingWeeklyPromptText, rules[key] != nil {
                        Button("Clear") {
                            if let key = editingWeeklyPromptText {
                                var rule = rules[key] ?? PromptRule()
                                rule.weekday = nil
                                rule.timeHour = nil
                                rule.timeMinute = nil
                                rules[key] = rule
                            }
                            showingWeeklySheet = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let key = editingWeeklyPromptText else {
                            showingWeeklySheet = false
                            return
                        }
                        let cal = Calendar.current
                        let comps = cal.dateComponents([.hour, .minute], from: weeklyTempTime)
                        var rule = rules[key] ?? PromptRule()
                        rule.weekday = weeklyTempWeekday
                        rule.timeHour = comps.hour
                        rule.timeMinute = comps.minute
                        rules[key] = rule
                        showingWeeklySheet = false
                    }
                }
            }
        }
    }

    // MARK: - YEARLY Alert helpers

    private func startEditingYearly(for item: PromptItem) {
        let key = item.text
        editingYearlyPromptText = key
        let rule = rules[key]

        if let rule, let m = rule.month, let d = rule.day {
            yearlyTempMonth = m
            yearlyTempDay   = d
        } else {
            // Default to today's date if no rule yet
            let now = Date()
            let cal = Calendar.current
            yearlyTempMonth = cal.component(.month, from: now)
            yearlyTempDay   = cal.component(.day, from: now)
        }
        clampYearlyDay()
        showingYearlySheet = true
    }

    private func yearlyAlertLabel(for item: PromptItem) -> String {
        let key = item.text
        guard let rule = rules[key],
              let m = rule.month,
              let d = rule.day else {
            return "Alert"
        }
        return "\(d) \(monthName(for: m))"
    }

    private func monthName(for month: Int) -> String {
        let symbols = Calendar.current.monthSymbols
        guard month >= 1, month <= symbols.count else { return "Month" }
        return symbols[month - 1]
    }

    private func daysIn(yearlyMonth: Int) -> Int {
        var comps = DateComponents()
        comps.year = 2024 // leap-year-safe baseline
        comps.month = yearlyMonth
        let cal = Calendar.current
        let date = cal.date(from: comps) ?? Date()
        return cal.range(of: .day, in: .month, for: date)?.count ?? 31
    }

    private func clampYearlyDay() {
        let maxDay = daysIn(yearlyMonth: yearlyTempMonth)
        if yearlyTempDay > maxDay { yearlyTempDay = maxDay }
        if yearlyTempDay < 1 { yearlyTempDay = 1 }
    }

    @ViewBuilder
    private func yearlyAlertSheet() -> some View {
        NavigationStack {
            Form {
                Section("Date (repeats every year)") {
                    Picker("Month", selection: $yearlyTempMonth) {
                        ForEach(1...12, id: \.self) { m in
                            Text(monthName(for: m)).tag(m)
                        }
                    }
                    .pickerStyle(.wheel)

                    Picker("Day", selection: $yearlyTempDay) {
                        ForEach(1...daysIn(yearlyMonth: yearlyTempMonth), id: \.self) { d in
                            Text("\(d)").tag(d)
                        }
                    }
                    .pickerStyle(.wheel)
                }
            }
            .navigationTitle("Yearly Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingYearlySheet = false
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if let key = editingYearlyPromptText, rules[key] != nil {
                        Button("Clear") {
                            if let key = editingYearlyPromptText {
                                var rule = rules[key] ?? PromptRule()
                                rule.month = nil
                                rule.day = nil
                                rules[key] = rule
                            }
                            showingYearlySheet = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let key = editingYearlyPromptText else {
                            showingYearlySheet = false
                            return
                        }
                        clampYearlyDay()
                        var rule = rules[key] ?? PromptRule()
                        rule.month = yearlyTempMonth
                        rule.day   = yearlyTempDay
                        rules[key] = rule
                        showingYearlySheet = false
                    }
                }
            }
        }
    }

    // MARK: - MONTHLY Alert helpers

    private func startEditingMonthly(for item: PromptItem) {
        let key = item.text
        editingMonthlyPromptText = key
        let rule = rules[key]

        if let rule {
            monthlyIsLastDay = rule.monthlyIsLastDay ?? false
            if let d = rule.monthlyDay {
                monthlyTempDay = d
            } else {
                let now = Date()
                let cal = Calendar.current
                monthlyTempDay = cal.component(.day, from: now)
            }
        } else {
            monthlyIsLastDay = false
            let now = Date()
            let cal = Calendar.current
            monthlyTempDay = cal.component(.day, from: now)
        }

        clampMonthlyDay()
        showingMonthlySheet = true
    }

    private func monthlyAlertLabel(for item: PromptItem) -> String {
        let key = item.text
        guard let rule = rules[key] else { return "Alert" }

        if rule.monthlyIsLastDay == true {
            return "Last day"
        } else if let d = rule.monthlyDay {
            return "Day \(d)"
        } else {
            return "Alert"
        }
    }

    private func clampMonthlyDay() {
        if monthlyTempDay < 1 { monthlyTempDay = 1 }
        if monthlyTempDay > 31 { monthlyTempDay = 31 }
    }

    @ViewBuilder
    private func monthlyAlertSheet() -> some View {
        NavigationStack {
            Form {
                Section("Monthly schedule") {
                    Toggle("Last day of month", isOn: $monthlyIsLastDay)

                    if !monthlyIsLastDay {
                        Picker("Day of month", selection: $monthlyTempDay) {
                            ForEach(1...31, id: \.self) { d in
                                Text("\(d)").tag(d)
                            }
                        }
                        .pickerStyle(.wheel)
                    } else {
                        Text("This prompt will repeat on the last day of every month.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Monthly Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingMonthlySheet = false
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if let key = editingMonthlyPromptText, rules[key] != nil {
                        Button("Clear") {
                            if let key = editingMonthlyPromptText {
                                var rule = rules[key] ?? PromptRule()
                                rule.monthlyDay = nil
                                rule.monthlyIsLastDay = nil
                                rules[key] = rule
                            }
                            showingMonthlySheet = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let key = editingMonthlyPromptText else {
                            showingMonthlySheet = false
                            return
                        }
                        clampMonthlyDay()
                        var rule = rules[key] ?? PromptRule()
                        if monthlyIsLastDay {
                            rule.monthlyIsLastDay = true
                            rule.monthlyDay = nil
                        } else {
                            rule.monthlyIsLastDay = false
                            rule.monthlyDay = monthlyTempDay
                        }
                        rules[key] = rule
                        showingMonthlySheet = false
                    }
                }
            }
        }
    }

    // MARK: - Persistence

    private struct PromptsState: Codable {
        var dailyItems:        [PromptItem] = []
        var weeklyItems:       [PromptItem] = []
        var monthlyItems:      [PromptItem] = []
        var yearlyItems:       [PromptItem] = []
        var eventsItems:       [PromptItem] = []
        var studyItems:        [PromptItem] = []
        var mentalHealthItems: [PromptItem] = []
    }

    private func loadRules() {
        rules = PromptRulesStore.load()
    }

    private func saveRules() {
        PromptRulesStore.save(rules)
    }

    private func loadFromDisk() async {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let url = docs.appendingPathComponent("prompts.json")
                var loaded = PromptsState()
                if let data = try? Data(contentsOf: url) {
                    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                    if let s = try? dec.decode(PromptsState.self, from: data) {
                        loaded = s
                    }
                }
                DispatchQueue.main.async {
                    self.dailyItems        = loaded.dailyItems
                    self.weeklyItems       = loaded.weeklyItems
                    self.monthlyItems      = loaded.monthlyItems
                    self.yearlyItems       = loaded.yearlyItems
                    self.eventsItems       = loaded.eventsItems
                    self.studyItems        = loaded.studyItems
                    self.mentalHealthItems = loaded.mentalHealthItems
                    cont.resume()
                }
            }
        }
    }

    private func saveToDisk() {
        let state = PromptsState(
            dailyItems:        dailyItems,
            weeklyItems:       weeklyItems,
            monthlyItems:      monthlyItems,
            yearlyItems:       yearlyItems,
            eventsItems:       eventsItems,
            studyItems:        studyItems,
            mentalHealthItems: mentalHealthItems
        )
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("prompts.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Helpers

    private func itemsBinding(for category: PromptCategory) -> Binding<[PromptItem]> {
        switch category {
        case .daily:        return $dailyItems
        case .weekly:       return $weeklyItems
        case .monthly:      return $monthlyItems
        case .yearly:       return $yearlyItems
        case .events:       return $eventsItems
        case .study:        return $studyItems
        case .mentalHealth: return $mentalHealthItems
        }
    }

    private var draftTextTrimmed: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var placeholderText: String {
        switch selectedCategory {
        case .daily:        return "e.g. Get Milk"
        case .weekly:       return "e.g. Team stand-up Monday 9am"
        case .monthly:      return "e.g. Dog worming tablets"
        case .yearly:       return "e.g. Mum's birthday"
        case .events:       return "e.g. School concert"
        case .study:        return "e.g. Read chapter 3"
        case .mentalHealth: return "e.g. 10-min walk / breathe"
        }
    }
}

#Preview {
    PromptsView()
}
