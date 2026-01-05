//
//  PromptNotificationDelegate.swift
//  Done
//
//  Created by Patrick Sarell on 6/1/2026.
//

// Path: Done/Notifications/PromptNotificationDelegate.swift

import Foundation
import UserNotifications

final class PromptNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    // Category + Action IDs
    static let categoryID = "prompt-actions"
    static let actionDoneID = "prompt-done"
    static let actionSkipID = "prompt-skip"

    // Keys in content.userInfo
    static let kPromptID = "prompt_id"
    static let kPromptText = "prompt_text"

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

        #if DEBUG
        print("✅ Recorded prompt action:", action.rawValue, "|", promptText)
        #endif
    }
}
