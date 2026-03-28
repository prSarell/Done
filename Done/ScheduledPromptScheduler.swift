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

    // Near-target behaviour
    private let immediateWindow: TimeInterval = 5 * 60        // within 5 minutes -> fire immediately
    private let immediateLeadSeconds: TimeInterval = 5        // first alert 5 seconds from now

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
        #if DEBUG
        print("SPS: refreshSchedule called with \(prompts.count) prompts | forceRebuild=\(forceRebuild)")
        #endif

        refreshLock.lock()
        if isRefreshing {
            #if DEBUG
            print("SPS: skipped refresh because a refresh is already in progress")
            #endif
            refreshLock.unlock()
            return
        }
        isRefreshing = true

        let nowForThrottle = Date()
        if let last = lastRefreshAt, nowForThrottle.timeIntervalSince(last) < 0.5 {
            #if DEBUG
            print("SPS: throttled refresh (\(nowForThrottle.timeIntervalSince(last))s since last)")
            #endif
            isRefreshing = false
            refreshLock.unlock()
            return
        }
        lastRefreshAt = nowForThrottle
        refreshLock.unlock()

        let rulesByText = PromptRulesStore.load()
        let events = PromptStatusStore.load()

        #if DEBUG
        print("SPS: loaded \(rulesByText.count) rules")
        print("SPS: loaded \(events.count) prompt action events")
        #endif

        let scheduledPrompts = prompts.filter { item in
            guard let rule = rulesByText[item.text] else {
                #if DEBUG
                print("SPS: no rule found for prompt '\(item.text)'")
                #endif
                return false
            }

            let valid = rule.hasSchedulingRule
            #if DEBUG
            if !valid {
                print("SPS: rule exists but has no scheduling rule for '\(item.text)'")
            }
            #endif
            return valid
        }

        #if DEBUG
        print("SPS: found \(scheduledPrompts.count) prompts with usable schedule rules")
        #endif

        guard !scheduledPrompts.isEmpty else {
            NotificationsManager.shared.cancelAll(prefix: idPrefix) { [weak self] in
                #if DEBUG
                print("SPS: no scheduled prompts found, cancelled all sched-* notifications")
                #endif
                self?.finishRefresh()
            }
            return
        }

        NotificationsManager.shared.cancelAll(prefix: idPrefix) { [weak self] in
            guard let self else { return }

            let now = Date()
            let horizon = now.addingTimeInterval(self.horizonHours * 3600)

            #if DEBUG
            print("SPS: planning window \(now) -> \(horizon)")
            #endif

            var allRequests: [PendingScheduledNotification] = []

            for prompt in scheduledPrompts {
                guard let rule = rulesByText[prompt.text] else {
                    #if DEBUG
                    print("SPS: skipped '\(prompt.text)' because its rule disappeared during refresh")
                    #endif
                    continue
                }

                #if DEBUG
                print("SPS: evaluating prompt '\(prompt.text)' | recurrence=\(rule.recurrenceKind.rawValue)")
                #endif

                guard let target = self.currentOrNextTarget(
                    for: prompt,
                    rule: rule,
                    now: now,
                    events: events,
                    calendar: cal
                ) else {
                    #if DEBUG
                    print("SPS: no current/next target for '\(prompt.text)'")
                    #endif
                    continue
                }

                let leadInStart = rule.leadInStart(for: target, now: now, calendar: cal)

                #if DEBUG
                print("SPS: '\(prompt.text)' target=\(target) | leadInStart=\(leadInStart)")
                if target > horizon {
                    print("SPS: '\(prompt.text)' target is beyond 24h horizon — only lead-in notifications within horizon can be scheduled")
                }
                #endif

                let dates = self.generateFireDates(
                    for: prompt,
                    rule: rule,
                    target: target,
                    now: now,
                    horizon: horizon,
                    calendar: cal
                )

                if dates.isEmpty {
                    #if DEBUG
                    print("SPS: generated 0 notifications for '\(prompt.text)'")
                    #endif
                }

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

            let finalRequests = Array(
                allRequests
                    .sorted { $0.fireDate < $1.fireDate }
                    .prefix(self.globalNotificationCap)
            )

            #if DEBUG
            print("SPS: generated \(allRequests.count) raw sched requests, keeping \(finalRequests.count)")
            #endif

            if finalRequests.isEmpty {
                #if DEBUG
                print("SPS: no sched-* notifications to schedule in current horizon")
                #endif
            }

            for req in finalRequests {
                #if DEBUG
                print("SPS: scheduling '\(req.title)' at \(req.fireDate) | id=\(req.id)")
                #endif

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
            self.dumpPendingScheduledNotifications()
            #endif

            self.finishRefresh()
        }
    }

    // MARK: - Target selection

    private func currentOrNextTarget(
        for prompt: PromptItem,
        rule: PromptRule,
        now: Date,
        events: [PromptActionEvent],
        calendar cal: Calendar
    ) -> Date? {
        switch rule.recurrenceKind {
        case .oneOff:
            return currentOrNextTargetForOneOff(
                prompt: prompt,
                rule: rule,
                now: now,
                events: events,
                calendar: cal
            )

        case .weekly, .monthly, .yearly:
            return currentOrNextTargetForRecurring(
                prompt: prompt,
                rule: rule,
                now: now,
                events: events,
                calendar: cal
            )

        case .none:
            #if DEBUG
            print("SPS: '\(prompt.text)' has recurrence .none in currentOrNextTarget")
            #endif
            return nil
        }
    }

    private func currentOrNextTargetForOneOff(
        prompt: PromptItem,
        rule: PromptRule,
        now: Date,
        events: [PromptActionEvent],
        calendar cal: Calendar
    ) -> Date? {
        if let previousTarget = rule.previousTarget(before: now, calendar: cal) {
            let cycleStart = rule.leadInStart(for: previousTarget, now: now, calendar: cal)
            let completed = cycleCompleted(
                promptID: prompt.id,
                cycleStart: cycleStart,
                events: events
            )

            #if DEBUG
            print("SPS: one-off previous target for '\(prompt.text)' = \(previousTarget) | completed=\(completed)")
            #endif

            if !completed {
                return previousTarget
            }
        }

        guard let nextTarget = rule.nextTarget(after: now, calendar: cal) else {
            #if DEBUG
            print("SPS: one-off nextTarget returned nil for '\(prompt.text)'")
            #endif
            return nil
        }

        let cycleStart = rule.leadInStart(for: nextTarget, now: now, calendar: cal)
        let completed = cycleCompleted(
            promptID: prompt.id,
            cycleStart: cycleStart,
            events: events
        )

        #if DEBUG
        print("SPS: one-off next target for '\(prompt.text)' = \(nextTarget) | cycleStart=\(cycleStart) | completed=\(completed)")
        #endif

        if completed {
            #if DEBUG
            print("SPS: one-off '\(prompt.text)' already completed for current cycle, no target returned")
            #endif
            return nil
        }

        return nextTarget
    }

    private func currentOrNextTargetForRecurring(
        prompt: PromptItem,
        rule: PromptRule,
        now: Date,
        events: [PromptActionEvent],
        calendar cal: Calendar
    ) -> Date? {
        if let nextTarget = rule.nextTarget(after: now, calendar: cal) {
            let cycleStart = rule.leadInStart(for: nextTarget, now: now, calendar: cal)
            let completed = cycleCompleted(
                promptID: prompt.id,
                cycleStart: cycleStart,
                events: events
            )

            #if DEBUG
            print("SPS: recurring next target for '\(prompt.text)' = \(nextTarget) | cycleStart=\(cycleStart) | completed=\(completed)")
            #endif

            if completed {
                let later = nextTarget.addingTimeInterval(1)
                let future = rule.nextTarget(after: later, calendar: cal)

                #if DEBUG
                print("SPS: recurring '\(prompt.text)' current cycle already done, advanced to future target \(String(describing: future))")
                #endif

                return future
            }

            return nextTarget
        }

        if let previousTarget = rule.previousTarget(before: now, calendar: cal) {
            let cycleStart = rule.leadInStart(for: previousTarget, now: now, calendar: cal)
            let completed = cycleCompleted(
                promptID: prompt.id,
                cycleStart: cycleStart,
                events: events
            )

            #if DEBUG
            print("SPS: recurring previous target fallback for '\(prompt.text)' = \(previousTarget) | completed=\(completed)")
            #endif

            if now <= previousTarget {
                return previousTarget
            }

            if now <= endOfRecurringWindow(for: previousTarget, rule: rule, calendar: cal), !completed {
                #if DEBUG
                print("SPS: recurring '\(prompt.text)' is still within active window for previous target")
                #endif
                return previousTarget
            }
        }

        #if DEBUG
        print("SPS: recurring '\(prompt.text)' has no valid current or future target")
        #endif
        return nil
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

        #if DEBUG
        print("SPS: '\(prompt.text)' generation start=\(start) | target=\(target) | horizon=\(horizon)")
        #endif

        guard start < horizon else {
            #if DEBUG
            print("SPS: '\(prompt.text)' start is outside horizon, skipping")
            #endif
            return []
        }

        var results: [Date] = []
        let minimumFireDate = now.addingTimeInterval(immediateLeadSeconds)

        let secondsToTarget = target.timeIntervalSince(now)
        let shouldFireImmediately = (secondsToTarget <= immediateWindow)

        if shouldFireImmediately {
            let first = min(max(minimumFireDate, start), horizon)
            results.append(first)

            #if DEBUG
            print("SPS: '\(prompt.text)' target is near/immediate (\(secondsToTarget)s), forcing first fire at \(first)")
            #endif
        }

        var cursor = results.last ?? start

        while cursor < horizon && results.count < maxNotificationsPerPrompt {
            let baseInterval = cadence(for: cursor, target: target)
            let jittered = jitteredInterval(from: baseInterval)

            var next = cursor.addingTimeInterval(jittered)

            if next < minimumFireDate {
                next = minimumFireDate
            }

            if next > horizon {
                break
            }

            if let last = results.last, next <= last {
                next = last.addingTimeInterval(60)
            }

            if next > horizon {
                break
            }

            results.append(next)
            cursor = next
        }

        #if DEBUG
        if results.isEmpty {
            print("SPS: '\(prompt.text)' -> generated no fire dates")
        } else {
            for d in results {
                print("SPS: '\(prompt.text)' -> fire date \(d)")
            }
        }
        #endif

        return results
    }

    private func cadence(for date: Date, target: Date) -> TimeInterval {
        if date >= target {
            return overdueInterval
        }

        let maxCadence = TimeInterval(max(RandomPromptRules().intervalMinutes, 5) * 60)
        let hours = target.timeIntervalSince(date) / 3600

        switch hours {
        case let h where h > 24 * 14:
            return 24 * 60 * 60
        case let h where h > 24 * 7:
            return 12 * 60 * 60
        case let h where h > 24 * 3:
            return 8 * 60 * 60
        case let h where h > 24:
            return 4 * 60 * 60
        case let h where h > 6:
            return 2 * 60 * 60
        case let h where h > 1:
            return 60 * 60
        default:
            return maxCadence
        }
    }

    private func jitteredInterval(from base: TimeInterval) -> TimeInterval {
        let lower = base * 0.85
        let upper = base * 1.15
        return Double.random(in: lower...upper)
    }

    private func endOfRecurringWindow(
        for target: Date,
        rule: PromptRule,
        calendar cal: Calendar
    ) -> Date {
        switch rule.recurrenceKind {
        case .weekly:
            if rule.timeHour != nil, rule.timeMinute != nil {
                return target.addingTimeInterval(24 * 60 * 60)
            } else {
                return cal.startOfDay(for: target).addingTimeInterval(24 * 60 * 60)
            }

        case .monthly, .yearly:
            if rule.timeHour != nil, rule.timeMinute != nil {
                return target.addingTimeInterval(24 * 60 * 60)
            } else {
                return cal.startOfDay(for: target).addingTimeInterval(24 * 60 * 60)
            }

        case .oneOff, .none:
            return target
        }
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

    // MARK: - Debug helper

    #if DEBUG
    func dumpPendingScheduledNotifications() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let sched = requests
                .filter { $0.identifier.hasPrefix(self.idPrefix) }
                .sorted { $0.identifier < $1.identifier }

            print("SPS: pending sched-* request count = \(sched.count)")

            for req in sched {
                if let trigger = req.trigger as? UNCalendarNotificationTrigger {
                    print("SPS: pending id=\(req.identifier) | dateComponents=\(trigger.dateComponents) | title=\(req.content.title)")
                } else {
                    print("SPS: pending id=\(req.identifier) | title=\(req.content.title)")
                }
            }
        }
    }
    #endif
}

// MARK: - Supporting type

private struct PendingScheduledNotification {
    let id: String
    let title: String
    let fireDate: Date
    let userInfo: [AnyHashable: Any]
}
