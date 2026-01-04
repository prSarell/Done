// Path: Done/Storage/PromptsRules.swift

import Foundation

// 1 = Sunday … 7 = Saturday (Calendar.current.weekday)
public typealias Weekday = Int

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

    // Is this prompt active at 'now'?
    // NOTE: we haven’t wired monthly/yearly logic in here yet.
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
