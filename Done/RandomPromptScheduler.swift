//
//  RandomPromptScheduler.swift
//  Done
//
//  Created by Patrick Sarell on 4/11/2025.
//

import Foundation
import UserNotifications

// Simple knobs we’ll expose in a settings screen later
struct RandomPromptRules: Codable {
    // NOTE: promptsPerDay/minGapMinutes kept for backward-compat,
    // but this 20-min build derives count from the window length.
    var promptsPerDay: Int = 5              // (unused in this build)
    var dayStartHour: Int = 9               // window start (24h)
    var dayEndHour: Int = 20                // window end (24h)
    var minGapMinutes: Int = 60             // (unused in this build)
    var noRepeatDays: Int = 2               // don’t re-show same prompt within N days
    var weightImportant: Int = 3            // multiplier for "important" prompts (future)

    // Exact cadence controls
    var intervalMinutes: Int = 20           // 🔸 one notification every 20 minutes
    var jitterMinutes: Int = 2              // small +/- jitter to feel organic
}

// NOTE: using your existing PromptItem from PromptsView persistence.

final class RandomPromptScheduler {
    static let shared = RandomPromptScheduler()
    private init() {}

    // MARK: - History (avoid repeats + cancel old plan)
    private struct History: Codable {
        var lastShown: [UUID: Date] = [:]   // prompt id -> last shown date
        var lastPlanDate: String? = nil     // "yyyy-MM-dd"
        var pendingIDs: [String] = []       // identifiers scheduled for today (so we can cancel if needed)
        var lastText: String? = nil         // last text we scheduled (avoid immediate duplicate)
    }

    private var historyURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("random_prompt_history.json")
    }

    // MARK: - Entry point

    /// Call on app launch / when prompts change. Plans *today’s* notifications once.
    func refreshScheduleToday(allPrompts: [PromptItem], rules: RandomPromptRules = .init()) {
        guard !allPrompts.isEmpty else { return }

        var history = loadHistory()
        let todayKey = Self.dayKey(Date())

        // Plan only once per calendar day
        if history.lastPlanDate == todayKey { return }

        // Cancel any pending plan from a previous run so we can rebuild fresh
        if !history.pendingIDs.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: history.pendingIDs)
            history.pendingIDs.removeAll()
        }

        // Filter candidates (non-empty text) and exclude recently shown within N days
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -rules.noRepeatDays, to: now) ?? now
        var candidates = allPrompts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        candidates.removeAll { p in
            if let d = history.lastShown[p.id] { return d > cutoff }
            return false
        }
        if candidates.isEmpty { candidates = allPrompts } // fallback

        // Build today’s window
        let cal = Calendar.current
        guard
            let start0 = cal.date(bySettingHour: rules.dayStartHour, minute: 0, second: 0, of: now),
            let end0   = cal.date(bySettingHour: rules.dayEndHour, minute: 0, second: 0, of: now)
        else {
            history.lastPlanDate = todayKey
            saveHistory(history)
            return
        }

        let start = max(start0, now)
        let end = end0 <= start ? start.addingTimeInterval(3600) : end0 // guard against inverted window

        // Generate 20-min slots from "next slot after now" up to end, capped at 64
        let times = Self.generateEveryInterval(
            start: start,
            end: end,
            intervalMinutes: rules.intervalMinutes,
            jitterMinutes: rules.jitterMinutes
        )

        guard !times.isEmpty else {
            history.lastPlanDate = todayKey
            saveHistory(history)
            return
        }

        // Deterministic pool shuffle (kept from your version)
        var rng = SeededRandom(seed: UInt64(todayKey.hashValue ^ candidates.count))
        var pool = candidates
        pool.shuffle(using: &rng)

        // load per-prompt temporal rules once
        let perPromptRules = PromptRulesStore.load()

        var scheduledIDs: [String] = []
        var lastText = history.lastText
        var scheduledCount = 0

        for (i, time) in times.enumerated() {
            // filter eligible prompts *for this exact fire time* by rules
            let eligible = PromptSelector.eligible(from: pool, rules: perPromptRules, at: time, cal: cal)

            // Pick next avoiding immediate duplicate; if no eligible, skip this slot
            guard let next = pickNextPrompt(fromEligible: eligible, lastText: lastText, fallback: pool, rng: &rng) else {
                continue
            }

            lastText = next.text

            let id = notifID(for: next.id, on: time, index: i)
            NotificationsManager.shared.scheduleOneOff(id: id, title: next.text, at: time)
            scheduledIDs.append(id)

            history.lastShown[next.id] = now
            scheduledCount += 1
        }

        history.lastPlanDate = todayKey
        history.pendingIDs = scheduledIDs
        history.lastText = lastText
        saveHistory(history)

        print("RPS: planned \(scheduledCount) notifications at ~every \(rules.intervalMinutes)m between \(start)–\(end)")
    }

    // MARK: - Pick helper (avoid immediate duplicate; respects eligibility)
    private func pickNextPrompt(fromEligible eligible: [PromptItem],
                                lastText: String?,
                                fallback: [PromptItem],
                                rng: inout SeededRandom) -> PromptItem? {
        if eligible.isEmpty {
            // nothing eligible at this moment -> skip this slot
            return nil
        }
        if let lastText, let nonRepeat = eligible.first(where: { $0.text != lastText }) {
            return nonRepeat
        }
        return eligible.randomElement(using: &rng) ?? eligible.first ?? fallback.randomElement(using: &rng)
    }

    // MARK: - IDs / History IO

    private func notifID(for id: UUID, on date: Date, index: Int) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmm"
        return "rand-\(df.string(from: date))-\(index)-\(id.uuidString)"
    }

    private func loadHistory() -> History {
        do {
            let data = try Data(contentsOf: historyURL)
            return try JSONDecoder().decode(History.self, from: data)
        } catch { return History() }
    }

    private func saveHistory(_ h: History) {
        do {
            let data = try JSONEncoder().encode(h)
            try data.write(to: historyURL, options: .atomic)
        } catch { /* ignore for WIP */ }
    }

    private static func dayKey(_ date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    // MARK: - Time generation (every N minutes, jittered, cap 64)
    private static func generateEveryInterval(start: Date,
                                              end: Date,
                                              intervalMinutes: Int,
                                              jitterMinutes: Int) -> [Date] {
        guard intervalMinutes > 0, end > start else { return [] }

        // Align the first slot to the next interval boundary after 'start'
        let interval = Double(intervalMinutes * 60)
        let jitter   = Double(max(0, jitterMinutes) * 60)

        var out: [Date] = []
        var t = alignedNext(after: start, step: interval)

        while t <= end && out.count < 64 { // iOS pending cap safety
            // Apply small jitter within bounds (±jitter)
            let j = jitter > 0 ? Double.random(in: -jitter...jitter) : 0
            var candidate = t.addingTimeInterval(j)

            // Keep inside [start, end]
            if candidate < start { candidate = start }
            if candidate > end { candidate = end }

            // Ensure chronological order (monotonic)
            if let last = out.last, candidate <= last {
                candidate = last.addingTimeInterval(interval)
                if candidate > end { break }
            }

            out.append(candidate)
            t = t.addingTimeInterval(interval)
        }
        return out
    }

    /// Round up to the next multiple of `step` seconds from a reference anchor (midnight).
    private static func alignedNext(after date: Date, step: TimeInterval) -> Date {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let elapsed = date.timeIntervalSince(startOfDay)
        let nextBucket = ceil(elapsed / step) * step
        return startOfDay.addingTimeInterval(nextBucket)
    }
}

// Deterministic RNG
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 0x9e3779b97f4a7c15 }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z ^= z >> 30; z &*= 0xbf58476d1ce4e5b9
        z ^= z >> 27; z &*= 0x94d049bb133111eb
        z ^= z >> 31
        return z
    }
}
