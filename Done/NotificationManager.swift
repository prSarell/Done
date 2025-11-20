//
//  NotificationsManager.swift
//  Done
//
//  Created by Patrick Sarell on 23/8/2025.
//

import Foundation
import UserNotifications

final class NotificationsManager {
    static let shared = NotificationsManager()
    private init() {}

    // Ask once at app launch
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, err in
            if let err = err {
                print("Notification auth error:", err)
            } else {
                print("Notification auth granted:", granted)
            }
        }
    }

    /// Schedule a repeating daily notification at a specific time (hour/minute).
    func scheduleDaily(id: String, title: String, time: Date) {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)

        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { err in
            if let err = err {
                print("Failed to schedule daily notification:", err)
            } else {
                print("Scheduled daily notification:", id, comps)
            }
        }
    }

    /// Schedule a one-off (non-repeating) notification at an exact date/time.
    func scheduleOneOff(id: String, title: String, at date: Date) {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { err in
            if let err = err {
                print("Failed to schedule one-off notification:", err)
            } else {
                print("Scheduled one-off notification:", id, comps)
            }
        }
    }

    /// Cancel any pending or delivered notifications with the given id.
    func cancel(id: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: - Debug helper to confirm notifications work
    /// Schedules a test notification 30 seconds from now.
    func debugTestNotification() {
        let date = Date().addingTimeInterval(30)
        scheduleOneOff(id: "testNotification", title: "✅ Done! Test Notification", at: date)
        print("Debug test notification scheduled for:", date)
    }
}
