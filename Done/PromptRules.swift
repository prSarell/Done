// Path: Done/Storage/PromptRules.swift

import Foundation

// 1 = Sunday … 7 = Saturday (Calendar.current.weekday)
public typealias Weekday = Int

public enum PromptRecurrenceKind: String, Codable {
    case none
    case weekly
    case oneOff
    case yearly
    case monthly
}

public struct PromptRule: Codable, Equatable {
    // Optional schedule parts
    public var timeHour: Int?          // 0...23
    public var timeMinute: Int?        // 0...59
    public var weekday: Weekday?       // 1...7
    public var date: Date?             // absolute day (local)

    // Yearly recurrence (month/day, year-agnostic)
    // Example: month=3, day=31 means "31 March every year".
    public var month: Int?             // 1...12
    public var day: Int?               // 1...31

    // Monthly recurrence
    // Example: monthlyDay=15 -> "15th of every month"
    // monthlyIsLastDay == true -> "last day of every month"
    public var monthlyDay: Int?        // 1...31
    public var monthlyIsLastDay: Bool?

    // Behaviour
    // oneOff == true  -> treat as one-off
    // oneOff == false -> treat as recurring
    // oneOff == nil   -> legacy: if date != nil, treated as one-off by default
    public var oneOff: Bool?
    public var windowMinutes: Int = 120 // active window centered on time (default ±60m)

    public init(
        timeHour: Int? = nil,
        timeMinute: Int? = nil,
        weekday: Weekday? = nil,
        date: Date? = nil,
        oneOff: Bool? = nil,
        windowMinutes: Int = 120,
        month: Int? = nil,
        day: Int? = nil,
        monthlyDay: Int? = nil,
        monthlyIsLastDay: Bool? = nil
    ) {
        self.timeHour = timeHour
        self.timeMinute = timeMinute
        self.weekday = weekday
        self.date = date
        self.oneOff = oneOff
        self.windowMinutes = windowMinutes
        self.month = month
        self.day = day
        self.monthlyDay = monthlyDay
        self.monthlyIsLastDay = monthlyIsLastDay
    }

    // MARK: - Existing active-window logic

    // Is this prompt active at 'now'?
    public func isActive(at now: Date, calendar cal: Calendar = .current) -> Bool {
        // Date gate: if date set, only that calendar day
        if let d = date, !cal.isDate(now, inSameDayAs: d) { return false }

        // Weekday gate: if weekday set, only that weekday
        if let wd = weekday, cal.component(.weekday, from: now) != wd { return false }

        // Time window gate: if time set, enforce ±window/2 around that time today
        if let h = timeHour, let m = timeMinute {
            guard let center = cal.date(bySettingHour: h, minute: m, second: 0, of: now) else { return false }
            let half = TimeInterval((windowMinutes / 2) * 60)
            let start = center.addingTimeInterval(-half)
            let end   = center.addingTimeInterval(+half)
            return (now >= start && now <= end)
        }

        // If no time, and date/weekday matched, it's active for the entire day window.
        // If no fields, no restriction.
        return true
    }

    // Should be auto-removed after the assigned date?
    public func shouldAutoDelete(after now: Date, calendar cal: Calendar = .current) -> Bool {
        let treatAsOneOff = (oneOff ?? (date != nil))
        guard treatAsOneOff, let d = date else { return false }
        // Delete once the day has fully passed (midnight after 'date')
        return now > cal.startOfDay(for: d).addingTimeInterval(24 * 60 * 60)
    }
}

// MARK: - Scheduler helpers

public extension PromptRule {
    var recurrenceKind: PromptRecurrenceKind {
        let treatAsOneOff = (oneOff ?? (date != nil))

        if treatAsOneOff, date != nil {
            return .oneOff
        }
        if weekday != nil {
            return .weekly
        }
        if month != nil, day != nil {
            return .yearly
        }
        if monthlyDay != nil || (monthlyIsLastDay ?? false) {
            return .monthly
        }
        return .none
    }

    var hasSchedulingRule: Bool {
        recurrenceKind != .none
    }

    func nextTarget(after now: Date, calendar cal: Calendar = .current) -> Date? {
        switch recurrenceKind {
        case .none:
            return nil

        case .oneOff:
            guard let d = date else { return nil }
            let target = targetDate(forBaseDay: d, calendar: cal)
            return (target >= now) ? target : nil

        case .weekly:
            guard let wd = weekday else { return nil }

            let thisWeekTarget = targetForWeekday(wd, relativeTo: now, calendar: cal)
            if thisWeekTarget >= now {
                return thisWeekTarget
            }

            guard let nextWeekBase = cal.date(byAdding: .day, value: 7, to: thisWeekTarget) else {
                return nil
            }
            return nextWeekBase

        case .monthly:
            return nextMonthlyTarget(after: now, calendar: cal)

        case .yearly:
            return nextYearlyTarget(after: now, calendar: cal)
        }
    }

    func previousTarget(before now: Date, calendar cal: Calendar = .current) -> Date? {
        switch recurrenceKind {
        case .none:
            return nil

        case .oneOff:
            guard let d = date else { return nil }
            let target = targetDate(forBaseDay: d, calendar: cal)
            return (target <= now) ? target : nil

        case .weekly:
            guard let wd = weekday else { return nil }
            let thisWeekTarget = targetForWeekday(wd, relativeTo: now, calendar: cal)
            if thisWeekTarget <= now {
                return thisWeekTarget
            }
            return cal.date(byAdding: .day, value: -7, to: thisWeekTarget)

        case .monthly:
            return previousMonthlyTarget(before: now, calendar: cal)

        case .yearly:
            return previousYearlyTarget(before: now, calendar: cal)
        }
    }

    func leadInStart(for target: Date, now: Date, calendar cal: Calendar = .current) -> Date {
        switch recurrenceKind {
        case .none:
            return target

        case .weekly:
            return cal.startOfDay(for: target)

        case .monthly:
            return cal.date(byAdding: .day, value: -5, to: cal.startOfDay(for: target))
                ?? cal.startOfDay(for: target)

        case .yearly:
            return cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: target))
                ?? cal.startOfDay(for: target)

        case .oneOff:
            let daysAway = cal.dateComponents([.day], from: now, to: target).day ?? 0

            if daysAway > 60 {
                return cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: target))
                    ?? cal.startOfDay(for: target)
            } else if daysAway > 7 {
                return cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: target))
                    ?? cal.startOfDay(for: target)
            } else {
                return cal.startOfDay(for: now)
            }
        }
    }
}

// MARK: - Internal helpers

private extension PromptRule {
    func targetDate(forBaseDay baseDay: Date, calendar cal: Calendar) -> Date {
        if let h = timeHour, let m = timeMinute,
           let dated = cal.date(bySettingHour: h, minute: m, second: 0, of: baseDay) {
            return dated
        }

        let start = cal.startOfDay(for: baseDay)
        return start.addingTimeInterval((24 * 60 * 60) - 1) // end of day
    }

    func targetForWeekday(_ weekday: Int, relativeTo now: Date, calendar cal: Calendar) -> Date {
        let nowWeekday = cal.component(.weekday, from: now)
        let delta = weekday - nowWeekday
        let targetDay = cal.date(byAdding: .day, value: delta, to: now) ?? now
        return targetDate(forBaseDay: targetDay, calendar: cal)
    }

    func nextMonthlyTarget(after now: Date, calendar cal: Calendar) -> Date? {
        for offset in 0...24 {
            guard let monthDate = cal.date(byAdding: .month, value: offset, to: now) else { continue }
            if let candidate = monthlyTarget(inMonthContaining: monthDate, calendar: cal), candidate >= now {
                return candidate
            }
        }
        return nil
    }

    func previousMonthlyTarget(before now: Date, calendar cal: Calendar) -> Date? {
        for offset in 0...24 {
            guard let monthDate = cal.date(byAdding: .month, value: -offset, to: now) else { continue }
            if let candidate = monthlyTarget(inMonthContaining: monthDate, calendar: cal), candidate <= now {
                return candidate
            }
        }
        return nil
    }

    func monthlyTarget(inMonthContaining date: Date, calendar cal: Calendar) -> Date? {
        var comps = cal.dateComponents([.year, .month], from: date)

        let resolvedDay: Int
        if monthlyIsLastDay == true {
            guard let range = cal.range(of: .day, in: .month, for: date) else { return nil }
            resolvedDay = range.count
        } else if let monthlyDay {
            guard let range = cal.range(of: .day, in: .month, for: date) else { return nil }
            resolvedDay = min(monthlyDay, range.count)
        } else {
            return nil
        }

        comps.day = resolvedDay

        guard let baseDay = cal.date(from: comps) else { return nil }
        return targetDate(forBaseDay: baseDay, calendar: cal)
    }

    func nextYearlyTarget(after now: Date, calendar cal: Calendar) -> Date? {
        let currentYear = cal.component(.year, from: now)

        for year in currentYear...(currentYear + 10) {
            if let candidate = yearlyTarget(year: year, calendar: cal), candidate >= now {
                return candidate
            }
        }
        return nil
    }

    func previousYearlyTarget(before now: Date, calendar cal: Calendar) -> Date? {
        let currentYear = cal.component(.year, from: now)

        for year in stride(from: currentYear, through: currentYear - 10, by: -1) {
            if let candidate = yearlyTarget(year: year, calendar: cal), candidate <= now {
                return candidate
            }
        }
        return nil
    }

    func yearlyTarget(year: Int, calendar cal: Calendar) -> Date? {
        guard let month, let day else { return nil }

        var comps = DateComponents()
        comps.year = year
        comps.month = month

        if let firstOfMonth = cal.date(from: DateComponents(year: year, month: month)),
           let range = cal.range(of: .day, in: .month, for: firstOfMonth) {
            comps.day = min(day, range.count)
        } else {
            comps.day = day
        }

        guard let baseDay = cal.date(from: comps) else { return nil }
        return targetDate(forBaseDay: baseDay, calendar: cal)
    }
}

// Simple persistence for rules keyed by prompt text (matches your existing usage)
public enum PromptRulesStore {
    private static let filename = "prompt_rules.json"

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(filename)
    }

    public static func load() -> [String: PromptRule] {
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                #if DEBUG
                print("📂 PromptRulesStore: No file at \(fileURL.path), returning empty rules")
                #endif
                return [:]
            }

            let data = try Data(contentsOf: fileURL)

            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601

            let decoded = try dec.decode([String: PromptRule].self, from: data)

            #if DEBUG
            print("📦 PromptRulesStore: Loaded \(decoded.count) rules (\(data.count) bytes)")
            print("   → File: \(fileURL.path)")
            #endif

            return decoded

        } catch {
            #if DEBUG
            print("❌ PromptRulesStore load error: \(error)")
            print("   → File: \(fileURL.path)")
            #endif
            return [:]
        }
    }

    public static func save(_ rules: [String: PromptRule]) {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601

            let data = try enc.encode(rules)
            try data.write(to: fileURL, options: [.atomic])

            #if DEBUG
            print("💾 PromptRulesStore: Saved \(rules.count) rules (\(data.count) bytes)")
            print("   → File: \(fileURL.path)")
            #endif

        } catch {
            #if DEBUG
            print("❌ PromptRulesStore save error: \(error)")
            print("   → File: \(fileURL.path)")
            #endif
        }
    }
}
