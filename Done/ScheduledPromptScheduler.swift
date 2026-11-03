//
//  ScheduledPromptScheduler.swift
//  Done
//
//  Path: Done/Notifications/ScheduledPromptScheduler.swift
//

import Foundation
import UserNotifications

/// One notification the scheduled-prompt planner wants queued with iOS.
struct PlannedScheduledNotification {
    /// What a notification is *for*. The order is also the priority order when the
    /// shared notification budget runs short (see `ScheduledPromptScheduler.prioritised`).
    enum Kind: Int {
        case primary    // the alert at the time/day the user actually set
        case approach   // -30 / -15 min before a set time
        case followUp   // +15 / +30 min after a set time, or later the same day for a day-only prompt
        case leadIn     // the days before a dated prompt (birthday, bin night, bill)
        case overdue    // a one-off whose time has passed without Done/Skip
    }

    let promptID: UUID
    let promptText: String
    let kind: Kind
    /// The occurrence (target date) this notification belongs to.
    let occurrence: Date
    /// When it fires. For a repeating request, its next fire.
    let fireDate: Date
    /// Non-nil for a repeating trigger (daily / weekly primary), which keeps firing on
    /// every match without the app needing to be opened again.
    let repeating: DateComponents?
}

/// Everything the planner needs besides the prompts themselves.
struct ScheduledPlanContext {
    var now: Date
    var calendar: Calendar = .current
    var dayStartHour: Int
    var dayEndHour: Int
    var categoryQuietWindows: [PromptCategory: CategoryQuietWindow] = [:]
    var categoryOf: [UUID: PromptCategory] = [:]

    init(
        now: Date,
        calendar: Calendar = .current,
        dayStartHour: Int,
        dayEndHour: Int,
        categoryQuietWindows: [PromptCategory: CategoryQuietWindow] = [:],
        categoryPromptIDs: [PromptCategory: Set<UUID>] = [:]
    ) {
        self.now = now
        self.calendar = calendar
        self.dayStartHour = dayStartHour
        self.dayEndHour = dayEndHour
        self.categoryQuietWindows = categoryQuietWindows
        for (category, ids) in categoryPromptIDs {
            for id in ids { categoryOf[id] = category }
        }
    }

    /// Current settings from the Settings app (Settings.bundle → UserDefaults).
    static func fromUserDefaults(now: Date = Date(), categoryPromptIDs: [PromptCategory: Set<UUID>]) -> ScheduledPlanContext {
        let rules = RandomPromptRules.loadFromUserDefaults()
        return ScheduledPlanContext(
            now: now,
            dayStartHour: rules.dayStartHour,
            dayEndHour: rules.dayEndHour,
            categoryQuietWindows: CategoryQuietWindow.loadAllFromUserDefaults(),
            categoryPromptIDs: categoryPromptIDs
        )
    }
}

/// Plans notifications for every prompt with a day/date/time rule, across all categories.
///
/// How it works, per prompt:
/// 1. Work out its upcoming *occurrences* (next Friday, the 15th, 8am tomorrow…), skipping
///    any already settled by a Done/Skip (`PromptRule.cycleStart`).
/// 2. Give each occurrence a **primary** alert — at the set time, or for a day-only prompt
///    at the first non-quiet hour that day. A time the user chose explicitly is never
///    silenced by quiet hours: quiet hours exist to hush the random feed and the extra
///    nudges, and used to swallow a 9pm bin night or a 5:30pm Work reminder entirely.
///    Daily and weekly primaries are repeating iOS triggers, so they keep arriving even
///    if the app isn't opened for weeks.
/// 3. Add the optional extras (run-up nudges, follow-ups, lead-in days, overdue nags),
///    which do respect quiet hours.
/// 4. When everything won't fit in the shared budget, primaries win, then the run-up to
///    anything in the next 24h, then extras — so one busy category can't push another
///    category's on-time alert out.
final class ScheduledPromptScheduler {
    static let shared = ScheduledPromptScheduler()
    private init() {}

    // iOS keeps at most ~64 pending notifications per app, shared with RandomPromptScheduler
    // (which gets whatever this leaves under its combined cap of 60). Capped below 60 so
    // scheduled prompts can't take the whole budget and starve the random feed.
    static let scheduledNotificationCap: Int = 40

    /// The run-up to a set time (-30, -15 and the time itself).
    static let approachWindow: TimeInterval = 30 * 60

    /// Notifications are never queued sooner than this from "now".
    private static let minimumLead: TimeInterval = 5
    /// One-off occurrences further out than this aren't queued yet — the app will have been
    /// opened (and re-planned) long before then, and they'd only tie up slots.
    private static let occurrenceHorizon: TimeInterval = 35 * 24 * 3600
    /// Overdue one-offs: first nag an hour after planning (not instantly — planning runs
    /// every time something is edited in the app), then every 3 hours.
    private static let overdueFirstDelay: TimeInterval = 60 * 60
    private static let overdueInterval: TimeInterval = 3 * 60 * 60
    private static let maxOverdueNags = 4

    private let idPrefix = "sched-"

    // Re-entrancy guard. RandomPromptScheduler serialises full refreshes, so this only
    // protects against a stray direct caller.
    private let refreshLock = NSLock()
    private var isRefreshing = false

    // MARK: - Entry point (full rebuild)

    /// Rebuilds every `sched-*` notification. `onComplete` fires once every request has
    /// actually been accepted by iOS, so `RandomPromptScheduler` can size its own budget
    /// against the real pending count.
    func refreshSchedule(
        prompts: [PromptItem],
        categoryPromptIDs: [PromptCategory: Set<UUID>] = [:],
        categoryQuietWindows: [PromptCategory: CategoryQuietWindow] = [:],
        globalRules: RandomPromptRules = .init(),
        calendar cal: Calendar = .current,
        onComplete: @escaping () -> Void = {}
    ) {
        refreshLock.lock()
        if isRefreshing {
            refreshLock.unlock()
            #if DEBUG
            print("SPS: skipped refresh because a refresh is already in progress")
            #endif
            onComplete()
            return
        }
        isRefreshing = true
        refreshLock.unlock()

        // If prompt_rules.json can't be read, leave what's already queued alone rather
        // than wiping every scheduled reminder because the rules "look" empty.
        guard let rulesByID = PromptRulesStore.load() else {
            #if DEBUG
            print("SPS: prompt_rules.json failed to load — keeping existing sched-* requests")
            #endif
            finishRefresh()
            onComplete()
            return
        }

        NotificationsManager.shared.cancelPending(prefix: idPrefix) { [weak self] in
            guard let self else { onComplete(); return }

            // Re-read after the cancel pass so a Done/Skip recorded meanwhile is respected.
            let events = PromptStatusStore.load()
            let context = ScheduledPlanContext(
                now: Date(),
                calendar: cal,
                dayStartHour: globalRules.dayStartHour,
                dayEndHour: globalRules.dayEndHour,
                categoryQuietWindows: categoryQuietWindows,
                categoryPromptIDs: categoryPromptIDs
            )
            let planned = Self.plan(prompts: prompts, rules: rulesByID, events: events, context: context)
            let final = Self.prioritised(planned, now: context.now, cap: Self.scheduledNotificationCap)

            #if DEBUG
            print("SPS: planned \(planned.count) sched requests, keeping \(final.count)")
            for p in final {
                print("SPS:   \(p.kind) '\(p.promptText)' at \(p.fireDate)\(p.repeating != nil ? " (repeating)" : "")")
            }
            #endif

            Task {
                for p in final {
                    await self.enqueue(p, rule: rulesByID[p.promptID.uuidString])
                }
                self.finishRefresh()
                onComplete()
            }
        }
    }

    /// After Done/Skip on a banner, every pending notification for that prompt is cleared
    /// (so nothing more fires for the occurrence just handled). That also removes the
    /// prompt's repeating daily/weekly trigger, and the app may not be opened again for
    /// days — so put the *next* occurrence's primary straight back.
    func requeueNextOccurrence(promptID: UUID) async {
        guard let state = PromptsStore.loadSafe(),
              let rules = PromptRulesStore.load(),
              let rule = rules[promptID.uuidString],
              rule.hasSchedulingRule,
              let prompt = state.allItems.first(where: { $0.id == promptID })
        else { return }

        let context = ScheduledPlanContext.fromUserDefaults(categoryPromptIDs: state.categoryPromptIDs)
        let primaries = Self.planPrompt(prompt, rule: rule, events: PromptStatusStore.load(), context: context)
            .filter { $0.kind == .primary }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(2)

        for p in primaries {
            await enqueue(p, rule: rule)
        }
        #if DEBUG
        print("SPS: re-queued \(primaries.count) primary alert(s) for '\(prompt.text)' after Done/Skip")
        #endif
    }

    private func enqueue(_ p: PlannedScheduledNotification, rule: PromptRule?) async {
        var userInfo: [AnyHashable: Any] = [
            PromptNotificationDelegate.kPromptID: p.promptID.uuidString,
            PromptNotificationDelegate.kPromptText: p.promptText
        ]
        // A repeating trigger fires on many dates, so its delivery date (not a baked-in
        // one) is what a Done/Skip on it should be recorded against.
        if p.repeating == nil {
            userInfo[PromptNotificationDelegate.kPromptDate] = p.fireDate.timeIntervalSince1970
        }

        let title = rule?.isImportant == true ? "⭐️ \(p.promptText)" : p.promptText
        let id = p.repeating != nil
            ? "\(idPrefix)\(p.promptID.uuidString)-repeat"
            : "\(idPrefix)\(p.promptID.uuidString)-\(p.kind.rawValue)-\(Int(p.fireDate.timeIntervalSince1970))"

        await NotificationsManager.shared.add(
            id: id,
            title: title,
            subtitle: rule?.scheduleDescription,
            userInfo: userInfo,
            fireDate: p.fireDate,
            repeating: p.repeating
        )
    }

    private func finishRefresh() {
        refreshLock.lock()
        isRefreshing = false
        refreshLock.unlock()
    }

    // MARK: - Planning (pure — no iOS calls, unit-tested)

    static func plan(
        prompts: [PromptItem],
        rules: [String: PromptRule],
        events: [PromptActionEvent],
        context: ScheduledPlanContext
    ) -> [PlannedScheduledNotification] {
        prompts.flatMap { prompt -> [PlannedScheduledNotification] in
            guard let rule = rules[prompt.id.uuidString], rule.hasSchedulingRule else { return [] }
            return planPrompt(prompt, rule: rule, events: events, context: context)
        }
    }

    /// Orders by importance and trims to `cap`:
    /// 1. every primary alert, whatever the category or how far off (each prompt has at
    ///    most three, so these can't swamp the budget — and they're the promise that a
    ///    reminder arrives when it was set for, even if the app isn't opened in between)
    /// 2. run-up nudges in the next 24h
    /// 3. other extras in the next 24h, then 4. everything else — soonest first within each.
    static func prioritised(
        _ planned: [PlannedScheduledNotification],
        now: Date,
        cap: Int
    ) -> [PlannedScheduledNotification] {
        func tier(_ p: PlannedScheduledNotification) -> Int {
            let soon = p.fireDate.timeIntervalSince(now) <= 24 * 3600
            switch p.kind {
            case .primary: return 0
            case .approach: return soon ? 1 : 3
            case .followUp, .leadIn, .overdue: return soon ? 2 : 3
            }
        }
        return Array(
            planned
                .sorted { a, b in
                    let ta = tier(a), tb = tier(b)
                    return ta != tb ? ta < tb : a.fireDate < b.fireDate
                }
                .prefix(cap)
        )
    }

    static func planPrompt(
        _ prompt: PromptItem,
        rule: PromptRule,
        events: [PromptActionEvent],
        context ctx: ScheduledPlanContext
    ) -> [PlannedScheduledNotification] {
        let cal = ctx.calendar
        let now = ctx.now
        let earliest = now.addingTimeInterval(minimumLead)
        let kind = rule.recurrenceKind
        let category = ctx.categoryOf[prompt.id]
        let timed = rule.timeHour != nil && rule.timeMinute != nil

        func settled(_ occurrence: Date) -> Bool {
            let start = rule.cycleStart(for: occurrence, now: now, calendar: cal)
            return events.contains { $0.promptID == prompt.id && $0.occurredAt >= start }
        }
        func allowed(_ date: Date) -> Bool {
            !isQuiet(date, category: category, context: ctx)
        }

        var out: [PlannedScheduledNotification] = []
        func add(_ k: PlannedScheduledNotification.Kind, _ occurrence: Date, _ fire: Date, repeating: DateComponents? = nil) {
            out.append(PlannedScheduledNotification(
                promptID: prompt.id, promptText: prompt.text, kind: k,
                occurrence: occurrence, fireDate: fire, repeating: repeating
            ))
        }

        // --- A one-off whose time has passed without Done/Skip -------------------------
        if kind == .oneOff, let missed = rule.previousTarget(before: now, calendar: cal), !settled(missed) {
            if timed {
                for minutes in [15.0, 30.0] {
                    let fire = missed.addingTimeInterval(minutes * 60)
                    if fire >= earliest, allowed(fire) { add(.followUp, missed, fire) }
                }
            }
            let graceOver = timed ? now > missed.addingTimeInterval(approachWindow) : true
            if graceOver {
                var cursor = now.addingTimeInterval(overdueFirstDelay)
                var count = 0
                let end = now.addingTimeInterval(24 * 3600)
                while cursor < end && count < maxOverdueNags {
                    if allowed(cursor) { add(.overdue, missed, cursor); count += 1 }
                    cursor = cursor.addingTimeInterval(overdueInterval)
                }
            }
            return out
        }

        // --- A timed recurring occurrence that passed under 30 min ago -----------------
        // Keeps its +15/+30 follow-ups instead of losing them to the roll-forward.
        if timed, kind != .oneOff,
           let previous = rule.previousTarget(before: now, calendar: cal),
           now.timeIntervalSince(previous) <= approachWindow,
           !settled(previous) {
            for minutes in [15.0, 30.0] {
                let fire = previous.addingTimeInterval(minutes * 60)
                if fire >= earliest, allowed(fire) { add(.followUp, previous, fire) }
            }
        }

        // --- Upcoming occurrences -------------------------------------------------------
        let maxOccurrences: Int
        switch kind {
        case .daily: maxOccurrences = 3
        case .weekly, .fortnightly, .monthly: maxOccurrences = 2
        default: maxOccurrences = 1
        }

        let trueNext = rule.nextTarget(after: now, calendar: cal)
        var occurrences: [Date] = []
        var cursor = now
        for _ in 0..<(maxOccurrences + 1) {
            guard occurrences.count < maxOccurrences,
                  let next = rule.nextTarget(after: cursor, calendar: cal),
                  next.timeIntervalSince(now) <= occurrenceHorizon
            else { break }
            if !settled(next) { occurrences.append(next) }
            if kind == .oneOff { break }
            cursor = next.addingTimeInterval(1)
        }

        // Daily / weekly: one repeating trigger covers this and every later occurrence —
        // unless the next one is already Done/Skipped (e.g. Friday's ticked off on
        // Wednesday), since a repeating trigger can't skip a single date. Then the later
        // occurrences get one-off primaries until the next re-plan.
        var repeatingComps: DateComponents?
        if (kind == .daily || kind == .weekly), let first = occurrences.first, first == trueNext {
            let primaryTime = primaryFireDate(for: first, rule: rule, category: category, context: ctx)
            var comps = DateComponents()
            if kind == .weekly { comps.weekday = rule.weekday }
            comps.hour = cal.component(.hour, from: primaryTime)
            comps.minute = cal.component(.minute, from: primaryTime)
            repeatingComps = comps
            let nextFire = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? primaryTime
            add(.primary, first, nextFire, repeating: comps)
        }

        for (index, occurrence) in occurrences.enumerated() {
            let primary = primaryFireDate(for: occurrence, rule: rule, category: category, context: ctx)

            if repeatingComps == nil, primary >= earliest {
                add(.primary, occurrence, primary)
            }

            if timed {
                for minutes in [-30.0, -15.0] {
                    let fire = occurrence.addingTimeInterval(minutes * 60)
                    if fire >= earliest, allowed(fire) { add(.approach, occurrence, fire) }
                }
                for minutes in [15.0, 30.0] {
                    let fire = occurrence.addingTimeInterval(minutes * 60)
                    if fire >= earliest, allowed(fire) { add(.followUp, occurrence, fire) }
                }
            } else {
                // Day-only: a few more reminders through the rest of that day.
                for hours in [4.0, 8.0, 12.0] {
                    let fire = primary.addingTimeInterval(hours * 3600)
                    if fire >= earliest, cal.isDate(fire, inSameDayAs: occurrence), allowed(fire) {
                        add(.followUp, occurrence, fire)
                    }
                }
            }

            // Lead-in days before the next dated occurrence only.
            if index == 0, rule.hasDatedLeadIn {
                for daysBefore in leadInDays(for: kind) {
                    guard let day = cal.date(byAdding: .day, value: -daysBefore, to: cal.startOfDay(for: occurrence)) else { continue }
                    let fire = leadInFireDate(on: day, rule: rule, category: category, context: ctx)
                    if fire >= earliest { add(.leadIn, occurrence, fire) }
                }
            }
        }

        return out
    }

    /// Days before the date to remind on. Birthdays/one-off dates get a long runway that
    /// tightens to daily in the final week; monthly/fortnightly get the final five days.
    static func leadInDays(for kind: PromptRecurrenceKind) -> [Int] {
        switch kind {
        case .yearly, .oneOff: return [30, 21, 14, 7, 6, 5, 4, 3, 2, 1]
        case .monthly, .fortnightly: return [5, 4, 3, 2, 1]
        default: return []
        }
    }

    // MARK: - Times of day

    /// The set time if there is one (quiet hours never move or drop it); otherwise the
    /// first hour that day the prompt's category isn't quiet, within the global window.
    static func primaryFireDate(
        for occurrence: Date,
        rule: PromptRule,
        category: PromptCategory?,
        context ctx: ScheduledPlanContext
    ) -> Date {
        if rule.timeHour != nil, rule.timeMinute != nil { return occurrence }
        return firstAllowedTime(on: occurrence, category: category, context: ctx)
    }

    /// Lead-in reminders go out at the prompt's own time when that's allowed, otherwise
    /// at the first allowed hour of the day (so a 9pm bin night still gets a run-up).
    private static func leadInFireDate(
        on day: Date,
        rule: PromptRule,
        category: PromptCategory?,
        context ctx: ScheduledPlanContext
    ) -> Date {
        if let h = rule.timeHour, let m = rule.timeMinute,
           let atTime = ctx.calendar.date(bySettingHour: h, minute: m, second: 0, of: day),
           !isQuiet(atTime, category: category, context: ctx) {
            return atTime
        }
        return firstAllowedTime(on: day, category: category, context: ctx)
    }

    private static func firstAllowedTime(on day: Date, category: PromptCategory?, context ctx: ScheduledPlanContext) -> Date {
        let cal = ctx.calendar
        let startHour = ctx.dayStartHour == ctx.dayEndHour ? 9 : ctx.dayStartHour
        for offset in 0..<24 {
            let hour = startHour + offset
            guard hour < 24 else { break }
            if let candidate = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day),
               !isQuiet(candidate, category: category, context: ctx) {
                return candidate
            }
        }
        // Every hour that day is quiet (e.g. a Work prompt the user put on a Saturday):
        // they still chose that day, so remind at the start of it.
        return cal.date(bySettingHour: startHour, minute: 0, second: 0, of: day) ?? day
    }

    /// Global earliest/latest window plus the prompt category's own quiet window — the
    /// same rules `RandomPromptScheduler` applies to the random feed.
    static func isQuiet(_ date: Date, category: PromptCategory?, context ctx: ScheduledPlanContext) -> Bool {
        let cal = ctx.calendar
        if let category, let window = ctx.categoryQuietWindows[category], window.isQuiet(at: date, cal: cal) {
            return true
        }
        guard ctx.dayStartHour != ctx.dayEndHour else { return false }
        let hour = cal.component(.hour, from: date)
        let inside = ctx.dayStartHour < ctx.dayEndHour
            ? (hour >= ctx.dayStartHour && hour < ctx.dayEndHour)
            : (hour >= ctx.dayStartHour || hour < ctx.dayEndHour)
        return !inside
    }
}
