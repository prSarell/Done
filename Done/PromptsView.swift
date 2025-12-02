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
    case work = "Work"
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

// Single row for a prompt, with a unified Alert pill
private struct PromptRow: View {
    let item: PromptItem
    let alertLabel: String
    let onAlertTap: () -> Void

    var body: some View {
        HStack {
            Text(item.text)
                .lineLimit(2)
            Spacer()

            Button(action: onAlertTap) {
                Text(alertLabel)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .stroke(Color.accentColor, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

struct PromptsView: View {
    @State private var selectedCategory: PromptCategory = .daily

    // Separate lists per category
    @State private var dailyItems:        [PromptItem] = []
    @State private var weeklyItems:       [PromptItem] = []
    @State private var workItems:         [PromptItem] = []
    @State private var monthlyItems:      [PromptItem] = []
    @State private var yearlyItems:       [PromptItem] = []
    @State private var eventsItems:       [PromptItem] = []
    @State private var studyItems:        [PromptItem] = []
    @State private var mentalHealthItems: [PromptItem] = []

    // Draft input for the single-line add row
    @State private var draftText: String = ""

    // Rules (keyed by prompt text to match PromptRulesStore)
    @State private var rules: [String: PromptRule] = [:]

    // Unified alert editor state
    @State private var editingAlertPromptText: String?
    @State private var showingAlertSheet = false

    @State private var alertDayEnabled: Bool = false
    @State private var alertDateEnabled: Bool = false
    @State private var alertTimeEnabled: Bool = false

    @State private var alertWeekday: Int = 2   // 1 = Sunday … 7 = Saturday, default Monday
    @State private var alertDate: Date = Date()
    @State private var alertTime: Date = Date().addingTimeInterval(3600)

    // MARK: - Body split into small pieces

    var body: some View {
        NavigationStack {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 12) {
            tabsHeader
            promptsList
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
        .onChange(of: workItems)         { _, _ in saveToDisk() }
        .onChange(of: monthlyItems)      { _, _ in saveToDisk() }
        .onChange(of: yearlyItems)       { _, _ in saveToDisk() }
        .onChange(of: eventsItems)       { _, _ in saveToDisk() }
        .onChange(of: studyItems)        { _, _ in saveToDisk() }
        .onChange(of: mentalHealthItems) { _, _ in saveToDisk() }
        // Save rules when changed
        .onChange(of: rules) { _, _ in saveRules() }
        // Unified Alert editor sheet
        .sheet(isPresented: $showingAlertSheet) {
            alertEditorSheet()
        }
    }

    // MARK: - Header + List split out

    @ViewBuilder
    private var tabsHeader: some View {
        VStack(spacing: 8) {

            // Row 1: Daily · Weekly · Monthly · Yearly
            HStack(spacing: 8) {
                CategoryTabButton(
                    category: .daily,
                    isSelected: selectedCategory == .daily,
                    action: { selectedCategory = .daily }
                )
                CategoryTabButton(
                    category: .weekly,
                    isSelected: selectedCategory == .weekly,
                    action: { selectedCategory = .weekly }
                )
                CategoryTabButton(
                    category: .monthly,
                    isSelected: selectedCategory == .monthly,
                    action: { selectedCategory = .monthly }
                )
                CategoryTabButton(
                    category: .yearly,
                    isSelected: selectedCategory == .yearly,
                    action: { selectedCategory = .yearly }
                )
            }

            // Row 2: Events · Study · Health · Work
            HStack(spacing: 8) {
                CategoryTabButton(
                    category: .events,
                    isSelected: selectedCategory == .events,
                    action: { selectedCategory = .events }
                )
                CategoryTabButton(
                    category: .study,
                    isSelected: selectedCategory == .study,
                    action: { selectedCategory = .study }
                )
                CategoryTabButton(
                    category: .mentalHealth,
                    isSelected: selectedCategory == .mentalHealth,
                    action: { selectedCategory = .mentalHealth }
                )
                CategoryTabButton(
                    category: .work,
                    isSelected: selectedCategory == .work,
                    action: { selectedCategory = .work }
                )
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var promptsList: some View {
        List {
            addSection
            listSection(for: selectedCategory)
        }
        .listStyle(.insetGrouped)
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

    // Make the list section very simple for the compiler
    @ViewBuilder
    private func listSection(for category: PromptCategory) -> some View {
        switch category {
        case .daily:
            promptsListSection(title: "Daily List", items: dailyItems, category: .daily)
        case .weekly:
            promptsListSection(title: "Weekly List", items: weeklyItems, category: .weekly)
        case .work:
            promptsListSection(title: "Work List", items: workItems, category: .work)
        case .monthly:
            promptsListSection(title: "Monthly List", items: monthlyItems, category: .monthly)
        case .yearly:
            promptsListSection(title: "Yearly List", items: yearlyItems, category: .yearly)
        case .events:
            promptsListSection(title: "Events List", items: eventsItems, category: .events)
        case .study:
            promptsListSection(title: "Study List", items: studyItems, category: .study)
        case .mentalHealth:
            promptsListSection(title: "Health List", items: mentalHealthItems, category: .mentalHealth)
        }
    }

    @ViewBuilder
    private func promptsListSection(
        title: String,
        items: [PromptItem],
        category: PromptCategory
    ) -> some View {
        Section(title) {
            if items.isEmpty {
                Text("No items yet. Add one above.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.id) { item in
                    PromptRow(
                        item: item,
                        alertLabel: alertLabel(for: item),
                        onAlertTap: { startEditingAlert(for: item) }
                    )
                }
                .onDelete { indexSet in
                    deleteItems(at: indexSet, in: category)
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
        case .work:         workItems.append(newItem)
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

        case .work:
            let texts = indexSet.map { workItems[$0].text }
            workItems.remove(atOffsets: indexSet)
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

    // MARK: - Unified Alert helpers

    private func startEditingAlert(for item: PromptItem) {
        let key = item.text
        editingAlertPromptText = key

        let now = Date()
        let cal = Calendar.current
        let rule = rules[key]

        // Reset defaults
        alertDayEnabled = false
        alertDateEnabled = false
        alertTimeEnabled = false

        alertWeekday = cal.component(.weekday, from: now)
        alertDate = now
        alertTime = now.addingTimeInterval(3600)

        if let rule {
            // Day (weekday)
            if let wd = rule.weekday {
                alertDayEnabled = true
                alertWeekday = wd
            }

            // Date
            if let d = rule.date {
                alertDateEnabled = true
                alertDate = d
            }

            // Time
            if let h = rule.timeHour, let m = rule.timeMinute {
                if let composed = cal.date(
                    bySettingHour: h,
                    minute: m,
                    second: 0,
                    of: now
                ) {
                    alertTimeEnabled = true
                    alertTime = composed
                } else {
                    alertTimeEnabled = true
                }
            }
        }

        showingAlertSheet = true
    }

    private func alertLabel(for item: PromptItem) -> String {
        let key = item.text
        guard let rule = rules[key] else {
            return "Alert"
        }

        let hasDay = (rule.weekday != nil)
        let hasDate = (rule.date != nil)
        let hasTime = (rule.timeHour != nil && rule.timeMinute != nil)

        if !hasDay && !hasDate && !hasTime {
            return "Alert"
        }

        let cal = Calendar.current
        let dfDate = DateFormatter()
        dfDate.dateStyle = .medium
        dfDate.timeStyle = .none

        let dfTime = DateFormatter()
        dfTime.dateStyle = .none
        dfTime.timeStyle = .short

        // Prefer Date when both Date + Day are set
        if let date = rule.date {
            // Compose a date at the stored time if present, otherwise use date-only
            var dateToShow = date
            if hasTime,
               let h = rule.timeHour,
               let m = rule.timeMinute,
               let composed = cal.date(
                    bySettingHour: h,
                    minute: m,
                    second: 0,
                    of: date
               ) {
                dateToShow = composed
            }

            if hasTime {
                let dateStr = dfDate.string(from: dateToShow)
                let timeStr = dfTime.string(from: dateToShow)
                return "\(dateStr) \(timeStr)"
            } else {
                return dfDate.string(from: dateToShow)
            }
        }

        // No Date, but maybe Day / Time
        if let wd = rule.weekday {
            let dayName = weekdayName(for: wd)

            if hasTime {
                let now = Date()
                if let h = rule.timeHour,
                   let m = rule.timeMinute,
                   let t = cal.date(bySettingHour: h, minute: m, second: 0, of: now) {
                    let timeStr = dfTime.string(from: t)
                    return "\(dayName) \(timeStr)"
                } else {
                    return dayName
                }
            } else {
                return dayName
            }
        }

        // Time-only: treat as "every day at HH:mm"
        if hasTime,
           let h = rule.timeHour,
           let m = rule.timeMinute {
            let now = Date()
            if let t = cal.date(bySettingHour: h, minute: m, second: 0, of: now) {
                let timeStr = dfTime.string(from: t)
                return timeStr
            } else {
                return "Time set"
            }
        }

        return "Alert"
    }

    private func weekdayName(for weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols // Sun…Sat
        guard weekday >= 1, weekday <= symbols.count else { return "Day" }
        return symbols[weekday - 1]
    }

    @ViewBuilder
    private func alertEditorSheet() -> some View {
        NavigationStack {
            Form {
                Section("Day / Date / Time") {
                    Toggle("Day (weekday)", isOn: $alertDayEnabled)

                    if alertDayEnabled {
                        Picker("Weekday", selection: $alertWeekday) {
                            ForEach(1...7, id: \.self) { wd in
                                Text(weekdayName(for: wd)).tag(wd)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxHeight: 150)
                    }

                    Toggle("Date", isOn: $alertDateEnabled)

                    if alertDateEnabled {
                        DatePicker(
                            "Date",
                            selection: $alertDate,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxHeight: 180)
                    }

                    Toggle("Time", isOn: $alertTimeEnabled)

                    if alertTimeEnabled {
                        DatePicker(
                            "Time",
                            selection: $alertTime,
                            displayedComponents: [.hourAndMinute]
                        )
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxHeight: 180)
                    }
                }

                Section {
                    Text("You can turn on any combination of Day, Date, and Time.\n\nIf both Day and Date are on, the Date will effectively win for scheduling in this version.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingAlertSheet = false
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if let key = editingAlertPromptText, rules[key] != nil {
                        Button("Clear") {
                            if let key = editingAlertPromptText {
                                rules[key] = nil
                            }
                            showingAlertSheet = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAlertEdits()
                    }
                }
            }
        }
    }

    private func saveAlertEdits() {
        guard let key = editingAlertPromptText else {
            showingAlertSheet = false
            return
        }

        // If all toggles off, remove the rule entirely
        if !alertDayEnabled && !alertDateEnabled && !alertTimeEnabled {
            rules[key] = nil
            showingAlertSheet = false
            return
        }

        var rule = rules[key] ?? PromptRule()
        let cal = Calendar.current

        // Day
        if alertDayEnabled {
            rule.weekday = alertWeekday
        } else {
            rule.weekday = nil
        }

        // Date
        if alertDateEnabled {
            let comps = cal.dateComponents([.year, .month, .day], from: alertDate)
            rule.date = cal.date(from: comps)
        } else {
            rule.date = nil
        }

        // Time
        if alertTimeEnabled {
            let comps = cal.dateComponents([.hour, .minute], from: alertTime)
            rule.timeHour = comps.hour
            rule.timeMinute = comps.minute
        } else {
            rule.timeHour = nil
            rule.timeMinute = nil
        }

        // For this version we ignore more advanced monthly/yearly fields.
        rules[key] = rule
        showingAlertSheet = false
    }

    // MARK: - Persistence

    private struct PromptsState: Codable {
        var dailyItems:        [PromptItem]
        var weeklyItems:       [PromptItem]
        var workItems:         [PromptItem]
        var monthlyItems:      [PromptItem]
        var yearlyItems:       [PromptItem]
        var eventsItems:       [PromptItem]
        var studyItems:        [PromptItem]
        var mentalHealthItems: [PromptItem]

        // Default init for new sessions
        init(
            dailyItems:        [PromptItem] = [],
            weeklyItems:       [PromptItem] = [],
            workItems:         [PromptItem] = [],
            monthlyItems:      [PromptItem] = [],
            yearlyItems:       [PromptItem] = [],
            eventsItems:       [PromptItem] = [],
            studyItems:        [PromptItem] = [],
            mentalHealthItems: [PromptItem] = []
        ) {
            self.dailyItems        = dailyItems
            self.weeklyItems       = weeklyItems
            self.workItems         = workItems
            self.monthlyItems      = monthlyItems
            self.yearlyItems       = yearlyItems
            self.eventsItems       = eventsItems
            self.studyItems        = studyItems
            self.mentalHealthItems = mentalHealthItems
        }

        private enum CodingKeys: String, CodingKey {
            case dailyItems
            case weeklyItems
            case workItems
            case monthlyItems
            case yearlyItems
            case eventsItems
            case studyItems
            case mentalHealthItems
        }

        // Custom decoder that tolerates missing keys (old files)
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            func decodeItems(for key: CodingKeys) -> [PromptItem] {
                (try? container.decode([PromptItem].self, forKey: key)) ?? []
            }

            self.dailyItems        = decodeItems(for: .dailyItems)
            self.weeklyItems       = decodeItems(for: .weeklyItems)
            self.workItems         = decodeItems(for: .workItems)
            self.monthlyItems      = decodeItems(for: .monthlyItems)
            self.yearlyItems       = decodeItems(for: .yearlyItems)
            self.eventsItems       = decodeItems(for: .eventsItems)
            self.studyItems        = decodeItems(for: .studyItems)
            self.mentalHealthItems = decodeItems(for: .mentalHealthItems)
        }

        // Explicit encoder so Codable stays happy
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(dailyItems,        forKey: .dailyItems)
            try container.encode(weeklyItems,       forKey: .weeklyItems)
            try container.encode(workItems,         forKey: .workItems)
            try container.encode(monthlyItems,      forKey: .monthlyItems)
            try container.encode(yearlyItems,       forKey: .yearlyItems)
            try container.encode(eventsItems,       forKey: .eventsItems)
            try container.encode(studyItems,        forKey: .studyItems)
            try container.encode(mentalHealthItems, forKey: .mentalHealthItems)
        }
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

                #if DEBUG
                print("📂 PromptsView: Loading prompts from \(url.path)")
                #endif

                var loaded = PromptsState()

                do {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        #if DEBUG
                        print("📂 PromptsView: No prompts.json file yet, starting empty")
                        #endif
                        throw NSError(domain: "PromptsView", code: 1, userInfo: nil)
                    }

                    let data = try Data(contentsOf: url)
                    #if DEBUG
                    print("📂 PromptsView: Read \(data.count) bytes from prompts.json")
                    #endif

                    let dec = JSONDecoder()
                    dec.dateDecodingStrategy = .iso8601
                    loaded = try dec.decode(PromptsState.self, from: data)

                    #if DEBUG
                    print("📦 PromptsView: Decoded prompts: daily=\(loaded.dailyItems.count), weekly=\(loaded.weeklyItems.count), work=\(loaded.workItems.count)")
                    #endif
                } catch {
                    #if DEBUG
                    print("❌ PromptsView: Failed to load prompts.json:", error)
                    #endif
                }

                DispatchQueue.main.async {
                    self.dailyItems        = loaded.dailyItems
                    self.weeklyItems       = loaded.weeklyItems
                    self.workItems         = loaded.workItems
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
            workItems:         workItems,
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
        do {
            let data = try enc.encode(state)
            try data.write(to: url, options: .atomic)
            #if DEBUG
            print("💾 PromptsView: Saved prompts to \(url.lastPathComponent)")
            #endif
        } catch {
            #if DEBUG
            print("❌ PromptsView: Failed to save prompts.json:", error)
            #endif
        }
    }

    // MARK: - Helpers

    private var draftTextTrimmed: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var placeholderText: String {
        switch selectedCategory {
        case .daily:        return "e.g. Get Milk"
        case .weekly:       return "e.g. Weekly review"
        case .work:         return "e.g. Check-in with producer"
        case .monthly:      return "e.g. Dog worming tablets"
        case .yearly:       return "e.g. Mum's birthday"
        case .events:       return "e.g. Pia singing concert"
        case .study:        return "e.g. Read chapter 3"
        case .mentalHealth: return "e.g. 10-min walk / breathe"
        }
    }
}

#Preview {
    PromptsView()
}
