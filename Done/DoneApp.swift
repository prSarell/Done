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
                .onAppear {
                    NotificationsManager.shared.requestAuthorization()

                    // Only plan once per foreground session
                    if !didPlanThisForeground {
                        didPlanThisForeground = true

                        performOneOffCleanup()

                        let prompts = loadAllPromptsFromDisk()
                        RandomPromptScheduler.shared.refreshScheduleToday(allPrompts: prompts)

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
                        RandomPromptScheduler.shared.refreshScheduleToday(allPrompts: prompts)
                    }
                }
                // When leaving foreground, reset the gate so next foreground can plan once
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    didPlanThisForeground = false
                }
        }
    }
}

// MARK: - Prompts load/save helpers (same schema PromptsView uses)

private struct PromptsState: Codable {
    var dailyItems:        [PromptItem] = []
    var weeklyItems:       [PromptItem] = []
    var workItems:         [PromptItem] = []   // ✅ IMPORTANT: you have Work in PromptsView
    var monthlyItems:      [PromptItem] = []
    var yearlyItems:       [PromptItem] = []
    var eventsItems:       [PromptItem] = []
    var studyItems:        [PromptItem] = []
    var mentalHealthItems: [PromptItem] = []
}

/// Returns all prompt items across all categories for scheduling.
/// IMPORTANT: If prompts.json fails to load/decode, returns [] but does NOT write anything to disk.
private func loadAllPromptsFromDisk() -> [PromptItem] {
    guard let s = loadPromptsStateSafe() else {
        #if DEBUG
        print("🛑 loadAllPromptsFromDisk: prompts.json failed to load; returning [] for scheduling only.")
        #endif
        return []
    }

    return s.dailyItems
         + s.weeklyItems
         + s.workItems            // ✅ include work
         + s.monthlyItems
         + s.yearlyItems
         + s.eventsItems
         + s.studyItems
         + s.mentalHealthItems
}

/// Safe loader:
/// - If prompts.json does not exist, returns an empty PromptsState (first-run case).
/// - If reading/decoding fails, returns nil (so callers can avoid overwriting prompts.json with empty state).
private func loadPromptsStateSafe() -> PromptsState? {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = docs.appendingPathComponent("prompts.json")

    // Missing file is normal on first run
    guard FileManager.default.fileExists(atPath: url.path) else {
        return PromptsState()
    }

    do {
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(PromptsState.self, from: data)
    } catch {
        #if DEBUG
        print("❌ loadPromptsStateSafe failed: \(error)")
        print("   → Bundle: \(Bundle.main.bundleIdentifier ?? "nil")")
        print("   → File: \(url.path)")
        #endif
        return nil
    }
}

/// Writes prompts.json atomically.
private func savePromptsState(_ state: PromptsState) {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = docs.appendingPathComponent("prompts.json")

    let enc = JSONEncoder()
    enc.outputFormatting = [.withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601

    if let data = try? enc.encode(state) {
        do {
            try data.write(to: url, options: .atomic)
            #if DEBUG
            print("💾 savePromptsState: wrote prompts.json (\(data.count) bytes)")
            print("   → Bundle: \(Bundle.main.bundleIdentifier ?? "nil")")
            print("   → File: \(url.path)")
            #endif
        } catch {
            #if DEBUG
            print("❌ savePromptsState write error: \(error)")
            print("   → File: \(url.path)")
            #endif
        }
    } else {
        #if DEBUG
        print("❌ savePromptsState: failed to encode PromptsState")
        #endif
    }
}

// MARK: - One-off cleanup (delete prompts whose dated rule has passed)

private func performOneOffCleanup() {
    var rules = PromptRulesStore.load()
    guard !rules.isEmpty else { return }

    let now = Date()
    var toDeleteTexts: [String] = []

    for (text, rule) in rules {
        if rule.shouldAutoDelete(after: now) {
            toDeleteTexts.append(text)
        }
    }

    guard !toDeleteTexts.isEmpty else { return }

    // CRITICAL: only proceed if prompts.json loads successfully.
    guard var state = loadPromptsStateSafe() else {
        print("🛑 OneOffCleanup: aborted because prompts.json failed to load (preventing overwrite).")
        return
    }

    let filter: ([PromptItem]) -> [PromptItem] = { arr in
        arr.filter { !toDeleteTexts.contains($0.text) }
    }

    state.dailyItems        = filter(state.dailyItems)
    state.weeklyItems       = filter(state.weeklyItems)
    state.workItems         = filter(state.workItems)   // ✅ cleanup work too
    state.monthlyItems      = filter(state.monthlyItems)
    state.yearlyItems       = filter(state.yearlyItems)
    state.eventsItems       = filter(state.eventsItems)
    state.studyItems        = filter(state.studyItems)
    state.mentalHealthItems = filter(state.mentalHealthItems)

    savePromptsState(state)

    toDeleteTexts.forEach { rules.removeValue(forKey: $0) }
    PromptRulesStore.save(rules)

    print("OneOffCleanup: removed \(toDeleteTexts.count) dated prompts: \(toDeleteTexts)")
}
