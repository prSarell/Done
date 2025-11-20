import SwiftUI
import UserNotifications
import UIKit

@main
struct DoneApp: App {
    // Provide the notes VM app-wide so TimerView can save notes
    @StateObject private var notesVM = TimerNotesViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notesVM)
                .onAppear {
                    // Notifications
                    NotificationsManager.shared.requestAuthorization()

                    // Clean up any "one-off" prompts whose dated rule has passed (safe no-op if none)
                    performOneOffCleanup()

                    // Load prompts + schedule the day
                    let prompts = loadAllPromptsFromDisk()
                    RandomPromptScheduler.shared.refreshScheduleToday(allPrompts: prompts)

                    // Optional visibility for testing
                    UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
                        print("Pending notifications:", reqs.count)
                    }
                }
                // Optional: re-plan when returning to foreground (picks up any rule/prompt edits)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    let prompts = loadAllPromptsFromDisk()
                    RandomPromptScheduler.shared.refreshScheduleToday(allPrompts: prompts)
                }
        }
    }
}

// MARK: - Prompts load/save helpers (same schema PromptsView uses)
private struct PromptsState: Codable {
    var dailyItems:        [PromptItem] = []
    var weeklyItems:       [PromptItem] = []
    var monthlyItems:      [PromptItem] = []
    var yearlyItems:       [PromptItem] = []
    var eventsItems:       [PromptItem] = []
    var studyItems:        [PromptItem] = []
    var mentalHealthItems: [PromptItem] = []
}

private func loadAllPromptsFromDisk() -> [PromptItem] {
    let s = loadPromptsState()
    return s.dailyItems + s.weeklyItems + s.monthlyItems + s.yearlyItems +
           s.eventsItems + s.studyItems + s.mentalHealthItems
}

private func loadPromptsState() -> PromptsState {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = docs.appendingPathComponent("prompts.json")
    do {
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(PromptsState.self, from: data)
    } catch {
        return PromptsState()
    }
}

private func savePromptsState(_ state: PromptsState) {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = docs.appendingPathComponent("prompts.json")
    let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes]; enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(state) {
        try? data.write(to: url, options: .atomic)
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

    // Remove those prompts from PromptsState and from rules file
    var state = loadPromptsState()
    let filter: ([PromptItem]) -> [PromptItem] = { arr in arr.filter { !toDeleteTexts.contains($0.text) } }

    state.dailyItems        = filter(state.dailyItems)
    state.weeklyItems       = filter(state.weeklyItems)
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
