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

    // Yearly prompts (birthdays, anniversaries, etc.) get a much longer runway than other
    // recurrence kinds: reminders start at the full 30-day lead-in (see PromptRule.leadInStart)
    // instead of only the next 24h, and ramp up in frequency approaching the date.
    private let maxNotificationsPerYearlyPrompt: Int = 50

    // Near-target behaviour
    private let immediateWindow: TimeInterval = 5 * 60        // within 5 minutes -> fire immediately
    private let immediateLeadSeconds: TimeInterval = 5        // first alert 5 seconds from now

    // Re-entrancy guard / throttle
    private let refreshLock = NSLock()
    private var isRefreshing: Bool = false
    private var lastRefreshAt: Date? = nil

    // MARK: - Entry point

    /// `onComplete` fires once this scheduler's own cancel/rebuild pass has fully settled
    /// (on every exit path, including reentrancy/throttle skips), so callers that need to
    /// coordinate a shared notification budget — see `RandomPromptScheduler` — can rely on
    /// `sched-*` pending requests being in their final state by the time it's called.
    func refreshSchedule(
        prompts: [PromptItem],
        categoryPromptIDs: [PromptCategory: Set<UUID>] = [:],
        categoryQuietWindows: [PromptCategory: CategoryQuietWindow] = [:],
        globalRules: RandomPromptRules = .init(),
        forceRebuild: Bool = true,
        calendar cal: Calendar = .current,
        onComplete: @escaping () -> Void = {}
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
            onComplete()
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
            onComplete()
            return
        }
        lastRefreshAt = nowForThrottle
        refreshLock.unlock()

        let rulesByID = PromptRulesStore.load() ?? [:]
        let events = PromptStatusStore.load()

        #if DEBUG
        print("SPS: loaded \(rulesByID.count) rules")
        print("SPS: loaded \(events.count) prompt action events")
        #endif

        let scheduledPrompts = prompts.filter { item in
            guard let rule = rulesByID[item.id.uuidString] else {
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
            NotificationsManager.shared.cancelPending(prefix: idPrefix) { [weak self] in
                #if DEBUG
                print("SPS: no scheduled prompts found, cancelled all pending sched-* notifications")
                #endif
                self?.finishRefresh()
                onComplete()
            }
            return
        }

        NotificationsManager.shared.cancelPending(prefix: idPrefix) { [weak self] in
            guard let self else {
                onComplete()
                return
            }

            let now = Date()

            var allRequests: [PendingScheduledNotification] = []

            for prompt in scheduledPrompts {
                guard let rule = rulesByID[prompt.id.uuidString] else {
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
                let horizon = self.horizon(for: rule, target: target, now: now)

                #if DEBUG
                print("SPS: '\(prompt.text)' target=\(target) | leadInStart=\(leadInStart) | horizon=\(horizon)")
                #endif

                let rawDates = self.generateFireDates(
                    for: prompt,
                    rule: rule,
                    target: target,
                    now: now,
                    horizon: horizon,
                    calendar: cal
                )

                let promptCategory = self.category(for: prompt.id, in: categoryPromptIDs)
                let dates = rawDates.filter {
                    !self.isQuietHour(
                        $0,
                        category: promptCategory,
                        categoryQuietWindows: categoryQuietWindows,
                        dayStartHour: globalRules.dayStartHour,
                        dayEndHour: globalRules.dayEndHour,
                        calendar: cal
                    )
                }

                if dates.isEmpty {
                    #if DEBUG
                    print("SPS: generated 0 notifications for '\(prompt.text)' (raw=\(rawDates.count), quiet-hours filtered=\(rawDates.count - dates.count))")
                    #endif
                }

                let subtitle = rule.scheduleDescription

                for (index, fireDate) in dates.enumerated() {
                    let id = self.notificationID(for: prompt.id, fireDate: fireDate, index: index)

                    let userInfo: [AnyHashable: Any] = [
                        PromptNotificationDelegate.kPromptID: prompt.id.uuidString,
                        PromptNotificationDelegate.kPromptText: prompt.text
                    ]

                    let title = rule.isImportant == true ? "⭐️ \(prompt.text)" : prompt.text
                    allRequests.append(
                        PendingScheduledNotification(
                            id: id,
                            title: title,
                            subtitle: subtitle,
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
                    subtitle: req.subtitle,
                    userInfo: req.userInfo,
                    categoryID: PromptNotificationDelegate.categoryID
                )
            }

            #if DEBUG
            print("SPS: scheduled \(finalRequests.count) notifications across \(scheduledPrompts.count) scheduled prompts")
            self.dumpPendingScheduledNotifications()
            #endif

            self.finishRefresh()
            onComplete()
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

        case .weekly, .monthly, .yearly, .fortnightly:
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
        events.contains { $0.promptID == promptID && $0.occurredAt >= cycleStart }
    }

    // MARK: - Quiet hours

    private func category(
        for promptID: UUID,
        in categoryPromptIDs: [PromptCategory: Set<UUID>]
    ) -> PromptCategory? {
        categoryPromptIDs.first { $0.value.contains(promptID) }?.key
    }

    /// Mirrors the global + per-category quiet-hours enforcement `RandomPromptScheduler`
    /// applies to random prompts (see `CategoryQuietWindow.isQuiet` and the `dayStartHour`/
    /// `dayEndHour` clip in `RandomPromptScheduler.planNow`), so a dated/recurring prompt
    /// can't slip a notification past the user's quiet-hours settings just because this
    /// scheduler plans multiple days ahead instead of a single day's window.
    private func isQuietHour(
        _ date: Date,
        category: PromptCategory?,
        categoryQuietWindows: [PromptCategory: CategoryQuietWindow],
        dayStartHour: Int,
        dayEndHour: Int,
        calendar cal: Calendar
    ) -> Bool {
        if let category, let window = categoryQuietWindows[category], window.isQuiet(at: date, cal: cal) {
            return true
        }

        guard dayStartHour != dayEndHour else { return false }
        let hour = cal.component(.hour, from: date)
        let withinGlobalWindow = dayStartHour < dayEndHour
            ? (hour >= dayStartHour && hour < dayEndHour)
            : (hour >= dayStartHour || hour < dayEndHour)
        return !withinGlobalWindow
    }

    // MARK: - Planning horizon

    /// How far ahead we're willing to actually schedule notifications for a prompt.
    /// Most recurrence kinds only plan the next 24h and rely on being re-run regularly
    /// (app open/foreground) to roll the window forward day by day. Yearly and weekly
    /// prompts instead get a horizon reaching all the way to their target (plus a short
    /// overdue buffer), so the full lead-in ramp is queued up front and doesn't depend on
    /// the app being reopened on the exact target day to keep showing up.
    private func horizon(for rule: PromptRule, target: Date, now: Date) -> Date {
        switch rule.recurrenceKind {
        case .yearly, .weekly:
            return target.addingTimeInterval(24 * 3600)
        default:
            return now.addingTimeInterval(horizonHours * 3600)
        }
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
        // Time-specific prompts: fire twice in the 30 min before and twice in the 30 min after.
        // Marking done/skip from any notification cancels the rest (handled by the delegate).
        if rule.timeHour != nil, rule.timeMinute != nil {
            let minimumFireDate = now.addingTimeInterval(immediateLeadSeconds)
            let candidates: [Date] = [
                target.addingTimeInterval(-30 * 60),
                target.addingTimeInterval(-15 * 60),
                target.addingTimeInterval(15 * 60),
                target.addingTimeInterval(30 * 60)
            ]
            let results = candidates.filter { $0 >= minimumFireDate && $0 <= horizon }

            if !results.isEmpty {
                #if DEBUG
                print("SPS: '\(prompt.text)' time-window fire dates: \(results)")
                #endif
                return results
            }

            // A bare time-only rule with oneOff == false (e.g. "repeat every day at 9am")
            // has no `date`, so its base day is always `now`-relative (see
            // effectiveOneOffBaseDay) — today's occurrence already rolls over to tomorrow's
            // on the next refresh with no help needed. Catching it up here would instead
            // spam notifications starting the moment the rule is created/refreshed after
            // today's time has already passed, even though nothing was ever missed.
            // Only a genuinely dated one-off, or an explicit "Once" bare-time reminder
            // (which self-purges ~24h later regardless), warrants the catch-up below.
            let isSelfRollingDailyReminder = (rule.date == nil && rule.oneOff == false)

            // All four candidates already passed — this only means the prompt is overdue
            // (not that it's too far in the future to schedule yet) when `target` itself
            // is in the past. Without a catch-up here, a target missed by more than ~30
            // minutes (e.g. app wasn't opened) would get zero notifications for the whole
            // cycle, mirroring the rolling overdue cadence used below for date/weekday-only
            // prompts instead of going silent.
            guard !isSelfRollingDailyReminder, now > target else {
                #if DEBUG
                print("SPS: '\(prompt.text)' time-window produced no dates; skipping catch-up (selfRolling=\(isSelfRollingDailyReminder))")
                #endif
                return []
            }

            let cap = rule.recurrenceKind == .yearly ? maxNotificationsPerYearlyPrompt : maxNotificationsPerPrompt
            var overdueResults: [Date] = []
            var cursor = minimumFireDate
            while cursor < horizon && overdueResults.count < cap {
                overdueResults.append(cursor)
                cursor = cursor.addingTimeInterval(jitteredInterval(from: overdueInterval))
            }

            #if DEBUG
            print("SPS: '\(prompt.text)' time-window overdue catch-up fire dates: \(overdueResults)")
            #endif
            return overdueResults
        }

        // Date/weekday-only prompts: use the rolling lead-in cadence.
        let leadInStart = rule.leadInStart(for: target, now: now, calendar: cal)

        // Not yet within the lead-in window — nothing to schedule. Most recurrence kinds
        // relied on their short 24h horizon to make this a no-op automatically, but yearly's
        // extended horizon reaches leadInStart regardless, so it needs this check explicitly.
        guard now >= leadInStart else {
            #if DEBUG
            print("SPS: '\(prompt.text)' not yet within lead-in window (starts \(leadInStart))")
            #endif
            return []
        }

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

        let cap = rule.recurrenceKind == .yearly ? maxNotificationsPerYearlyPrompt : maxNotificationsPerPrompt

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

        while cursor < horizon && results.count < cap {
            let baseInterval = cadence(for: cursor, target: target, recurrenceKind: rule.recurrenceKind)
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

    private func cadence(for date: Date, target: Date, recurrenceKind: PromptRecurrenceKind) -> TimeInterval {
        if date >= target {
            return overdueInterval
        }

        let hours = target.timeIntervalSince(date) / 3600

        if recurrenceKind == .yearly {
            return yearlyCadence(hoursRemaining: hours)
        }

        let maxCadence = TimeInterval(max(RandomPromptRules().intervalMinutes, 5) * 60)

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

    /// Once a day from the 30-day lead-in down to 10 days out, then ramping up as the date
    /// approaches: twice a day (10-4 days out), four times a day (4-1 days out), and six
    /// times a day on the final day itself.
    private func yearlyCadence(hoursRemaining hours: Double) -> TimeInterval {
        switch hours {
        case let h where h > 24 * 10:
            return 24 * 60 * 60
        case let h where h > 24 * 4:
            return 12 * 60 * 60
        case let h where h > 24:
            return 6 * 60 * 60
        default:
            return 4 * 60 * 60
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

        case .monthly, .yearly, .fortnightly:
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
    let subtitle: String
    let fireDate: Date
    let userInfo: [AnyHashable: Any]
}
