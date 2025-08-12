//
//  NotificationManager.swift
//  Done
//
//  Created by Patrick Sarell on 23/8/2025.
//

import Foundation
import UserNotifications

final class NotificationsManager {
    static let shared = NotificationsManager()
    private init() {}

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
    /// - Parameters:
    ///   - id: stable identifier per item (use item.id.uuidString)
    ///   - title: notification title/body
    ///   - time: Date containing the desired time-of-day (hour/minute used)
    func scheduleDaily(id: String, title: String, time: Date) {
        // Build date components from 'time' (hour/minute)
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

    func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
