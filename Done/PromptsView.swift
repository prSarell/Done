// Path: Done/PromptsView.swift

import SwiftUI
import UserNotifications

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
struct PromptRow: View {
    let item: PromptItem
    let alertLabel: String
    let isImportant: Bool
    let isDoneToday: Bool
    let onAlertTap: () -> Void
    let onDone: () -> Void
    let onSkip: () -> Void
    // nil hides the Mark/Remove Important context menu entry — used on the Stats page,
    // where every row shown is already important by definition.
    var onToggleImportant: (() -> Void)? = nil

    var body: some View {
        HStack {
            if isImportant {
                Image(systemName: "star.fill")
                    .foregroundStyle(isDoneToday ? Color.secondary : Color.yellow)
                    .font(.caption)
            }
            Text(item.text)
                .lineLimit(2)
                .strikethrough(isDoneToday)
                .foregroundStyle(isDoneToday ? .secondary : .primary)
            Spacer()

            Button(action: onAlertTap) {
                Text(alertLabel)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .stroke(isDoneToday ? Color.secondary : Color.accentColor, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .opacity(isDoneToday ? 0.5 : 1)
        .contextMenu {
            Button { onDone() } label: {
                Label("Mark Done", systemImage: "checkmark.circle.fill")
            }
            Button { onSkip() } label: {
                Label("Skip", systemImage: "forward.circle.fill")
            }
            if let onToggleImportant {
                Button { onToggleImportant() } label: {
                    Label(
                        isImportant ? "Remove Important" : "Mark Important",
                        systemImage: isImportant ? "star.slash" : "star"
                    )
                }
            }
        }
    }
}

// Small inline "add item" row, one per sub-list section.
private struct AddItemRow: View {
    let placeholder: String
    let onAdd: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.sentences)
                .focused($focused)
                .onSubmit { submit() }

            Button("Add") { submit() }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        text = ""
        focused = false
    }
}

struct PromptsView: View {
    @EnvironmentObject private var rewardsVM: RewardsViewModel

    @State private var selectedCategory: PromptCategory = .daily

    // Separate lists (each holding one or more named sub-lists) per category
    @State private var dailyLists:        [PromptList] = [PromptList()]
    @State private var weeklyLists:       [PromptList] = [PromptList()]
    @State private var workLists:         [PromptList] = [PromptList()]
    @State private var monthlyLists:      [PromptList] = [PromptList()]
    @State private var yearlyLists:       [PromptList] = [PromptList()]
    @State private var eventsLists:       [PromptList] = [PromptList()]
    @State private var studyLists:        [PromptList] = [PromptList()]
    @State private var mentalHealthLists: [PromptList] = [PromptList()]

    // Rules (keyed by prompt item id, as a UUID string)
    @State private var rules: [String: PromptRule] = [:]

    // Unified alert editor (shared with StatsView)
    @StateObject private var alertEditor = PromptAlertEditorModel()

    // Prompt IDs marked done today — greyed out until the day rolls over
    @State private var doneTodayPromptIDs: Set<UUID> = []

    // Reward overlay shown when an important prompt is marked done
    @State private var rewardMessage: String? = nil
    @State private var rewardColor: Color = .blue

    // Sub-list rename / delete state
    @State private var renamingListID: UUID?
    @State private var renameText: String = ""
    @State private var showingRenameAlert = false
    @State private var listPendingDeletion: (category: PromptCategory, listID: UUID)?
    @State private var showingDeleteListConfirm = false

    // MARK: - Safety gates / debouncers

    /// Prevents "load → assign arrays → onChange → save empty" wipes.
    @State private var hasFinishedInitialLoad: Bool = false

    /// Debounce schedule rebuilds so we don’t spam notifications while typing/editing.
    @State private var scheduleTask: Task<Void, Never>?

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Derived collections / helpers

    private var allPromptItems: [PromptItem] {
        dailyLists.allItems
        + weeklyLists.allItems
        + workLists.allItems
        + monthlyLists.allItems
        + yearlyLists.allItems
        + eventsLists.allItems
        + studyLists.allItems
        + mentalHealthLists.allItems
    }

    /// Binding into the `[PromptList]` array backing a given category, so category
    /// dispatch lives in exactly one place instead of being repeated per-action.
    private func listsBinding(for category: PromptCategory) -> Binding<[PromptList]> {
        switch category {
        case .daily:        return $dailyLists
        case .weekly:       return $weeklyLists
        case .work:         return $workLists
        case .monthly:      return $monthlyLists
        case .yearly:       return $yearlyLists
        case .events:       return $eventsLists
        case .study:        return $studyLists
        case .mentalHealth: return $mentalHealthLists
        }
    }

    private var allCategoryBindings: [Binding<[PromptList]>] {
        PromptCategory.allCases.map { listsBinding(for: $0) }
    }

    private func scheduleRandomPromptsDebounced(forceRebuild: Bool) {
        scheduleTask?.cancel()
        scheduleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            if Task.isCancelled { return }
            RandomPromptScheduler.shared.refreshScheduleToday(
                allPrompts: allPromptItems,
                workPromptIDs: Set(workLists.allItems.map(\.id)),
                forceRebuild: forceRebuild
            )
        }
    }

    // MARK: - Body split into small pieces

    var body: some View {
        ZStack {
            NavigationStack {
                content
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

    @ViewBuilder
    private var content: some View {
        contentCore
            // Rename a sub-list
            .alert("Rename List", isPresented: $showingRenameAlert) {
                TextField("List name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingListID = nil }
                Button("Save") { commitRename() }
            }
            // Delete a sub-list
            .confirmationDialog(
                "Delete this list and all its items?",
                isPresented: $showingDeleteListConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete List", role: .destructive) { commitDeleteList() }
                Button("Cancel", role: .cancel) { listPendingDeletion = nil }
            }
    }

    @ViewBuilder
    private var contentCore: some View {
        VStack(spacing: 12) {
            tabsHeader
            promptsList
        }
        .navigationTitle("Prompts")
        .task {
            // Important: gate all onChange saves until load + rules load completed
            hasFinishedInitialLoad = false

            let (loadedState, loadedRules) = await PromptsStore.loadSafeWithRulesAsync()
            if let loadedState {
                dailyLists        = loadedState.dailyLists
                weeklyLists       = loadedState.weeklyLists
                workLists         = loadedState.workLists
                monthlyLists      = loadedState.monthlyLists
                yearlyLists       = loadedState.yearlyLists
                eventsLists       = loadedState.eventsLists
                studyLists        = loadedState.studyLists
                mentalHealthLists = loadedState.mentalHealthLists
            }
            // else: decode failed — keep current in-memory state rather than clobber it
            rules = loadedRules
            repairCorruptedRules()

            hasFinishedInitialLoad = true

            purgeCompletedOneOffPrompts()
            refreshDoneTodaySet()

            // Plan once based on loaded data (NOT repeatedly during load)
            RandomPromptScheduler.shared.refreshScheduleToday(
                allPrompts: allPromptItems,
                workPromptIDs: Set(workLists.allItems.map(\.id)),
                forceRebuild: true
            )
        }
        // Save prompts when any category changes
        .onChange(of: dailyLists)        { _, _ in onPromptsMutated() }
        .onChange(of: weeklyLists)       { _, _ in onPromptsMutated() }
        .onChange(of: workLists)         { _, _ in onPromptsMutated() }
        .onChange(of: monthlyLists)      { _, _ in onPromptsMutated() }
        .onChange(of: yearlyLists)       { _, _ in onPromptsMutated() }
        .onChange(of: eventsLists)       { _, _ in onPromptsMutated() }
        .onChange(of: studyLists)        { _, _ in onPromptsMutated() }
        .onChange(of: mentalHealthLists) { _, _ in onPromptsMutated() }

        // Save rules when changed
        .onChange(of: rules) { _, _ in
            guard hasFinishedInitialLoad else { return }
            saveRules()
            scheduleRandomPromptsDebounced(forceRebuild: true)
        }

        // Purge completed one-offs when app returns to foreground
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, hasFinishedInitialLoad else { return }
            purgeCompletedOneOffPrompts()
            refreshDoneTodaySet()
        }

        // Unified Alert editor sheet
        .sheet(isPresented: $alertEditor.isPresented) {
            PromptAlertEditorSheet(editor: alertEditor)
        }
    }

    private func onPromptsMutated() {
        guard hasFinishedInitialLoad else { return }
        saveToDisk()
        scheduleRandomPromptsDebounced(forceRebuild: true)
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
            ForEach(listsBinding(for: selectedCategory)) { $list in
                promptListSection(list: $list, category: selectedCategory)
            }

            Section {
                Button {
                    addList()
                } label: {
                    Label("New List", systemImage: "plus.circle")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Sections broken out

    @ViewBuilder
    private func promptListSection(list: Binding<PromptList>, category: PromptCategory) -> some View {
        Section {
            if list.wrappedValue.items.isEmpty {
                Text("No items yet. Add one below.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(list.wrappedValue.items, id: \.id) { item in
                    PromptRow(
                        item: item,
                        alertLabel: PromptAlertEditorModel.label(for: rules[item.id.uuidString]),
                        isImportant: rules[item.id.uuidString]?.isImportant == true,
                        isDoneToday: doneTodayPromptIDs.contains(item.id),
                        onAlertTap: {
                            alertEditor.begin(rule: rules[item.id.uuidString]) { newRule in
                                rules[item.id.uuidString] = newRule
                            }
                        },
                        onDone: { markPrompt(item, action: .done) },
                        onSkip: { markPrompt(item, action: .skipped) },
                        onToggleImportant: { toggleImportant(item) }
                    )
                }
                .onDelete { indexSet in
                    deleteItems(at: indexSet, listID: list.wrappedValue.id, in: category)
                }
            }

            AddItemRow(placeholder: placeholderText) { text in
                addItem(text, toListID: list.wrappedValue.id, in: category)
            }
        } header: {
            listSectionHeader(list: list, category: category)
        }
    }

    private func listSectionHeader(list: Binding<PromptList>, category: PromptCategory) -> some View {
        HStack {
            Text(list.wrappedValue.name)
            Spacer()
            Menu {
                Button {
                    renamingListID = list.wrappedValue.id
                    renameText = list.wrappedValue.name
                    showingRenameAlert = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    listPendingDeletion = (category, list.wrappedValue.id)
                    showingDeleteListConfirm = true
                } label: {
                    Label("Delete List", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sub-list add / rename / delete

    private func addList() {
        let binding = listsBinding(for: selectedCategory)
        let newList = PromptList(name: "New List")
        binding.wrappedValue.append(newList)
        renamingListID = newList.id
        renameText = newList.name
        showingRenameAlert = true
    }

    private func commitRename() {
        defer { renamingListID = nil }
        guard let id = renamingListID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let binding = listsBinding(for: selectedCategory)
        guard let idx = binding.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
        binding.wrappedValue[idx].name = trimmed
    }

    private func commitDeleteList() {
        defer { listPendingDeletion = nil }
        guard let (category, listID) = listPendingDeletion else { return }

        let binding = listsBinding(for: category)
        guard let idx = binding.wrappedValue.firstIndex(where: { $0.id == listID }) else { return }

        let removedItemIDs = binding.wrappedValue[idx].items.map(\.id)

        if binding.wrappedValue.count == 1 {
            // Never leave a category with zero lists — reset to an empty default instead.
            binding.wrappedValue[idx] = PromptList()
        } else {
            binding.wrappedValue.remove(at: idx)
        }

        removedItemIDs.forEach { rules[$0.uuidString] = nil }
    }

    // MARK: - Add / Delete items

    private func markPrompt(_ item: PromptItem, action: PromptAction) {
        PromptStatusStore.append(
            PromptActionEvent(promptID: item.id, promptText: item.text, action: action)
        )

        // Cancel pending notifications and remove delivered banners for this prompt
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

        // Done removes the prompt unless it is a repeating schedule (those come back by design)
        if action == .done {
            doneTodayPromptIDs.insert(item.id)
            NotificationsManager.shared.scheduleMorningUpdateIfNeeded()
            let rule = rules[item.id.uuidString]
            if rule?.isImportant == true {
                triggerReward()
            }
            if rule?.oneOff != false {
                switch rule?.recurrenceKind {
                case nil, .none?, .oneOff:
                    removePrompt(item)
                default:
                    break  // keep repeating prompts in the list
                }
            }
        }

        scheduleRandomPromptsDebounced(forceRebuild: true)
    }

    private func toggleImportant(_ item: PromptItem) {
        var rule = rules[item.id.uuidString] ?? PromptRule()
        rule.isImportant = !(rule.isImportant ?? false)
        rules[item.id.uuidString] = rule
    }

    private func removePrompt(_ item: PromptItem) {
        for binding in allCategoryBindings {
            for idx in binding.wrappedValue.indices {
                binding.wrappedValue[idx].items.removeAll { $0.id == item.id }
            }
        }
        rules[item.id.uuidString] = nil
    }

    private func addItem(_ text: String, toListID listID: UUID, in category: PromptCategory) {
        let newItem = PromptItem(text: text)
        let binding = listsBinding(for: category)
        guard let idx = binding.wrappedValue.firstIndex(where: { $0.id == listID }) else { return }
        binding.wrappedValue[idx].items.append(newItem)

        // Default all new prompts to repeat so they survive being marked done
        if rules[newItem.id.uuidString] == nil {
            rules[newItem.id.uuidString] = PromptRule(oneOff: false)
        }
    }

    private func deleteItems(at indexSet: IndexSet, listID: UUID, in category: PromptCategory) {
        let binding = listsBinding(for: category)
        guard let idx = binding.wrappedValue.firstIndex(where: { $0.id == listID }) else { return }

        let removedIDs = indexSet.map { binding.wrappedValue[idx].items[$0].id }
        binding.wrappedValue[idx].items.remove(atOffsets: indexSet)
        removedIDs.forEach { rules[$0.uuidString] = nil }
    }

    // MARK: - Done cleanup

    /// Removes prompts marked done via notification, unless they are repeating.
    /// Called on launch and when the app returns to the foreground.
    private func purgeCompletedOneOffPrompts() {
        let doneIDs = Set(
            PromptStatusStore.load()
                .filter { $0.action == .done }
                .map { $0.promptID }
        )
        guard !doneIDs.isEmpty else { return }

        let shouldRemove: (PromptItem) -> Bool = { [rules] item in
            guard doneIDs.contains(item.id) else { return false }
            let rule = rules[item.id.uuidString]
            if rule?.oneOff == false { return false }  // explicitly marked repeat, keep it
            switch rule?.recurrenceKind {
            case nil, .none?, .oneOff: return true
            default: return false  // keep repeating prompts in the list
            }
        }

        var removedIDs: [UUID] = []
        for binding in allCategoryBindings {
            for idx in binding.wrappedValue.indices {
                let removed = binding.wrappedValue[idx].items.filter(shouldRemove)
                guard !removed.isEmpty else { continue }
                removedIDs.append(contentsOf: removed.map(\.id))
                binding.wrappedValue[idx].items.removeAll(where: shouldRemove)
            }
        }

        guard !removedIDs.isEmpty else { return }
        for id in removedIDs {
            rules[id.uuidString] = nil
        }
    }

    /// Recomputes which prompts were marked done today, so their rows can be greyed out.
    /// Prompts marked done on a prior day fall out of this set automatically, making them
    /// markable again.
    private func refreshDoneTodaySet() {
        doneTodayPromptIDs = Set(
            PromptStatusStore.load()
                .filter { $0.action == .done && Calendar.current.isDateInToday($0.occurredAt) }
                .map { $0.promptID }
        )
    }

    // MARK: - Persistence

    private func saveRules() {
        PromptRulesStore.save(rules)
    }

    /// Fixes rules where oneOff=true was accidentally written over a real recurrence structure
    /// (weekday, monthly, fortnightly, or yearly fields). oneOff=true only makes sense alongside
    /// an explicit date or a bare time — pairing it with recurrence fields is always wrong.
    private func repairCorruptedRules() {
        var changed = false
        for (key, rule) in rules {
            guard rule.oneOff == true else { continue }
            let hasRecurrence = rule.weekday != nil
                || rule.monthlyDay != nil
                || (rule.monthlyIsLastDay ?? false)
                || rule.fortnightlyAnchorDate != nil
                || (rule.month != nil && rule.day != nil)
            guard hasRecurrence else { continue }
            var fixed = rule
            fixed.oneOff = false
            rules[key] = fixed
            changed = true
        }
        if changed { saveRules() }
    }

    private func saveToDisk() {
        let state = PromptsState(
            dailyLists:        dailyLists,
            weeklyLists:       weeklyLists,
            workLists:         workLists,
            monthlyLists:      monthlyLists,
            yearlyLists:       yearlyLists,
            eventsLists:       eventsLists,
            studyLists:        studyLists,
            mentalHealthLists: mentalHealthLists
        )
        PromptsStore.save(state)
    }

    // MARK: - Helpers

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
