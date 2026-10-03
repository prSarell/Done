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

}
