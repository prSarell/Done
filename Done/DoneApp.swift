// File: Done/DoneApp.swift
// Purpose:
// - App entry point
// - Provides TimerNotesViewModel as an EnvironmentObject
// - Requests notification permissions
// - Registers notification categories + delegate for Done/Skip actions
// - Performs one-off prompt cleanup WITHOUT risking overwriting prompts.json on load/decode failure
// - Loads prompts from disk and refreshes today's random schedule
// - Prevents repeated scheduling spam by gating "plan today" to once per foreground session

import SwiftUI
import UserNotifications
import UIKit

@main
struct DoneApp: App {
    @StateObject private var notesVM = TimerNotesViewModel()
    @StateObject private var rewardsVM = RewardsViewModel()

    // ✅ Add delegate instance (must be strongly held)
    private let notifDelegate = PromptNotificationDelegate()

    // Gate scheduling so we don't spam-refresh during launch / permission prompts
    @State private var didPlanThisForeground = false

    // ✅ Use init to set delegate + register categories once
    init() {
        let center = UNUserNotificationCenter.current()
        center.delegate = notifDelegate

        NotificationsManager.shared.registerCategories()

        // Settings.bundle defaults (Settings app → Done!) — must mirror the DefaultValue
        // entries in Done/Settings.bundle/Root.plist and the per-category child pane plists.
        UserDefaults.standard.register(defaults: [
            "notification_intensity": 0.5,
            "global_earliest_hour": 7,
            "global_latest_hour": 20,
            "quiet_daily_start": 0, "quiet_daily_end": 0, "quiet_daily_weekends": false,
            "quiet_weekly_start": 0, "quiet_weekly_end": 0, "quiet_weekly_weekends": false,
            "quiet_work_start": 17, "quiet_work_end": 9, "quiet_work_weekends": true,
            "quiet_monthly_start": 0, "quiet_monthly_end": 0, "quiet_monthly_weekends": false,
            "quiet_yearly_start": 0, "quiet_yearly_end": 0, "quiet_yearly_weekends": false,
            "quiet_events_start": 0, "quiet_events_end": 0, "quiet_events_weekends": false,
            "quiet_study_start": 0, "quiet_study_end": 0, "quiet_study_weekends": false,
            "quiet_mentalhealth_start": 0, "quiet_mentalhealth_end": 0, "quiet_mentalhealth_weekends": false,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notesVM)
                .environmentObject(rewardsVM)
                .onAppear {
                    NotificationsManager.shared.requestAuthorization()

                    // Only plan once per foreground session
                    if !didPlanThisForeground {
                        didPlanThisForeground = true

                        performOneOffCleanup()

                        let prompts = loadAllPromptsFromDisk()
                        let (rules, categoryQuietWindows, settingsChanged) = currentPromptSettings()
                        RandomPromptScheduler.shared.refreshScheduleToday(
                            allPrompts: prompts,
                            categoryPromptIDs: loadCategoryPromptIDsFromDisk(),
                            categoryQuietWindows: categoryQuietWindows,
                            rules: rules,
                            forceRebuild: settingsChanged
                        )

                        NotificationsManager.shared.scheduleDailySummary(
                            doneCount: doneTodayCount()
                        )

                        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
                            print("Pending notifications:", reqs.count)
                        }
                    }
                }
                // When app becomes active again later, allow a re-plan (once)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    if !didPlanThisForeground {
                        didPlanThisForeground = true

                        let prompts = loadAllPromptsFromDisk()
                        let (rules, categoryQuietWindows, settingsChanged) = currentPromptSettings()
                        RandomPromptScheduler.shared.refreshScheduleToday(
                            allPrompts: prompts,
                            categoryPromptIDs: loadCategoryPromptIDsFromDisk(),
                            categoryQuietWindows: categoryQuietWindows,
                            rules: rules,
                            forceRebuild: settingsChanged
                        )

                        NotificationsManager.shared.scheduleDailySummary(
                            doneCount: doneTodayCount()
                        )
                    }
                }
                // When leaving foreground, reset the gate so next foreground can plan once
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    didPlanThisForeground = false
                }
        }
    }
}

// MARK: - Settings.bundle → scheduler config (Settings app → Done!)

/// Reads global + per-category quiet-hours settings from the Settings app and reports
/// whether anything changed since the last time we applied it, so the caller can force a
/// same-day schedule rebuild (the scheduler otherwise only plans once per calendar day).
private func currentPromptSettings() -> (
    rules: RandomPromptRules,
    categoryQuietWindows: [PromptCategory: CategoryQuietWindow],
    changed: Bool
) {
    let rules = RandomPromptRules.loadFromUserDefaults()
    let categoryQuietWindows = CategoryQuietWindow.loadAllFromUserDefaults()

    let windowsSignature = categoryQuietWindows
        .sorted { $0.key.settingsKey < $1.key.settingsKey }
        .map { "\($0.key.settingsKey):\($0.value.startHour)-\($0.value.endHour)-\($0.value.weekendsQuiet)" }
        .joined(separator: ",")
    let signature = "\(rules.intervalMinutes)|\(rules.dayStartHour)|\(rules.dayEndHour)|\(windowsSignature)"

    let defaults = UserDefaults.standard
    let lastAppliedKey = "last_applied_prompt_settings_signature"
    let changed = defaults.string(forKey: lastAppliedKey) != signature
    defaults.set(signature, forKey: lastAppliedKey)

    return (rules, categoryQuietWindows, changed)
}

// MARK: - Prompts load helpers (PromptsStore in Storage/PromptsStore.swift owns persistence)

/// Returns prompt IDs grouped by category, for per-category quiet-hours filtering.
private func loadCategoryPromptIDsFromDisk() -> [PromptCategory: Set<UUID>] {
    PromptsStore.loadSafe()?.categoryPromptIDs ?? [:]
}

/// Returns all prompt items across all categories for scheduling.
/// IMPORTANT: If prompts.json fails to load/decode, returns [] but does NOT write anything to disk.
private func loadAllPromptsFromDisk() -> [PromptItem] {
    guard let s = PromptsStore.loadSafe() else {
        #if DEBUG
        print("🛑 loadAllPromptsFromDisk: prompts.json failed to load; returning [] for scheduling only.")
        #endif
        return []
    }
    return s.allItems
}

// MARK: - One-off cleanup (delete prompts whose dated rule has passed)

private func performOneOffCleanup() {
    // Cheap early exit before touching prompts.json at all. Bail on load failure too —
    // an empty result here could mean "no rules" or "decode failed", and treating a
    // failure as "no rules" is safe (nothing gets deleted below).
    guard let existingRules = PromptRulesStore.load(), !existingRules.isEmpty else { return }

    // CRITICAL: only proceed if prompts.json loads successfully.
    guard let state = PromptsStore.loadSafe() else {
        print("🛑 OneOffCleanup: aborted because prompts.json failed to load (preventing overwrite).")
        return
    }

    // CRITICAL: only proceed if prompt_rules.json loads successfully — otherwise the
    // save below would overwrite it with a near-empty dict.
    guard var rules = PromptRulesStore.loadMigratingIfNeeded(using: state.allItems) else {
        print("🛑 OneOffCleanup: aborted because prompt_rules.json failed to load (preventing overwrite).")
        return
    }

    let now = Date()
    let toDeleteIDs = Set(rules.compactMap { key, rule -> UUID? in
        guard rule.shouldAutoDelete(after: now), let id = UUID(uuidString: key) else { return nil }
        return id
    })
    guard !toDeleteIDs.isEmpty else { return }

    func filter(_ lists: [PromptList]) -> [PromptList] {
        lists.map { list in
            var list = list
            list.items.removeAll { toDeleteIDs.contains($0.id) }
            return list
        }
    }

    var updatedState = state
    updatedState.dailyLists        = filter(state.dailyLists)
    updatedState.weeklyLists       = filter(state.weeklyLists)
    updatedState.workLists         = filter(state.workLists)   // ✅ cleanup work too
    updatedState.monthlyLists      = filter(state.monthlyLists)
    updatedState.yearlyLists       = filter(state.yearlyLists)
    updatedState.eventsLists       = filter(state.eventsLists)
    updatedState.studyLists        = filter(state.studyLists)
    updatedState.mentalHealthLists = filter(state.mentalHealthLists)

    PromptsStore.save(updatedState)

    toDeleteIDs.forEach { rules.removeValue(forKey: $0.uuidString) }
    PromptRulesStore.save(rules)

    print("OneOffCleanup: removed \(toDeleteIDs.count) dated prompts")
}

// MARK: - Daily summary helper

/// Not private: called wherever a prompt is marked done, so the 9pm summary notification's
/// baked-in count can be refreshed rather than going stale from whatever it was when the app
/// was last opened.
func doneTodayCount() -> Int {
    PromptStatusStore.load()
        .filter { $0.action == .done && Calendar.current.isDateInToday($0.occurredAt) }
        .count
}
