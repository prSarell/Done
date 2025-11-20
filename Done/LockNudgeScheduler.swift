//
//  LockNudgeScheduler.swift
//  Done
//
//  Created by Patrick Sarell on 5/11/2025.
//

// LockNudgeScheduler.swift
import Foundation
import UserNotifications

final class LockNudgeScheduler {
    static let shared = LockNudgeScheduler()
    private init() {}

    // Tuning
    var delaySeconds: TimeInterval = 5        // fire shortly after you lock
    var cooldownMinutes: Int = 10             // don’t nudge again if you lock repeatedly
    var quietStartHour: Int = 22              // 22:00 → 07:00 no nudges
    var quietEndHour: Int = 7

    // Persistence
    private let lastNudgeKey = "LockNudgeScheduler.lastNudgeAt"
    private let lastTextKey  = "LockNudgeScheduler.lastText"

    private var lastNudgeAt: Date? {
        get { UserDefaults.standard.object(forKey: lastNudgeKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastNudgeKey) }
    }
    private var lastText: String? {
        get { UserDefaults.standard.string(forKey: lastTextKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastTextKey) }
    }

    /// Main entry: call when app is about to background (user locks phone).
    func scheduleNudgeIfAllowed(prompts: [PromptItem]) {
        guard let prompt = pickPrompt(from: prompts, avoiding: lastText) else { return }

        let now = Date()
        if inQuietHours(after: delaySeconds, from: now) { return }
        if let last = lastNudgeAt, now.timeIntervalSince(last) < Double(cooldownMinutes * 60) { return }

        // Remove any previously queued lock-nudges to avoid stacking
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            let ids = reqs.filter { $0.identifier.hasPrefix("lock-nudge-") }.map { $0.identifier }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)

            // Schedule fresh nudge
            let fire = now.addingTimeInterval(self.delaySeconds)
            let id = "lock-nudge-\(UUID().uuidString.prefix(6))"
            NotificationsManager.shared.scheduleOneOff(id: id, title: prompt.text, at: fire)

            #if DEBUG
            print("LockNudge: scheduled '\(prompt.text)' at \(fire)")
            #endif

            self.lastNudgeAt = now
            self.lastText = prompt.text
        }
    }

    // MARK: - Helpers

    private func inQuietHours(after delay: TimeInterval, from base: Date) -> Bool {
        let cal = Calendar.current
        let target = base.addingTimeInterval(delay)
        let h = cal.component(.hour, from: target)
        if quietStartHour < quietEndHour {
            // e.g., 22..7 (invalid window if start < end, so treat as daytime block)
            return (h >= quietStartHour && h < quietEndHour)
        } else {
            // Overnight window (e.g., 22 → 7)
            return (h >= quietStartHour || h < quietEndHour)
        }
    }

    private func pickPrompt(from prompts: [PromptItem], avoiding last: String?) -> PromptItem? {
        guard !prompts.isEmpty else { return nil }
        if let last, prompts.count > 1 {
            let filtered = prompts.filter { $0.text != last }
            return (filtered.isEmpty ? prompts : filtered).randomElement()
        }
        return prompts.randomElement()
    }
}
