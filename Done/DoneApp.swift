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
                        RandomPromptScheduler.shared.refreshScheduleToday(
                            allPrompts: prompts,
                            workPromptIDs: loadWorkPromptIDsFromDisk()
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
                        RandomPromptScheduler.shared.refreshScheduleToday(
                            allPrompts: prompts,
                            workPromptIDs: loadWorkPromptIDsFromDisk()
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

// MARK: - Prompts load helpers (PromptsStore in Storage/PromptsStore.swift owns persistence)

/// Returns UUIDs of Work-category prompts for time-gating in the random scheduler.
private func loadWorkPromptIDsFromDisk() -> Set<UUID> {
    guard let s = PromptsStore.loadSafe() else { return [] }
    return Set(s.workLists.allItems.map(\.id))
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
    // Cheap early exit before touching prompts.json at all.
    guard !PromptRulesStore.load().isEmpty else { return }

    // CRITICAL: only proceed if prompts.json loads successfully.
    guard let state = PromptsStore.loadSafe() else {
        print("🛑 OneOffCleanup: aborted because prompts.json failed to load (preventing overwrite).")
        return
    }

    var rules = PromptRulesStore.loadMigratingIfNeeded(using: state.allItems)

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

private func doneTodayCount() -> Int {
    PromptStatusStore.load()
        .filter { $0.action == .done && Calendar.current.isDateInToday($0.occurredAt) }
        .count
}
