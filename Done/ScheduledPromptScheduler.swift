//
//  ScheduledPromptScheduler.swift
//  Done
//
//  Path: Done/Notifications/ScheduledPromptScheduler.swift
//

import Foundation
import UserNotifications

final class ScheduledPromptScheduler {
    static let shared = ScheduledPromptScheduler()
    private init() {}

    // Agreed rules
    private let horizonHours: Double = 24
    private let maxNotificationsPerPrompt: Int = 6
    private let overdueInterval: TimeInterval = 60 * 60 * 3   // 3 hours
    private let globalNotificationCap: Int = 60               // stay safely under iOS 64 cap
    private let idPrefix = "sched-"

    // Re-entrancy guard / throttle
    private let refreshLock = NSLock()
    private var isRefreshing: Bool = false
    private var lastRefreshAt: Date? = nil

    // MARK: - Entry point

    func refreshSchedule(
        prompts: [PromptItem],
        forceRebuild: Bool = true,
        calendar cal: Calendar = .current
    ) {
        refreshLock.lock()
        if isRefreshing {
            refreshLock.unlock()
            return
        }
        isRefreshing = true

        let nowForThrottle = Date()
        if let last = lastRefreshAt, nowForThrottle.timeIntervalSince(last) < 0.5 {
            isRefreshing = false
            refreshLock.unlock()
            return
        }
        lastRefreshAt = nowForThrottle
        refreshLock.unlock()

        let rulesByText = PromptRulesStore.load()
        let events = PromptStatusStore.load()

        // Only prompts with an actual schedule rule belong in this system
        let scheduledPrompts = prompts.filter { item in
            guard let rule = rulesByText[item.text] else { return false }
            return rule.hasSchedulingRule
        }

        guard !scheduledPrompts.isEmpty else {
            NotificationsManager.shared.cancelAll(prefix: idPrefix) { [weak self] in
                self?.finishRefresh()
            }
            return
        }

        NotificationsManager.shared.cancelAll(prefix: idPrefix) { [weak self] in
            guard let self else { return }

            let now = Date()
            let horizon = now.addingTimeInterval(self.horizonHours * 3600)

            var allRequests: [PendingScheduledNotification] = []

            for prompt in scheduledPrompts {
                guard let rule = rulesByText[prompt.text] else { continue }

                guard let target = self.currentOrNextTarget(
                    for: prompt,
                    rule: rule,
                    now: now,
                    events: events,
                    calendar: cal
                ) else {
                    continue
                }

                let dates = self.generateFireDates(
                    for: prompt,
                    rule: rule,
                    target: target,
                    now: now,
                    horizon: horizon,
                    calendar: cal
                )

                for (index, fireDate) in dates.enumerated() {
                    let id = self.notificationID(for: prompt.id, fireDate: fireDate, index: index)

                    let userInfo: [AnyHashable: Any] = [
                        PromptNotificationDelegate.kPromptID: prompt.id.uuidString,
                        PromptNotificationDelegate.kPromptText: prompt.text
                    ]

                    allRequests.append(
                        PendingScheduledNotification(
                            id: id,
                            title: prompt.text,
                            fireDate: fireDate,
                            userInfo: userInfo
                        )
                    )
                }
            }

            // Keep the earliest notifications only, so we stay under the global cap.
            let finalRequests = allRequests
                .sorted { $0.fireDate < $1.fireDate }
                .prefix(self.globalNotificationCap)

            for req in finalRequests {
                NotificationsManager.shared.scheduleOneOff(
                    id: req.id,
                    title: req.title,
                    at: req.fireDate,
                    userInfo: req.userInfo,
                    categoryID: PromptNotificationDelegate.categoryID
                )
            }

            #if DEBUG
            print("SPS: scheduled \(finalRequests.count) notifications across \(scheduledPrompts.count) scheduled prompts")
            #endif

            self.finishRefresh()
        }
    }

    // MARK: - Target selection

    /// Chooses the current cycle target if it's still incomplete, otherwise the next target.
    private func currentOrNextTarget(
        for prompt: PromptItem,
        rule: PromptRule,
        now: Date,
        events: [PromptActionEvent],
        calendar cal: Calendar
    ) -> Date? {
        // 1) If there is a past target whose cycle is still incomplete, keep using it.
        if let previousTarget = rule.previousTarget(before: now, calendar: cal) {
            let cycleStart = rule.leadInStart(for: previousTarget, now: now, calendar: cal)

            if now > previousTarget {
                let completed = cycleCompleted(
                    promptID: prompt.id,
                    cycleStart: cycleStart,
                    events: events
                )

                if !completed {
                    return previousTarget
                }
            }
        }

        // 2) Otherwise use the next target.
        guard let nextTarget = rule.nextTarget(after: now, calendar: cal) else {
            return nil
        }

        let cycleStart = rule.leadInStart(for: nextTarget, now: now, calendar: cal)
        let completed = cycleCompleted(
            promptID: prompt.id,
            cycleStart: cycleStart,
            events: events
        )

        if completed {
            // Current cycle already done early. For recurring prompts, jump to the next recurrence.
            let later = nextTarget.addingTimeInterval(1)

            return rule.nextTarget(after: later, calendar: cal)
        }

        return nextTarget
    }

    private func cycleCompleted(
        promptID: UUID,
        cycleStart: Date,
        events: [PromptActionEvent]
    ) -> Bool {
        let latestForCycle = events
            .filter { $0.promptID == promptID && $0.occurredAt >= cycleStart }
            .sorted { $0.occurredAt > $1.occurredAt }
            .first

        return latestForCycle?.action == .done
    }

    // MARK: - Fire date generation

    private func generateFireDates(
        for prompt: PromptItem,
        rule: PromptRule,
        target: Date,
        now: Date,
        horizon: Date,
        calendar cal: Calendar
    ) -> [Date] {
        let leadInStart = rule.leadInStart(for: target, now: now, calendar: cal)
        let start = max(now, leadInStart)

        guard start < horizon else { return [] }

        var results: [Date] = []
        var cursor = start

        while cursor < horizon && results.count < maxNotificationsPerPrompt {
            let baseInterval = cadence(for: cursor, target: target)
            let jittered = jitteredInterval(from: baseInterval)

            var next = cursor.addingTimeInterval(jittered)

            // Avoid trying to schedule something in the past or too close to now.
            let minimumFireDate = Date().addingTimeInterval(5)
            if next < minimumFireDate {
                next = minimumFireDate
            }

            if next > horizon {
                break
            }

            results.append(next)
            cursor = next
        }

        #if DEBUG
        if !results.isEmpty {
            print("SPS: \(prompt.text) -> target \(target) -> \(results.count) notifications")
        }
        #endif

        return results
    }

    private func cadence(for date: Date, target: Date) -> TimeInterval {
        // Once the target has passed, stay steady. Do not intensify further.
        if date >= target {
            return overdueInterval
        }

        let maxCadence = TimeInterval(max(RandomPromptRules().intervalMinutes, 5) * 60)
        let hours = target.timeIntervalSince(date) / 3600

        switch hours {
        case let h where h > 24 * 14:
            return 24 * 60 * 60       // > 14 days away
        case let h where h > 24 * 7:
            return 12 * 60 * 60       // 7–14 days
        case let h where h > 24 * 3:
            return 8 * 60 * 60        // 3–7 days
        case let h where h > 24:
            return 4 * 60 * 60        // 1–3 days
        case let h where h > 6:
            return 2 * 60 * 60        // 6–24 hours
        case let h where h > 1:
            return 60 * 60            // 1–6 hours
        default:
            return maxCadence         // final hour uses existing prompt cadence ceiling
        }
    }

    private func jitteredInterval(from base: TimeInterval) -> TimeInterval {
        // Gentle randomisation so it doesn't feel robotic.
        let lower = base * 0.85
        let upper = base * 1.15
        return Double.random(in: lower...upper)
    }

    private func notificationID(for promptID: UUID, fireDate: Date, index: Int) -> String {
        let ts = Int(fireDate.timeIntervalSince1970)
        return "\(idPrefix)\(promptID.uuidString)-\(ts)-\(index)"
    }

    private func finishRefresh() {
        refreshLock.lock()
        isRefreshing = false
        refreshLock.unlock()
    }
}

// MARK: - Supporting type

private struct PendingScheduledNotification {
    let id: String
    let title: String
    let fireDate: Date
    let userInfo: [AnyHashable: Any]
}
