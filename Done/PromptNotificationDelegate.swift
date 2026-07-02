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

    // Show banner while app open
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
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

        PromptStatusStore.append(
            PromptActionEvent(promptID: promptID, promptText: promptText, action: action)
        )

        if action == .done {
            NotificationsManager.shared.scheduleMorningUpdateIfNeeded()
        }

        #if DEBUG
        print("✅ Recorded prompt action:", action.rawValue, "|", promptText)
        #endif

        // Cancel any remaining queued notifications for this prompt so they don't fire later today
        // Also remove delivered notifications so stale banners clear from the lock screen
        let center = UNUserNotificationCenter.current()
        async let pendingAsync = center.pendingNotificationRequests()
        async let deliveredAsync = center.deliveredNotifications()
        let (pending, delivered) = await (pendingAsync, deliveredAsync)
        let toCancel = pending
            .filter { $0.identifier.contains(promptID.uuidString) }
            .map { $0.identifier }
        let toRemove = delivered
            .filter { $0.request.identifier.contains(promptID.uuidString) }
            .map { $0.request.identifier }
        if !toCancel.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: toCancel)
            #if DEBUG
            print("🗑️ Cancelled \(toCancel.count) pending notification(s) for '\(promptText)'")
            #endif
        }
        if !toRemove.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: toRemove)
            #if DEBUG
            print("🗑️ Removed \(toRemove.count) delivered notification(s) for '\(promptText)'")
            #endif
        }
    }
}
