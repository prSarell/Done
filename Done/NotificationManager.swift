//
//  NotificationsManager.swift
//  Done
//

import Foundation
import UserNotifications

final class NotificationsManager {
    static let shared = NotificationsManager()
    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, err in
            if let err = err {
                print("Notification auth error:", err)
            } else {
                print("Notification auth granted:", granted)
            }
        }
    }

    func registerCategories() {
        let done = UNNotificationAction(
            identifier: PromptNotificationDelegate.actionDoneID,
            title: "Done!",
            options: []
        )

        let skip = UNNotificationAction(
            identifier: PromptNotificationDelegate.actionSkipID,
            title: "Skip",
            options: []
        )

        let cat = UNNotificationCategory(
            identifier: PromptNotificationDelegate.categoryID,
            actions: [done, skip],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([cat])

        #if DEBUG
        print("🔧 NotificationsManager: registered prompt action category")
        #endif
    }

    func scheduleDaily(id: String, title: String, time: Date) {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)

        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: comps,
            repeats: true
        )

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { err in
            if let err = err {
                print("Failed to schedule daily notification:", err)
            } else {
                print("Scheduled daily notification:", id, comps)
            }
        }
    }

    func scheduleOneOff(
        id: String,
        title: String,
        at date: Date,
        userInfo: [AnyHashable: Any]? = nil,
        categoryID: String? = nil
    ) {
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )

        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default

        if let userInfo {
            content.userInfo = userInfo
        }

        if let categoryID {
            content.categoryIdentifier = categoryID
        }

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: comps,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { err in
            if let err = err {
                print("Failed to schedule one-off notification:", err)
            } else {
                print("Scheduled one-off notification:", id, comps)
            }
        }
    }

    func cancel(id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func cancelAll(prefix: String, completion: (() -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()

        center.getPendingNotificationRequests { requests in
            let pendingIDs = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(prefix) }

            if !pendingIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
            }

            center.getDeliveredNotifications { delivered in
                let deliveredIDs = delivered
                    .map { $0.request.identifier }
                    .filter { $0.hasPrefix(prefix) }

                if !deliveredIDs.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
                }

                #if DEBUG
                print("🔕 NotificationsManager: cancelled \(pendingIDs.count) pending + \(deliveredIDs.count) delivered for prefix '\(prefix)'")
                #endif

                completion?()
            }
        }
    }
}
