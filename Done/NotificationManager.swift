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
        subtitle: String? = nil,
        userInfo: [AnyHashable: Any]? = nil,
        categoryID: String? = nil
    ) {
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )

        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
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

    func scheduleDailySummary(doneCount: Int) {
        let id = "daily-summary-\(Self.dateKey(for: Date()))"
        cancel(id: id)

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 21
        comps.minute = 0
        comps.second = 0
        guard let fireDate = Calendar.current.date(from: comps), fireDate > Date() else { return }

        let noun = doneCount == 1 ? "task" : "tasks"
        scheduleOneOff(id: id, title: "\(doneCount) \(noun) Done today!", at: fireDate)
    }

    /// Tasks completed after the 9pm summary has already fired go unmentioned that day.
    /// Call this whenever a prompt is marked done; if it's currently at/after 9pm, this
    /// (re)schedules a follow-up notification for 8am the next morning summarizing how many
    /// extra tasks got done overnight. Safe to call repeatedly — each call replaces the
    /// previous morning notification for today with an up-to-date count.
    func scheduleMorningUpdateIfNeeded(referenceDate: Date = Date(), calendar: Calendar = .current) {
        guard let dayStart = calendar.date(
            from: calendar.dateComponents([.year, .month, .day], from: referenceDate)
        ) else { return }
        guard let cutoff = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: dayStart) else { return }
        guard referenceDate >= cutoff else { return }

        let events = PromptStatusStore.load()
        let todayDoneEvents = events.filter {
            $0.action == .done && calendar.isDate($0.occurredAt, inSameDayAs: referenceDate)
        }
        let bonusCount = todayDoneEvents.filter { $0.occurredAt >= cutoff }.count
        guard bonusCount > 0 else { return }
        let totalCount = todayDoneEvents.count

        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let fireDate = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrowStart)
        else { return }

        let id = "morning-update-\(Self.dateKey(for: referenceDate))"
        cancel(id: id)

        let bonusNoun = bonusCount == 1 ? "task" : "tasks"
        let totalNoun = totalCount == 1 ? "task" : "tasks"
        let title = "\(totalCount) \(totalNoun) done yesterday!"
        let subtitle = "\(bonusCount) more \(bonusNoun) done after 9pm"
        scheduleOneOff(id: id, title: title, at: fireDate, subtitle: subtitle)
    }

    private static func dateKey(for date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
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

            center.getDeliveredNotifications { delivered in
                let deliveredIDs = delivered
                    .map { $0.request.identifier }
                    .filter { $0.hasPrefix(prefix) }

                DispatchQueue.main.async {
                    if !pendingIDs.isEmpty {
                        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
                    }

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
}
