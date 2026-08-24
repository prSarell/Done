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

    // In this build we allow prompts to repeat within the same day.
    // noRepeatDays > 0 would suppress prompts that were shown recently,
    // but the default 0 means "no cross-day suppression".
    var noRepeatDays: Int = 0               // don’t re-show within N days (0 = allow repeats)

    var weightImportant: Int = 3            // multiplier for "important" prompts (future)

    // Exact cadence controls
    var intervalMinutes: Int = 20           // 🔸 one notification every 20 minutes
    var jitterMinutes: Int = 2              // small +/- jitter to feel organic
}

/// A quiet window for one prompt category: prompts from that category are suppressed
/// between `startHour` and `endHour` (wrapping past midnight if `startHour > endHour`),
/// and optionally suppressed all day on weekends. `startHour == endHour` with
/// `weekendsQuiet == false` means "no quiet window" (never suppressed).
struct CategoryQuietWindow: Codable {
    var startHour: Int = 0
    var endHour: Int = 0
    var weekendsQuiet: Bool = false

    func isQuiet(at date: Date, cal: Calendar) -> Bool {
        let weekday = cal.component(.weekday, from: date) // 1 = Sun, 7 = Sat
        if weekendsQuiet && (weekday == 1 || weekday == 7) { return true }
        guard startHour != endHour else { return false }
        let hour = cal.component(.hour, from: date)
        return startHour < endHour
            ? (hour >= startHour && hour < endHour)
            : (hour >= startHour || hour < endHour)
    }
}

extension CategoryQuietWindow {
    /// Reads the per-category quiet-hours settings registered from Settings.bundle
    /// (see `Done/Settings.bundle/<Category>.plist` and the defaults registered in
    /// `DoneApp.init()`).
    static func loadAllFromUserDefaults() -> [PromptCategory: CategoryQuietWindow] {
        let defaults = UserDefaults.standard
        return Dictionary(uniqueKeysWithValues: PromptCategory.allCases.map { category in
            let key = category.settingsKey
            let window = CategoryQuietWindow(
                startHour: defaults.integer(forKey: "quiet_\(key)_start"),
                endHour: defaults.integer(forKey: "quiet_\(key)_end"),
                weekendsQuiet: defaults.bool(forKey: "quiet_\(key)_weekends")
            )
            return (category, window)
        })
    }
}

extension RandomPromptRules {
    /// Builds rules from the Settings.bundle-backed UserDefaults keys registered in
    /// `DoneApp.init()`, falling back to this struct's own defaults if unset.
    static func loadFromUserDefaults() -> RandomPromptRules {
        let defaults = UserDefaults.standard
        var rules = RandomPromptRules()
        rules.intervalMinutes = intervalMinutes(forIntensity: defaults.double(forKey: "notification_intensity"))
        rules.dayStartHour = defaults.integer(forKey: "global_earliest_hour")
        rules.dayEndHour = defaults.integer(forKey: "global_latest_hour")
        return rules
    }

    /// Piecewise map from the `notification_intensity` slider to minutes between prompts:
    /// cold (0.0) ≈ 60min, default (0.5) ≈ 20min, hot (1.0) ≈ 10min.
    private static func intervalMinutes(forIntensity intensity: Double) -> Int {
        let clamped = min(max(intensity, 0), 1)
        let minutes = clamped <= 0.5
            ? 60 - 80 * clamped
            : 30 - 20 * clamped
        return Int(minutes.rounded())
    }
}

// NOTE: using your existing PromptItem from PromptsView persistence.

final class RandomPromptScheduler {
    static let shared = RandomPromptScheduler()
    private init() {}

    // MARK: - History (avoid repeats + cancel old plan)

    private struct History: Codable {
        /// Use String keys for stable Codable (UUID dictionary keys are fragile across environments)
        var lastShown: [String: Date] = [:]     // prompt UUID string -> last shown date
        var lastPlanDate: String? = nil         // "yyyy-MM-dd"
        var pendingIDs: [String] = []           // identifiers scheduled for today (so we can cancel if needed)
        var lastText: String? = nil             // last text we scheduled (avoid immediate duplicate)
    }

    private var historyURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("random_prompt_history.json")
    }

    // MARK: - Re-entrancy guard / throttle

    private let refreshLock = NSLock()
    private var isRefreshing: Bool = false
    private var lastRefreshAt: Date? = nil

    // MARK: - Entry point

    /// iOS silently drops pending local notifications once an app's total exceeds ~64.
    /// Scheduled/dated prompts (see `ScheduledPromptScheduler`) get first claim on that
    /// budget since they're time-specific; random prompts only fill what's left, keeping
    /// the combined total safely under the OS cap.
    private static let combinedNotificationCap = 60

    /// Call on app launch / when prompts change. Plans *today’s* notifications once.
    func refreshScheduleToday(
        allPrompts: [PromptItem],
        categoryPromptIDs: [PromptCategory: Set<UUID>] = [:],
        categoryQuietWindows: [PromptCategory: CategoryQuietWindow] = [:],
        rules: RandomPromptRules = .init(),
        forceRebuild: Bool = false
    ) {
        #if DEBUG
        print("RPS: refreshScheduleToday called with \(allPrompts.count) prompts | forceRebuild=\(forceRebuild)")
        #endif

        // Scheduled/date-driven prompts are handled by their own scheduler. Wait for it to
        // fully settle before planning random ones, so we know the real "sched-*" pending
        // count and can size the random budget against it (see combinedNotificationCap).
        ScheduledPromptScheduler.shared.refreshSchedule(
            prompts: allPrompts,
            categoryPromptIDs: categoryPromptIDs,
            categoryQuietWindows: categoryQuietWindows,
            globalRules: rules
        ) { [weak self] in
            self?.continueRefreshAfterScheduledPlanning(
                allPrompts: allPrompts,
                categoryPromptIDs: categoryPromptIDs,
                categoryQuietWindows: categoryQuietWindows,
                rules: rules,
                forceRebuild: forceRebuild
            )
        }
    }

    private func continueRefreshAfterScheduledPlanning(
        allPrompts: [PromptItem],
        categoryPromptIDs: [PromptCategory: Set<UUID>],
        categoryQuietWindows: [PromptCategory: CategoryQuietWindow],
        rules: RandomPromptRules,
        forceRebuild: Bool
    ) {
        guard !allPrompts.isEmpty else {
            #if DEBUG
            print("RPS: no prompts supplied, skipping random plan rebuild")
            #endif
            finishRefresh()
            return
        }

        // Prevent overlapping refresh calls
        refreshLock.lock()
        if isRefreshing {
            #if DEBUG
            print("RPS: skipped refresh because a refresh is already in progress")
            #endif
            refreshLock.unlock()
            return
        }
        isRefreshing = true

        // Tiny throttle to avoid spam refresh loops
        let nowForThrottle = Date()
        if let last = lastRefreshAt, nowForThrottle.timeIntervalSince(last) < 0.5 {
            #if DEBUG
            print("RPS: throttled refresh (\(nowForThrottle.timeIntervalSince(last))s since last)")
            #endif
            isRefreshing = false
            refreshLock.unlock()
            return
        }
        lastRefreshAt = nowForThrottle
        refreshLock.unlock()

        let now = Date()
        let cal = Calendar.current
        let todayKey = Self.dayKey(now)

        var history = loadHistory()

        // Plan only once per calendar day, unless forceRebuild is true
        if !forceRebuild, history.lastPlanDate == todayKey {
            #if DEBUG
            print("RPS: random plan already exists for today, not rebuilding")
            #endif
            finishRefresh()
            return
        }

        // Cancel any pending plan we know about
        if !history.pendingIDs.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: history.pendingIDs)
            history.pendingIDs.removeAll()
        }

        // Belt + braces:
        // If history was missing/corrupt before, we may have old rand-* requests queued.
        // Remove all pending rand-* requests so we don’t stack duplicates.
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            let randIDs = reqs
                .map(\.identifier)
                .filter { $0.hasPrefix("rand-") }

            if !randIDs.isEmpty {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: randIDs)
            }

            // ScheduledPromptScheduler has already finished its own cancel/rebuild pass by
            // this point, so any "sched-*" requests here reflect its final pending count.
            let schedCount = reqs.filter { $0.identifier.hasPrefix("sched-") }.count
            let randomBudget = max(0, Self.combinedNotificationCap - schedCount)

            #if DEBUG
            print("RPS: \(schedCount) sched-* pending, leaving a budget of \(randomBudget) for random prompts")
            #endif

            // Continue planning after cleanup
            self.planNow(
                allPrompts: allPrompts,
                categoryPromptIDs: categoryPromptIDs,
                categoryQuietWindows: categoryQuietWindows,
                rules: rules,
                history: history,
                todayKey: todayKey,
                now: now,
                cal: cal,
                randomBudget: randomBudget
            )
        }
    }

    // MARK: - Planning core (runs after async pending fetch)

    private func planNow(
        allPrompts: [PromptItem],
        categoryPromptIDs: [PromptCategory: Set<UUID>],
        categoryQuietWindows: [PromptCategory: CategoryQuietWindow],
        rules: RandomPromptRules,
        history: History,
        todayKey: String,
        now: Date,
        cal: Calendar,
        randomBudget: Int
    ) {
        var history = history

        let perPromptRules = PromptRulesStore.load() ?? [:]

        // Build set of prompt IDs already acted on today (done or skipped)
        let todayStart = cal.startOfDay(for: now)
        let actedOnToday: Set<UUID> = Set(
            PromptStatusStore.load()
                .filter { $0.occurredAt >= todayStart }
                .map { $0.promptID }
        )

        // Filter candidates:
        // 1. non-empty text
        // 2. EXCLUDE prompts with a valid scheduling rule
        //    (scheduled prompts belong only to ScheduledPromptScheduler)
        // 3. KEEP prompts with no rule, or malformed/incomplete rule
        //    so they don't disappear from both systems
        var candidates = allPrompts.filter { prompt in
            let trimmed = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }

            // Exclude prompts already done or skipped today
            if actedOnToday.contains(prompt.id) {
                #if DEBUG
                print("RPS: excluding prompt acted on today -> '\(prompt.text)'")
                #endif
                return false
            }

            guard let rule = perPromptRules[prompt.id.uuidString] else {
                return true // no rule -> stays in random pool
            }

            if rule.hasSchedulingRule {
                #if DEBUG
                print("RPS: excluding scheduled prompt from random pool -> '\(prompt.text)' (\(rule.recurrenceKind.rawValue))")
                #endif
                return false
            }

            #if DEBUG
            print("RPS: keeping prompt with non-schedulable rule in random pool -> '\(prompt.text)'")
            #endif
            return true
        }

        #if DEBUG
        print("RPS: \(candidates.count) prompts remain in random pool after excluding scheduled prompts")
        #endif

        // Optional cross-day suppression:
        if rules.noRepeatDays > 0 {
            let cutoff = cal.date(byAdding: .day, value: -rules.noRepeatDays, to: now) ?? now
            candidates.removeAll { p in
                if let d = history.lastShown[p.id.uuidString] {
                    return d > cutoff
                }
                return false
            }
            if candidates.isEmpty {
                candidates = allPrompts.filter { prompt in
                    let trimmed = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return false }

                    // Keep the same "already acted on today" exclusion as the primary
                    // filter above — otherwise this fallback can re-offer a prompt just
                    // marked done/skipped today.
                    guard !actedOnToday.contains(prompt.id) else { return false }

                    guard let rule = perPromptRules[prompt.id.uuidString] else {
                        return true
                    }

                    return !rule.hasSchedulingRule
                }
            }
        }

        #if DEBUG
        print("RPS: \(candidates.count) prompts available after repeat suppression")
        #endif

        guard !candidates.isEmpty else {
            #if DEBUG
            print("RPS: no candidates available for random scheduling")
            #endif
            history.lastPlanDate = todayKey
            saveHistory(history)
            finishRefresh()
            return
        }

        // Build today’s window
        guard
            let start0 = cal.date(bySettingHour: rules.dayStartHour, minute: 0, second: 0, of: now),
            let end0   = cal.date(bySettingHour: rules.dayEndHour, minute: 0, second: 0, of: now)
        else {
            history.lastPlanDate = todayKey
            saveHistory(history)
            finishRefresh()
            return
        }

        let start = max(start0, now)
        let end = end0 <= start ? start.addingTimeInterval(3600) : end0

        // Generate slots from "next slot after now" up to end, capped at 64, then further
        // capped by randomBudget so combined with ScheduledPromptScheduler's own pending
        // requests we stay safely under iOS's ~64 pending-notification ceiling.
        let generatedTimes = Self.generateEveryInterval(
            start: start,
            end: end,
            intervalMinutes: rules.intervalMinutes,
            jitterMinutes: rules.jitterMinutes
        )
        let times = Array(generatedTimes.prefix(randomBudget))

        #if DEBUG
        if times.count < generatedTimes.count {
            print("RPS: trimmed \(generatedTimes.count) candidate slots down to \(times.count) to respect randomBudget=\(randomBudget)")
        }
        #endif

        guard !times.isEmpty else {
            history.lastPlanDate = todayKey
            saveHistory(history)
            finishRefresh()
            return
        }

        // Deterministic seed for this day's shuffles/picks
        let seedInt = todayKey.hashValue ^ candidates.count
        let seed = UInt64(bitPattern: Int64(seedInt))
        var rng = SeededRandom(seed: seed)

        // Reverse-lookup so each candidate knows which category it belongs to.
        var promptCategory: [UUID: PromptCategory] = [:]
        for (category, ids) in categoryPromptIDs {
            for id in ids { promptCategory[id] = category }
        }

        // Weighted pool per category — "important" prompts are duplicated to weight
        // them higher *within their own category* (see `RotationKey`/`CategoryRotation`
        // below for why this is no longer a single combined pool: a flat draw let a
        // category with more prompts, or more prompts starred important, crowd out a
        // smaller/less-starred category like Health over time, even with nothing
        // misconfigured).
        var categoryPools: [RotationKey: [PromptItem]] = [:]
        for prompt in candidates {
            let key: RotationKey = promptCategory[prompt.id].map(RotationKey.category) ?? .other
            let weight = perPromptRules[prompt.id.uuidString]?.isImportant == true ? rules.weightImportant : 1
            categoryPools[key, default: []].append(contentsOf: Array(repeating: prompt, count: weight))
        }
        for key in categoryPools.keys {
            categoryPools[key]?.shuffle(using: &rng)
        }

        var rotation = CategoryRotation(categories: Array(categoryPools.keys), rng: &rng)

        var scheduledIDs: [String] = []
        var lastText = history.lastText
        var scheduledCount = 0

        for (i, time) in times.enumerated() {
            // Categories currently inside their quiet window (e.g. Work defaults to
            // quiet outside Mon–Fri 9am–5pm) are suppressed entirely for this slot;
            // everything else is narrowed to prompts whose per-prompt rule is active now.
            var eligibleByCategory: [RotationKey: [PromptItem]] = [:]
            for (key, items) in categoryPools {
                if case .category(let category) = key,
                   let window = categoryQuietWindows[category],
                   window.isQuiet(at: time, cal: cal) {
                    continue
                }
                let active = PromptSelector.eligible(from: items, rules: perPromptRules, at: time, cal: cal)
                if !active.isEmpty { eligibleByCategory[key] = active }
            }

            guard !eligibleByCategory.isEmpty,
                  let chosenCategory = rotation.next(eligible: Set(eligibleByCategory.keys), rng: &rng),
                  let next = pickNextPrompt(fromEligible: eligibleByCategory[chosenCategory] ?? [], lastText: lastText, rng: &rng) else {
                continue
            }

            lastText = next.text

            // Stable deterministic ID per slot
            let id = notifID(for: next.id, on: time, index: i)

            let userInfo: [AnyHashable: Any] = [
                PromptNotificationDelegate.kPromptID: next.id.uuidString,
                PromptNotificationDelegate.kPromptText: next.text,
                PromptNotificationDelegate.kPromptDate: time.timeIntervalSince1970
            ]
            let isImportant = perPromptRules[next.id.uuidString]?.isImportant == true
            NotificationsManager.shared.scheduleOneOff(
                id: id,
                title: isImportant ? "⭐️ \(next.text)" : next.text,
                at: time,
                userInfo: userInfo,
                categoryID: PromptNotificationDelegate.categoryID
            )
            scheduledIDs.append(id)

            // Track last shown (use actual planned fire time, not "now")
            history.lastShown[next.id.uuidString] = time
            scheduledCount += 1
        }

        history.lastPlanDate = todayKey
        history.pendingIDs = scheduledIDs
        history.lastText = lastText
        saveHistory(history)

        #if DEBUG
        print("RPS: planned \(scheduledCount) random notifications at ~every \(rules.intervalMinutes)m between \(start)–\(end)")
        #endif

        finishRefresh()
    }

    // MARK: - Pick helper (avoid immediate duplicate; respects eligibility)

    private func pickNextPrompt(
        fromEligible eligible: [PromptItem],
        lastText: String?,
        rng: inout SeededRandom
    ) -> PromptItem? {
        guard !eligible.isEmpty else { return nil }

        if let lastText, eligible.count > 1 {
            let filtered = eligible.filter { $0.text != lastText }
            if let chosen = filtered.randomElement(using: &rng) {
                return chosen
            }
        }

        return eligible.randomElement(using: &rng) ?? eligible.first
    }

    // MARK: - IDs / History IO

    private func notifID(for id: UUID, on date: Date, index: Int) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        return "rand-\(df.string(from: date))-\(index)-\(id.uuidString)"
    }

    private func loadHistory() -> History {
        do {
            let data = try Data(contentsOf: historyURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(History.self, from: data)
        } catch {
            #if DEBUG
            print("RPS: loadHistory failed (starting fresh): \(error)")
            #endif
            return History()
        }
    }

    private func saveHistory(_ h: History) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(h)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            #if DEBUG
            print("RPS: saveHistory failed: \(error)")
            print("   → File: \(historyURL.path)")
            #endif
        }
    }

    private func finishRefresh() {
        refreshLock.lock()
        isRefreshing = false
        refreshLock.unlock()
    }

    private static func dayKey(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    // MARK: - Time generation (every N minutes, jittered, cap 64)

    private static func generateEveryInterval(
        start: Date,
        end: Date,
        intervalMinutes: Int,
        jitterMinutes: Int
    ) -> [Date] {
        guard intervalMinutes > 0, end > start else { return [] }

        let interval = Double(intervalMinutes * 60)
        let jitter   = Double(max(0, jitterMinutes) * 60)

        var out: [Date] = []
        var t = alignedNext(after: start, step: interval)

        while t <= end && out.count < 64 {
            let j = jitter > 0 ? Double.random(in: -jitter...jitter) : 0
            var candidate = t.addingTimeInterval(j)

            if candidate < start { candidate = start }
            if candidate > end { candidate = end }

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

/// Groups a candidate prompt for round-robin purposes. `.other` is a defensive bucket
/// for a prompt that isn't in any category's ID set (shouldn't happen given how
/// `categoryPromptIDs` is built from the real prompt lists, but keeps such a prompt
/// from being silently dropped rather than crowding out a real category).
enum RotationKey: Hashable {
    case category(PromptCategory)
    case other
}

/// Round-robins through prompt categories so a single day's plan can't drift toward
/// favoring one category over another the way a flat weighted draw across all
/// candidates can (a category with more prompts, or more prompts starred important,
/// wins more of a shared random draw purely by size). Each full pass through
/// `serveOrder` offers every category at most one slot; `next(eligible:)` skips a
/// category that's temporarily ineligible (e.g. inside its quiet window) without
/// losing its place in line — everyone else still gets exactly one turn per cycle.
struct CategoryRotation {
    private var serveOrder: [RotationKey]
    private var index = 0
    private var lastServed: RotationKey?

    init(categories: [RotationKey], rng: inout SeededRandom) {
        serveOrder = categories.shuffled(using: &rng)
    }

    /// Returns the next category to serve given which categories currently have
    /// eligible prompts, or nil if none of them do right now. Advances the rotation.
    mutating func next(eligible eligibleCategories: Set<RotationKey>, rng: inout SeededRandom) -> RotationKey? {
        guard !serveOrder.isEmpty else { return nil }

        // Reshuffle only at a cycle boundary, and only once, before searching — never
        // mid-sweep. Mutating serveOrder while walking it could make the sweep below
        // land on the same element twice and never reach one it hasn't tried yet,
        // wrongly reporting no eligible category even though one was still waiting.
        if index == 0 {
            reshuffleForNewCycle(rng: &rng)
        }

        // Walk a fixed snapshot of serveOrder for this search, so every offset maps
        // to a distinct position — guaranteeing all categories are tried once each.
        for offset in 0..<serveOrder.count {
            let candidate = serveOrder[(index + offset) % serveOrder.count]
            if eligibleCategories.contains(candidate) {
                index = (index + offset + 1) % serveOrder.count
                lastServed = candidate
                return candidate
            }
        }
        return nil
    }

    private mutating func reshuffleForNewCycle(rng: inout SeededRandom) {
        guard serveOrder.count > 1 else { return }
        serveOrder.shuffle(using: &rng)
        // Avoid immediately re-serving the category that just closed the previous
        // cycle if the fresh shuffle happens to put it first again.
        if serveOrder.first == lastServed {
            serveOrder.swapAt(0, Int.random(in: 1..<serveOrder.count, using: &rng))
        }
    }
}

// Deterministic RNG
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 0x9e377b97f4a7c15 }
    mutating func next() -> UInt64 {
        state &+= 0x9e377b97f4a7c15
        var z = state
        z ^= z >> 30; z &*= 0xbf58476d1ce4e5b9
        z ^= z >> 27; z &*= 0x94d049bb133111eb
        z ^= z >> 31
        return z
    }
}
