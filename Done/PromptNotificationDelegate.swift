//
//  PromptNotificationDelegate.swift
//  Done
//
//  Created by Patrick Sarell on 6/1/2026.
//

// Path: Done/Notifications/PromptNotificationDelegate.swift

import Foundation
import UserNotifications

@MainActor
final class PromptNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    // Category + Action IDs
    nonisolated static let categoryID = "prompt-actions"
    nonisolated static let actionDoneID = "prompt-done"
    nonisolated static let actionSkipID = "prompt-skip"

    // Keys in content.userInfo
    nonisolated static let kPromptID = "prompt_id"
    nonisolated static let kPromptText = "prompt_text"
    nonisolated static let kPromptDate = "prompt_date"

    // Show banner while app open
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if let idString = notification.request.content.userInfo[Self.kPromptID] as? String,
           let promptID = UUID(uuidString: idString),
           Self.actedOnToday(promptID) {
            await NotificationsManager.shared.clearNotifications(forPromptID: promptID)
            return []
        }

        // The new banner isn't in the delivered list until after this returns, so collapse
        // shortly afterwards to clear the older copies it replaces.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NotificationsManager.shared.collapseDeliveredDuplicates()
        }
        return [.banner, .sound]
    }

    // Handle Done/Skip action taps
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo

        guard
            let idString = userInfo[Self.kPromptID] as? String,
            let promptID = UUID(uuidString: idString),
            let promptText = userInfo[Self.kPromptText] as? String
        else {
            #if DEBUG
            print("⚠️ PromptNotificationDelegate: missing prompt metadata in userInfo")
            #endif
            return
        }

        let action: PromptAction?
        switch response.actionIdentifier {
        case Self.actionDoneID: action = .done
        case Self.actionSkipID: action = .skipped
        default: action = nil
        }

        guard let action else { return }

        // Use the date the prompt was scheduled/delivered for, not "now" — otherwise
        // acting on a stale banner from a previous day records it against today.
        let occurredAt: Date
        if let epoch = userInfo[Self.kPromptDate] as? Double {
            occurredAt = Date(timeIntervalSince1970: epoch)
        } else {
            occurredAt = response.notification.date
        }

        PromptStatusStore.append(
            PromptActionEvent(promptID: promptID, promptText: promptText, action: action, occurredAt: occurredAt)
        )

        if action == .done {
            NotificationsManager.shared.scheduleMorningUpdateIfNeeded()
            NotificationsManager.shared.scheduleDailySummary(doneCount: doneTodayCount())
        }

        #if DEBUG
        print("✅ Recorded prompt action:", action.rawValue, "|", promptText)
        #endif

        // Cancel any remaining queued notifications for this prompt so they don't fire later today,
        // and clear its delivered banners from the lock screen. Awaited in full: once this
        // returns iOS may suspend the app straight away.
        await NotificationsManager.shared.clearNotifications(forPromptID: promptID)
    }

    /// True when the prompt already has a done/skip recorded today — a banner for it that
    /// slipped through (e.g. queued by a re-plan that started just before the action) is
    /// dropped instead of shown.
    private static func actedOnToday(_ promptID: UUID) -> Bool {
        let todayStart = Calendar.current.startOfDay(for: Date())
        return PromptStatusStore.load().contains { $0.promptID == promptID && $0.occurredAt >= todayStart }
    }
}
