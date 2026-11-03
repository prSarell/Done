//
//  DoneTests.swift
//  DoneTests
//
//  Created by Patrick Sarell on 9/8/2025.
//

import Foundation
import Testing
@testable import Done

struct DoneTests {

    // MARK: - CategoryRotation fairness
    //
    // These guard the fix for prompts drifting unbalanced across categories: the
    // scheduler used to draw randomly from every category's prompts pooled together,
    // so a category with fewer prompts (or fewer "important"-starred prompts) than
    // the rest could go quiet for long stretches by chance alone. CategoryRotation
    // round-robins instead, so every eligible category gets one slot per cycle.

    @Test func rotationServesEveryCategoryExactlyOncePerCycle() {
        var rng = SeededRandom(seed: 42)
        let categories: [RotationKey] = [.category(.daily), .category(.work), .category(.mentalHealth)]
        var rotation = CategoryRotation(categories: categories, rng: &rng)

        let eligible = Set(categories)
        var served: [RotationKey] = []
        for _ in 0..<categories.count {
            served.append(rotation.next(eligible: eligible, rng: &rng)!)
        }

        #expect(Set(served) == eligible)
        #expect(served.count == categories.count)
    }

    @Test func rotationDoesNotStarveASmallOrUnstarredCategory() {
        // Mirrors the real-world bug: Health/mindfulness has far fewer prompts and
        // none starred important, so under the old flat-pool draw it could vanish
        // for many days in a row. The rotation should still give it one slot per
        // cycle regardless of pool size, which the old algorithm never guaranteed.
        var rng = SeededRandom(seed: 7)
        let categories: [RotationKey] = [.category(.daily), .category(.work), .category(.mentalHealth)]
        var rotation = CategoryRotation(categories: categories, rng: &rng)

        var counts: [RotationKey: Int] = [:]
        let cycles = 50
        for _ in 0..<cycles {
            for _ in 0..<categories.count {
                let served = rotation.next(eligible: Set(categories), rng: &rng)!
                counts[served, default: 0] += 1
            }
        }

        // Every category served exactly once per cycle, no drift toward any one of them.
        for category in categories {
            #expect(counts[category] == cycles)
        }
    }

    @Test func rotationSkipsIneligibleCategoryWithoutLosingItsTurn() {
        // A category that's temporarily ineligible (e.g. inside a quiet window) should
        // be skipped for that slot but still get served once it becomes eligible again,
        // rather than being pushed to the back indefinitely.
        var rng = SeededRandom(seed: 99)
        let daily: RotationKey = .category(.daily)
        let health: RotationKey = .category(.mentalHealth)
        var rotation = CategoryRotation(categories: [daily, health], rng: &rng)

        // Health is "quiet" (ineligible) for several consecutive slots.
        var servedWhileHealthQuiet: [RotationKey] = []
        for _ in 0..<4 {
            servedWhileHealthQuiet.append(rotation.next(eligible: [daily], rng: &rng)!)
        }
        #expect(servedWhileHealthQuiet.allSatisfy { $0 == daily })

        // Once Health becomes eligible again, it gets served.
        let servedAfter = rotation.next(eligible: [daily, health], rng: &rng)
        #expect(servedAfter == health)
    }

    @Test func rotationReturnsNilWhenNothingIsEligible() {
        var rng = SeededRandom(seed: 1)
        var rotation = CategoryRotation(categories: [.category(.daily), .category(.mentalHealth)], rng: &rng)
        #expect(rotation.next(eligible: [], rng: &rng) == nil)
    }

    // MARK: - Random slot budget
    //
    // These guard the fix for the random feed going silent for weeks: scheduled
    // reminders (daily meds × 4 nudges, birthday lead-ins) filled all 60 pending
    // notification slots, leaving random prompts a budget of 0. Scheduled prompts are
    // now capped lower, and whatever budget random prompts get is spread across the day.

    @Test func scheduledCapAlwaysLeavesRoomForRandomPrompts() {
        #expect(ScheduledPromptScheduler.scheduledNotificationCap <= 40)
    }

    private func todayAt(_ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }

    @Test func slotsSpreadAcrossWholeDayWhenBudgetIsTight() {
        let start = todayAt(7), end = todayAt(22)
        let times = RandomPromptScheduler.planSlotTimes(
            start: start, end: end, intervalMinutes: 21, jitterMinutes: 2, budget: 20
        )

        #expect(times.count <= 20)
        #expect(times.count >= 18)
        #expect(times.allSatisfy { $0 >= start && $0 <= end })
        // Must still reach into the evening, not bunch up in the morning.
        #expect(times.last! >= todayAt(20))
    }

    @Test func slotsKeepRequestedCadenceWhenBudgetIsAmple() {
        let start = todayAt(7), end = todayAt(22)
        let times = RandomPromptScheduler.planSlotTimes(
            start: start, end: end, intervalMinutes: 21, jitterMinutes: 0, budget: 60
        )
        // 15h at 21m ≈ 42-43 slots — the budget doesn't force any widening.
        #expect(times.count >= 42)
        #expect(times.count <= 60)
    }

    @Test func noSlotsWithZeroBudgetOrEmptyWindow() {
        let start = todayAt(7), end = todayAt(22)
        #expect(RandomPromptScheduler.planSlotTimes(
            start: start, end: end, intervalMinutes: 21, jitterMinutes: 2, budget: 0
        ).isEmpty)
        #expect(RandomPromptScheduler.planSlotTimes(
            start: end, end: start, intervalMinutes: 21, jitterMinutes: 2, budget: 20
        ).isEmpty)
    }

    // MARK: - Scheduled prompts: every category gets its alert
    //
    // These pin a fixed "now" (Wednesday 4 Nov 2026, 10:00) so they don't depend on the
    // day they run. Quiet hours mirror the app defaults: 7am–8pm globally, and Work
    // quiet 5pm–9am plus weekends.

    private let cal = Calendar.current

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private var wednesday10am: Date { at(4, 10) }

    private func day(_ offset: Int, at hour: Int, from base: Date) -> Date {
        let d = cal.date(byAdding: .day, value: offset, to: base)!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: d)!
    }
    private let friday = 6 // Calendar weekday: 1 = Sunday … 7 = Saturday

    private func context(now: Date, prompt: PromptItem, category: PromptCategory = .daily,
                         banners: Int = ScheduledPromptScheduler.maxBannersPerReminder) -> ScheduledPlanContext {
        ScheduledPlanContext(
            now: now, calendar: cal, dayStartHour: 7, dayEndHour: 20,
            categoryQuietWindows: [.work: CategoryQuietWindow(startHour: 17, endHour: 9, weekendsQuiet: true)],
            categoryPromptIDs: [category: [prompt.id]],
            bannersPerReminder: banners
        )
    }

    private func plan(_ rule: PromptRule, now: Date, category: PromptCategory = .daily,
                      events: [PromptActionEvent] = [], text: String = "Prompt",
                      banners: Int = ScheduledPromptScheduler.maxBannersPerReminder) -> [PlannedScheduledNotification] {
        let prompt = PromptItem(text: text)
        let events = events.map { PromptActionEvent(promptID: prompt.id, promptText: text, action: $0.action, occurredAt: $0.occurredAt) }
        return ScheduledPromptScheduler.planPrompt(prompt, rule: rule, events: events,
                                                   context: context(now: now, prompt: prompt, category: category, banners: banners))
    }

    private func done(at date: Date) -> PromptActionEvent {
        PromptActionEvent(promptID: UUID(), promptText: "", action: .done, occurredAt: date)
    }

    @Test func weeklyFridayWithNoTimeIsARepeatingAlertOnFriday() {
        let planned = plan(PromptRule(weekday: friday, oneOff: false), now: wednesday10am)
        let primary = planned.filter { $0.kind == .primary }

        #expect(primary.count == 1)
        #expect(primary[0].repeating == DateComponents(hour: 7, minute: 0, weekday: friday))
        #expect(primary[0].fireDate == at(6, 7))
        // Nothing on Wednesday or Thursday.
        #expect(planned.allSatisfy { cal.component(.weekday, from: $0.fireDate) == friday })
    }

    @Test func weeklyFridayAt9pmIsNotSilencedByQuietHours() {
        let planned = plan(PromptRule(timeHour: 21, timeMinute: 0, weekday: friday, oneOff: false), now: wednesday10am)
        let primary = planned.first { $0.kind == .primary }
        #expect(primary?.fireDate == at(6, 21))
        #expect(primary?.repeating?.hour == 21)
        // The extra nudges around it do respect the 8pm cut-off.
        #expect(!planned.contains { $0.kind == .approach })
    }

    @Test func workPromptAfterFivePmStillGetsItsAlert() {
        let planned = plan(PromptRule(timeHour: 17, timeMinute: 30, weekday: friday, oneOff: false),
                           now: wednesday10am, category: .work)
        #expect(planned.contains { $0.kind == .primary && $0.fireDate == at(6, 17, 30) })
        #expect(!planned.contains { $0.kind == .approach })
    }

    @Test func workDayOnlyPromptAvoidsWorksQuietMorning() {
        // Work is quiet until 9am, so a day-only Work prompt goes out at 9, not 7.
        let planned = plan(PromptRule(weekday: friday, oneOff: false), now: wednesday10am, category: .work)
        #expect(planned.first { $0.kind == .primary }?.fireDate == at(6, 9))
    }

    @Test func dailyReminderRepeatsSoItArrivesWithoutOpeningTheApp() {
        let rule = PromptRule(timeHour: 8, timeMinute: 0, oneOff: false)
        #expect(rule.recurrenceKind == .daily)
        #expect(rule.hasSchedulingRule)

        let planned = plan(rule, now: wednesday10am)
        let primary = planned.filter { $0.kind == .primary }
        #expect(primary.count == 1)
        #expect(primary[0].repeating == DateComponents(hour: 8, minute: 0))
        #expect(primary[0].fireDate == at(5, 8))
    }

    @Test func dailyReminderDoneEarlyStillQueuesTheNextDays() {
        // Done at 7:30 for today's 8am: today's alert must not fire, tomorrow's must.
        let rule = PromptRule(timeHour: 8, timeMinute: 0, oneOff: false)
        let planned = plan(rule, now: at(4, 7, 40), events: [done(at: at(4, 7, 30))])
        let primaries = planned.filter { $0.kind == .primary }

        #expect(primaries.allSatisfy { $0.repeating == nil })
        #expect(primaries.map(\.fireDate) == [at(5, 8), at(6, 8), at(7, 8)])
        #expect(!planned.contains { cal.isDate($0.fireDate, inSameDayAs: at(4, 0)) })
    }

    @Test func onceOnFridayWithNoTimeOnlyRemindsOnFriday() {
        let planned = plan(PromptRule(weekday: friday, oneOff: true), now: wednesday10am)
        #expect(planned.contains { $0.kind == .primary && $0.fireDate == at(6, 7) })
        #expect(planned.allSatisfy { cal.isDate($0.fireDate, inSameDayAs: at(6, 0)) })
        #expect(planned.allSatisfy { cal.component(.hour, from: $0.fireDate) < 20 })
    }

    @Test func monthlyDateOnlyPromptAlertsOnTheDayAndTheDaysBefore() {
        let planned = plan(PromptRule(oneOff: false, monthlyDay: 9), now: wednesday10am)
        #expect(planned.contains { $0.kind == .primary && $0.fireDate == at(9, 7) })
        let leadIns = planned.filter { $0.kind == .leadIn }.map(\.fireDate)
        #expect(leadIns.contains(at(8, 7)))
        #expect(leadIns.allSatisfy { cal.component(.hour, from: $0) == 7 })
        #expect(planned.allSatisfy { cal.component(.hour, from: $0.fireDate) < 20 })
    }

    @Test func yearlyBirthdayAtNineRampsUpOverTheFortnightBefore() {
        let planned = plan(PromptRule(timeHour: 9, timeMinute: 0, oneOff: false, month: 11, day: 18), now: wednesday10am)
        #expect(planned.contains { $0.kind == .primary && $0.fireDate == at(18, 9) })
        let leadInDays = Set(planned.filter { $0.kind == .leadIn }.map { cal.component(.day, from: $0.fireDate) })
        // 14 days before is today (already past 9am); 7…1 days before are all there.
        #expect(leadInDays == [11, 12, 13, 14, 15, 16, 17])
    }

    @Test func fortnightlyBinNightAt9pmGetsItsRunUpInTheMorning() {
        let planned = plan(PromptRule(timeHour: 21, timeMinute: 0, oneOff: false, fortnightlyAnchorDate: at(6, 0)),
                           now: wednesday10am)
        #expect(planned.contains { $0.kind == .primary && $0.fireDate == at(6, 21) })
        let leadIns = planned.filter { $0.kind == .leadIn }.map(\.fireDate)
        #expect(leadIns.contains(at(5, 7)))
        #expect(leadIns.allSatisfy { cal.component(.hour, from: $0) == 7 })
    }

    @Test func timedAppointmentNudgesInTheRunUpAndOnTheTime() {
        let rule = PromptRule(timeHour: 15, timeMinute: 0, date: at(4, 0), oneOff: true)
        let planned = plan(rule, now: wednesday10am)
        #expect(planned.filter { $0.kind == .approach }.map(\.fireDate).sorted() == [at(4, 14, 30), at(4, 14, 45)])
        #expect(planned.contains { $0.kind == .primary && $0.fireDate == at(4, 15) })
        #expect(planned.filter { $0.kind == .followUp }.map(\.fireDate).sorted() == [at(4, 15, 15), at(4, 15, 30)])
    }

    @Test func missedOneOffNagsLaterNotEveryTimeTheAppIsTouched() {
        let rule = PromptRule(timeHour: 8, timeMinute: 0, oneOff: true)
        let planned = plan(rule, now: wednesday10am)
        let overdue = planned.filter { $0.kind == .overdue }
        #expect(!overdue.isEmpty)
        #expect(overdue.allSatisfy { $0.fireDate >= wednesday10am.addingTimeInterval(3600) })
    }

    @Test func weeklyJustPassedKeepsItsFollowUps() {
        // 6:10pm Friday, the 6pm reminder fired 10 minutes ago and hasn't been ticked off.
        let planned = plan(PromptRule(timeHour: 18, timeMinute: 0, weekday: friday, oneOff: false), now: at(6, 18, 10))
        #expect(planned.filter { $0.kind == .followUp }.map(\.fireDate).contains(at(6, 18, 15)))
        #expect(planned.contains { $0.kind == .primary && $0.repeating != nil })
    }

    @Test func busyDailyListCannotCrowdOutAnotherCategorysAlert() {
        // 15 daily set-time reminders (4-5 nudges each) used to fill every slot.
        let now = wednesday10am
        var prompts: [PromptItem] = []
        var rules: [String: PromptRule] = [:]
        for i in 0..<15 {
            let p = PromptItem(text: "Daily \(i)")
            prompts.append(p)
            rules[p.id.uuidString] = PromptRule(timeHour: 11 + i % 8, timeMinute: i, oneOff: false)
        }
        let bins = PromptItem(text: "Bins")
        let birthday = PromptItem(text: "Birthday")
        prompts += [bins, birthday]
        rules[bins.id.uuidString] = PromptRule(weekday: friday, oneOff: false)
        rules[birthday.id.uuidString] = PromptRule(oneOff: false, month: 11, day: 20)

        let ctx = ScheduledPlanContext(now: now, calendar: cal, dayStartHour: 7, dayEndHour: 20)
        let planned = ScheduledPromptScheduler.plan(prompts: prompts, rules: rules, events: [], context: ctx)
        #expect(planned.count > ScheduledPromptScheduler.scheduledNotificationCap)

        let kept = ScheduledPromptScheduler.prioritised(planned, now: now, cap: ScheduledPromptScheduler.scheduledNotificationCap)
        #expect(kept.count == ScheduledPromptScheduler.scheduledNotificationCap)
        let keptPrimaryIDs = Set(kept.filter { $0.kind == .primary }.map(\.promptID))
        #expect(keptPrimaryIDs == Set(prompts.map(\.id)))
    }

    @Test func dailyRuleDescribesItselfAsEveryDay() {
        #expect(PromptRule(timeHour: 8, timeMinute: 0, oneOff: false).scheduleDescription.hasPrefix("Every day"))
        #expect(PromptRule(timeHour: 8, timeMinute: 0, oneOff: true).recurrenceKind == .oneOff)
    }

    // MARK: - Lock Screen duplicate banners

    @Test func collapseKeepsOnlyNewestBannerPerPrompt() {
        let t0 = Date()
        let delivered: [(id: String, promptKey: String?, date: Date)] = [
            ("poo-1", "poo", t0),
            ("poo-2", "poo", t0.addingTimeInterval(600)),
            ("poo-3", "poo", t0.addingTimeInterval(1200)),
            ("bins-1", "bins", t0),
            ("summary", nil, t0),
        ]
        let stale = Set(NotificationsManager.staleDuplicateIDs(in: delivered))
        #expect(stale == ["poo-1", "poo-2"])
    }

    // MARK: - Cycle start
    //
    // Guards the fix for daily 8am reminders and weekly bin night vanishing: planning in
    // the evening rolled the target to the next occurrence, but the "already acted on"
    // check started at midnight today, so that morning's Done/Skip suppressed tomorrow's.

    @Test func dailyReminderPlannedInTheEveningIgnoresThisMorningsAction() {
        let cal = Calendar.current
        let rule = PromptRule(timeHour: 8, timeMinute: 0, oneOff: false)
        let evening = todayAt(23)
        let target = rule.nextTarget(after: evening)!

        #expect(cal.isDate(target, inSameDayAs: day(1, at: 0, from: evening)))
        let skippedThisMorning = todayAt(8).addingTimeInterval(30 * 60)
        #expect(skippedThisMorning < rule.cycleStart(for: target, now: evening))
    }

    @Test func weeklyReminderDoneTonightDoesNotCancelNextWeek() {
        let cal = Calendar.current
        let tonight = todayAt(21)
        let rule = PromptRule(timeHour: 21, timeMinute: 0, weekday: cal.component(.weekday, from: tonight), oneOff: false)
        let later = tonight.addingTimeInterval(2 * 3600)
        let target = rule.nextTarget(after: later)!

        #expect(cal.isDate(target, inSameDayAs: day(7, at: 0, from: tonight)))
        let doneTonight = tonight.addingTimeInterval(15 * 60)
        let start = rule.cycleStart(for: target, now: later)
        #expect(doneTonight < start)
        // Done early in the week still counts for that week.
        #expect(day(3, at: 12, from: tonight) >= start)
    }

    // MARK: - Bare "Once" to-dos stay in the random feed
    //
    // Guards the fix for to-dos set to Once with no date/day/time (the whole Work list)
    // vanishing from the random prompts: they counted as scheduled, so only the
    // scheduled side looked at them, and it had no real time to aim for.

    @Test func bareOnceToDoStaysInRandomPoolButIsStillPurgedWhenDone() {
        let bareOnce = PromptRule(oneOff: true)
        #expect(!bareOnce.hasSchedulingRule)
        #expect(bareOnce.recurrenceKind == .oneOff)

        #expect(PromptRule(timeHour: 9, timeMinute: 0, oneOff: true).hasSchedulingRule)
        #expect(PromptRule(weekday: 2, oneOff: true).hasSchedulingRule)
        #expect(PromptRule(date: todayAt(0), oneOff: true).hasSchedulingRule)
    }

    // The green "Once" capsule must agree with the alert editor's Once/Repeat picker:
    // an explicit choice wins, legacy rules (oneOff == nil) fall back to their structure.
    @Test func isOneOffMatchesTheEditorsOnceRepeatChoice() {
        #expect(PromptRule(oneOff: true).isOneOff)
        #expect(PromptRule(timeHour: 9, timeMinute: 0, oneOff: true).isOneOff)
        #expect(!PromptRule(oneOff: false).isOneOff)
        #expect(!PromptRule(date: todayAt(0), oneOff: false).isOneOff)  // dated yearly-style repeat

        #expect(PromptRule(date: todayAt(0)).isOneOff)             // legacy dated -> Once
        #expect(!PromptRule(weekday: 2).isOneOff)                  // legacy weekly -> Repeat
        #expect(!PromptRule().isOneOff)                            // nothing set -> Repeat
    }


    // MARK: - Banners per Reminder slider
    //
    // Settings → Done! → Banners per Reminder (1…5, default 3) limits how many banners one
    // occurrence of a scheduled prompt sends. Extras are added closest-to-the-time first.

    @Test func bannerSliderRoundsAndClampsToOneThroughFive() {
        #expect(RandomPromptRules.bannersPerReminder(forSlider: 0) == 1)
        #expect(RandomPromptRules.bannersPerReminder(forSlider: 1.2) == 1)
        #expect(RandomPromptRules.bannersPerReminder(forSlider: 3) == 3)
        #expect(RandomPromptRules.bannersPerReminder(forSlider: 3.6) == 4)
        #expect(RandomPromptRules.bannersPerReminder(forSlider: 9) == 5)
    }

    private func timedFireTimes(banners: Int) -> [Date] {
        let rule = PromptRule(timeHour: 15, timeMinute: 0, weekday: friday, oneOff: false)
        let planned = plan(rule, now: wednesday10am, banners: banners)
        // This Friday only (the repeating primary stands for every Friday).
        return planned.filter { cal.isDate($0.fireDate, inSameDayAs: at(6, 0)) }.map(\.fireDate).sorted()
    }

    @Test func timedReminderSendsOnlyAsManyBannersAsTheSliderAllows() {
        #expect(timedFireTimes(banners: 1) == [at(6, 15)])
        #expect(timedFireTimes(banners: 2) == [at(6, 14, 45), at(6, 15)])
        #expect(timedFireTimes(banners: 3) == [at(6, 14, 45), at(6, 15), at(6, 15, 15)])
        #expect(timedFireTimes(banners: 5) == [at(6, 14, 30), at(6, 14, 45), at(6, 15), at(6, 15, 15), at(6, 15, 30)])
    }

    @Test func dayOnlyReminderFollowUpsFollowTheSlider() {
        let rule = PromptRule(weekday: friday, oneOff: false)
        func times(_ banners: Int) -> [Date] {
            plan(rule, now: wednesday10am, banners: banners)
                .filter { cal.isDate($0.fireDate, inSameDayAs: at(6, 0)) }.map(\.fireDate).sorted()
        }
        #expect(times(1) == [at(6, 7)])
        #expect(times(3) == [at(6, 7), at(6, 11), at(6, 15)])
        #expect(times(5) == [at(6, 7), at(6, 11), at(6, 15), at(6, 19)])
    }

    @Test func missedOneOffNagsAreLimitedBySlider() {
        let rule = PromptRule(timeHour: 8, timeMinute: 0, oneOff: true)
        #expect(plan(rule, now: wednesday10am, banners: 1).isEmpty)
        #expect(plan(rule, now: wednesday10am, banners: 3).filter { $0.kind == .overdue }.count == 2)
    }

    @Test func bannerSliderLeavesBirthdayLeadInDaysAlone() {
        let rule = PromptRule(timeHour: 9, timeMinute: 0, oneOff: false, month: 11, day: 18)
        let planned = plan(rule, now: wednesday10am, banners: 1)
        #expect(planned.filter { $0.kind == .leadIn }.count == 7)
        #expect(planned.filter { cal.isDate($0.fireDate, inSameDayAs: at(18, 0)) }.map(\.kind) == [.primary])
    }

}
