import SwiftUI

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
    case mentalHealth = "Health"

    var id: String { rawValue }
}

// Small extracted view to keep the compiler happy
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

// Single row for a prompt, with optional Alert pill(s)
private struct PromptRow: View {
    let item: PromptItem
    let category: PromptCategory

    let yearlyLabel: String
    let monthlyLabel: String
    let eventLabel: String
    let studyLabel: String
    let mentalLabel: String

    let onYearlyTap: () -> Void
    let onMonthlyTap: () -> Void
    let onEventTap: () -> Void
    let onStudyTap: () -> Void
    let onMentalTap: () -> Void

    var body: some View {
        HStack {
            Text(item.text)
                .lineLimit(2)
            Spacer()

            switch category {
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

            case .events:
                Button(action: onEventTap) {
                    Text(eventLabel)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(Color.accentColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

            case .study:
                Button(action: onStudyTap) {
                    Text(studyLabel)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(Color.accentColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

            case .mentalHealth:
                Button(action: onMentalTap) {
                    Text(mentalLabel)
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

    // Yearly alert editing
    @State private var editingYearlyPromptText: String?
    @State private var showingYearlySheet = false
    @State private var yearlyTempMonth: Int = 1
    @State private var yearlyTempDay: Int = 1

    // Monthly alert editing
    @State private var editingMonthlyPromptText: String?
    @State private var showingMonthlySheet = false
    @State private var monthlyTempDay: Int = 1
    @State private var monthlyIsLastDay: Bool = false

    // Events (one-off) alert editing
    @State private var editingEventPromptText: String?
    @State private var showingEventSheet = false
    @State private var eventTempDate: Date = Date().addingTimeInterval(3600) // default = 1h from now

    // Study (one-off) alert editing
    @State private var editingStudyPromptText: String?
    @State private var showingStudySheet = false
    @State private var studyTempDate: Date = Date().addingTimeInterval(3600)

    // Mental Health (one-off) alert editing
    @State private var editingMentalPromptText: String?
    @State private var showingMentalSheet = false
    @State private var mentalTempDate: Date = Date().addingTimeInterval(3600)

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
            // Save prompts when any category changes (iOS 17-style onChange)
            .onChange(of: dailyItems)        { _, _ in saveToDisk() }
            .onChange(of: weeklyItems)       { _, _ in saveToDisk() }
            .onChange(of: monthlyItems)      { _, _ in saveToDisk() }
            .onChange(of: yearlyItems)       { _, _ in saveToDisk() }
            .onChange(of: eventsItems)       { _, _ in saveToDisk() }
            .onChange(of: studyItems)        { _, _ in saveToDisk() }
            .onChange(of: mentalHealthItems) { _, _ in saveToDisk() }
            // Save rules when changed
            .onChange(of: rules) { _, _ in saveRules() }
            // Yearly editor sheet
            .sheet(isPresented: $showingYearlySheet) {
                yearlyAlertSheet()
            }
            // Monthly editor sheet
            .sheet(isPresented: $showingMonthlySheet) {
                monthlyAlertSheet()
            }
            // Events editor sheet
            .sheet(isPresented: $showingEventSheet) {
                eventAlertSheet()
            }
            // Study editor sheet
            .sheet(isPresented: $showingStudySheet) {
                studyAlertSheet()
            }
            // Mental Health editor sheet
            .sheet(isPresented: $showingMentalSheet) {
                mentalAlertSheet()
            }
        }
    }

    // MARK: - Sections broken out

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
                        yearlyLabel: yearlyAlertLabel(for: item),
                        monthlyLabel: monthlyAlertLabel(for: item),
                        eventLabel: eventAlertLabel(for: item),
                        studyLabel: studyAlertLabel(for: item),
                        mentalLabel: mentalAlertLabel(for: item),
                        onYearlyTap: { startEditingYearly(for: item) },
                        onMonthlyTap: { startEditingMonthly(for: item) },
                        onEventTap: { startEditingEvent(for: item) },
                        onStudyTap: { startEditingStudy(for: item) },
                        onMentalTap: { startEditingMental(for: item) }
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
        switch category {
        case .daily:
            let texts = indexSet.map { dailyItems[$0].text }
            dailyItems.remove(atOffsets: indexSet)
            texts.forEach { rules[$0] = nil }
        case .weekly:
            let texts = indexSet.map { weeklyItems[$0].text }
            weeklyItems.remove(atOffsets: indexSet)
            texts.forEach { rules[$0] = nil }
        case .monthly:
            let texts = indexSet.map { monthlyItems[$0].text }
            monthlyItems.remove(atOffsets: indexSet)
            texts.forEach { rules[$0] = nil }
        case .yearly:
            let texts = indexSet.map { yearlyItems[$0].text }
            yearlyItems.remove(atOffsets: indexSet)
            texts.forEach { rules[$0] = nil }
        case .events:
            let texts = indexSet.map { eventsItems[$0].text }
            eventsItems.remove(atOffsets: indexSet)
            texts.forEach { rules[$0] = nil }
        case .study:
            let texts = indexSet.map { studyItems[$0].text }
            studyItems.remove(atOffsets: indexSet)
            texts.forEach { rules[$0] = nil }
        case .mentalHealth:
            let texts = indexSet.map { mentalHealthItems[$0].text }
            mentalHealthItems.remove(atOffsets: indexSet)
            texts.forEach { rules[$0] = nil }
        }
    }

    // MARK: - Yearly Alert helpers

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

    // MARK: - Monthly Alert helpers

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

    // MARK: - Events (one-off) Alert helpers

    private func startEditingEvent(for item: PromptItem) {
        let key = item.text
        editingEventPromptText = key
        let rule = rules[key]
        let cal = Calendar.current

        if let rule, let baseDate = rule.date {
            if let h = rule.timeHour, let m = rule.timeMinute,
               let combined = cal.date(bySettingHour: h, minute: m, second: 0, of: baseDate) {
                eventTempDate = combined
            } else {
                eventTempDate = baseDate
            }
        } else {
            eventTempDate = Date().addingTimeInterval(3600)
        }

        showingEventSheet = true
    }

    private func eventAlertLabel(for item: PromptItem) -> String {
        let key = item.text
        guard let rule = rules[key],
              let baseDate = rule.date else {
            return "Alert"
        }

        let cal = Calendar.current
        let dateToShow: Date
        if let h = rule.timeHour, let m = rule.timeMinute,
           let combined = cal.date(bySettingHour: h, minute: m, second: 0, of: baseDate) {
            dateToShow = combined
        } else {
            dateToShow = baseDate
        }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: dateToShow)
    }

    @ViewBuilder
    private func eventAlertSheet() -> some View {
        NavigationStack {
            Form {
                Section("Event date & time") {
                    DatePicker(
                        "Event time",
                        selection: $eventTempDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.wheel)
                }

                Section {
                    Text("This event will be treated as a one-off and can be auto-removed after the date has passed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Event Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingEventSheet = false
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if let key = editingEventPromptText, rules[key] != nil {
                        Button("Clear") {
                            if let key = editingEventPromptText {
                                var rule = rules[key] ?? PromptRule()
                                rule.date = nil
                                rule.timeHour = nil
                                rule.timeMinute = nil
                                rule.oneOff = nil
                                rules[key] = rule
                            }
                            showingEventSheet = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let key = editingEventPromptText else {
                            showingEventSheet = false
                            return
                        }

                        let cal = Calendar.current
                        let comps = cal.dateComponents(
                            [.year, .month, .day, .hour, .minute],
                            from: eventTempDate
                        )

                        var rule = rules[key] ?? PromptRule()
                        if let y = comps.year, let m = comps.month, let d = comps.day {
                            rule.date = cal.date(from: DateComponents(year: y, month: m, day: d))
                        }
                        rule.timeHour = comps.hour
                        rule.timeMinute = comps.minute
                        rule.oneOff = true

                        rules[key] = rule
                        showingEventSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Study (one-off) Alert helpers

    private func startEditingStudy(for item: PromptItem) {
        let key = item.text
        editingStudyPromptText = key
        let rule = rules[key]
        let cal = Calendar.current

        if let rule, let baseDate = rule.date {
            if let h = rule.timeHour, let m = rule.timeMinute,
               let combined = cal.date(bySettingHour: h, minute: m, second: 0, of: baseDate) {
                studyTempDate = combined
            } else {
                studyTempDate = baseDate
            }
        } else {
            studyTempDate = Date().addingTimeInterval(3600)
        }

        showingStudySheet = true
    }

    private func studyAlertLabel(for item: PromptItem) -> String {
        let key = item.text
        guard let rule = rules[key],
              let baseDate = rule.date else {
            return "Alert"
        }

        let cal = Calendar.current
        let dateToShow: Date
        if let h = rule.timeHour, let m = rule.timeMinute,
           let combined = cal.date(bySettingHour: h, minute: m, second: 0, of: baseDate) {
            dateToShow = combined
        } else {
            dateToShow = baseDate
        }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: dateToShow)
    }

    @ViewBuilder
    private func studyAlertSheet() -> some View {
        NavigationStack {
            Form {
                Section("Study reminder date & time") {
                    DatePicker(
                        "Study time",
                        selection: $studyTempDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.wheel)
                }

                Section {
                    Text("This study reminder will be treated as a one-off and can be auto-removed after the date has passed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Study Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingStudySheet = false
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if let key = editingStudyPromptText, rules[key] != nil {
                        Button("Clear") {
                            if let key = editingStudyPromptText {
                                var rule = rules[key] ?? PromptRule()
                                rule.date = nil
                                rule.timeHour = nil
                                rule.timeMinute = nil
                                rule.oneOff = nil
                                rules[key] = rule
                            }
                            showingStudySheet = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let key = editingStudyPromptText else {
                            showingStudySheet = false
                            return
                        }

                        let cal = Calendar.current
                        let comps = cal.dateComponents(
                            [.year, .month, .day, .hour, .minute],
                            from: studyTempDate
                        )

                        var rule = rules[key] ?? PromptRule()
                        if let y = comps.year, let m = comps.month, let d = comps.day {
                            rule.date = cal.date(from: DateComponents(year: y, month: m, day: d))
                        }
                        rule.timeHour = comps.hour
                        rule.timeMinute = comps.minute
                        rule.oneOff = true

                        rules[key] = rule
                        showingStudySheet = false
                    }
                }
            }
        }
    }

    // MARK: - Mental Health (one-off) Alert helpers

    private func startEditingMental(for item: PromptItem) {
        let key = item.text
        editingMentalPromptText = key
        let rule = rules[key]
        let cal = Calendar.current

        if let rule, let baseDate = rule.date {
            if let h = rule.timeHour, let m = rule.timeMinute,
               let combined = cal.date(bySettingHour: h, minute: m, second: 0, of: baseDate) {
                mentalTempDate = combined
            } else {
                mentalTempDate = baseDate
            }
        } else {
            mentalTempDate = Date().addingTimeInterval(3600)
        }

        showingMentalSheet = true
    }

    private func mentalAlertLabel(for item: PromptItem) -> String {
        let key = item.text
        guard let rule = rules[key],
              let baseDate = rule.date else {
            return "Alert"
        }

        let cal = Calendar.current
        let dateToShow: Date
        if let h = rule.timeHour, let m = rule.timeMinute,
           let combined = cal.date(bySettingHour: h, minute: m, second: 0, of: baseDate) {
            dateToShow = combined
        } else {
            dateToShow = baseDate
        }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: dateToShow)
    }

    @ViewBuilder
    private func mentalAlertSheet() -> some View {
        NavigationStack {
            Form {
                Section("Mental health reminder date & time") {
                    DatePicker(
                        "Reminder time",
                        selection: $mentalTempDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.wheel)
                }

                Section {
                    Text("This reminder will be treated as a one-off and can be auto-removed after the date has passed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Mental Health Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingMentalSheet = false
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if let key = editingMentalPromptText, rules[key] != nil {
                        Button("Clear") {
                            if let key = editingMentalPromptText {
                                var rule = rules[key] ?? PromptRule()
                                rule.date = nil
                                rule.timeHour = nil
                                rule.timeMinute = nil
                                rule.oneOff = nil
                                rules[key] = rule
                            }
                            showingMentalSheet = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let key = editingMentalPromptText else {
                            showingMentalSheet = false
                            return
                        }

                        let cal = Calendar.current
                        let comps = cal.dateComponents(
                            [.year, .month, .day, .hour, .minute],
                            from: mentalTempDate
                        )

                        var rule = rules[key] ?? PromptRule()
                        if let y = comps.year, let m = comps.month, let d = comps.day {
                            rule.date = cal.date(from: DateComponents(year: y, month: m, day: d))
                        }
                        rule.timeHour = comps.hour
                        rule.timeMinute = comps.minute
                        rule.oneOff = true

                        rules[key] = rule
                        showingMentalSheet = false
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
        case .events:       return "e.g. Pia singing concert"
        case .study:        return "e.g. Read chapter 3"
        case .mentalHealth: return "e.g. 10-min walk / breathe"
        }
    }
}

#Preview { PromptsView() }
