// Path: Done/Storage/PromptsStore.swift

import Foundation

/// The 8 fixed categories, each holding one or more named PromptLists.
///
/// Decodes both the current shape (`dailyLists`, `weeklyLists`, ...) and the legacy
/// pre-sub-lists shape (flat `dailyItems`, `weeklyItems`, ... arrays), wrapping legacy
/// items into a single "General" list per category. This makes the upgrade lossless and
/// idempotent no matter which reader (PromptsView, DoneApp, StatsView) hits the file first.
struct PromptsState: Codable {
    var dailyLists:        [PromptList]
    var weeklyLists:       [PromptList]
    var workLists:         [PromptList]
    var monthlyLists:      [PromptList]
    var yearlyLists:       [PromptList]
    var eventsLists:       [PromptList]
    var studyLists:        [PromptList]
    var mentalHealthLists: [PromptList]

    init(
        dailyLists:        [PromptList] = [PromptList()],
        weeklyLists:       [PromptList] = [PromptList()],
        workLists:         [PromptList] = [PromptList()],
        monthlyLists:      [PromptList] = [PromptList()],
        yearlyLists:       [PromptList] = [PromptList()],
        eventsLists:       [PromptList] = [PromptList()],
        studyLists:        [PromptList] = [PromptList()],
        mentalHealthLists: [PromptList] = [PromptList()]
    ) {
        self.dailyLists        = dailyLists
        self.weeklyLists       = weeklyLists
        self.workLists         = workLists
        self.monthlyLists      = monthlyLists
        self.yearlyLists       = yearlyLists
        self.eventsLists       = eventsLists
        self.studyLists        = studyLists
        self.mentalHealthLists = mentalHealthLists
    }

    private enum CodingKeys: String, CodingKey {
        case dailyLists, weeklyLists, workLists, monthlyLists, yearlyLists, eventsLists, studyLists, mentalHealthLists
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case dailyItems, weeklyItems, workItems, monthlyItems, yearlyItems, eventsItems, studyItems, mentalHealthItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.dailyLists) {
            dailyLists        = try container.decodeIfPresent([PromptList].self, forKey: .dailyLists) ?? [PromptList()]
            weeklyLists       = try container.decodeIfPresent([PromptList].self, forKey: .weeklyLists) ?? [PromptList()]
            workLists         = try container.decodeIfPresent([PromptList].self, forKey: .workLists) ?? [PromptList()]
            monthlyLists      = try container.decodeIfPresent([PromptList].self, forKey: .monthlyLists) ?? [PromptList()]
            yearlyLists       = try container.decodeIfPresent([PromptList].self, forKey: .yearlyLists) ?? [PromptList()]
            eventsLists       = try container.decodeIfPresent([PromptList].self, forKey: .eventsLists) ?? [PromptList()]
            studyLists        = try container.decodeIfPresent([PromptList].self, forKey: .studyLists) ?? [PromptList()]
            mentalHealthLists = try container.decodeIfPresent([PromptList].self, forKey: .mentalHealthLists) ?? [PromptList()]
            return
        }

        // Legacy shape: flat [PromptItem] per category. Wrap into one default "General" list.
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        func wrap(_ items: [PromptItem]) -> [PromptList] {
            items.isEmpty ? [PromptList()] : [PromptList(items: items)]
        }
        dailyLists        = wrap(try legacy.decodeIfPresent([PromptItem].self, forKey: .dailyItems) ?? [])
        weeklyLists       = wrap(try legacy.decodeIfPresent([PromptItem].self, forKey: .weeklyItems) ?? [])
        workLists         = wrap(try legacy.decodeIfPresent([PromptItem].self, forKey: .workItems) ?? [])
        monthlyLists      = wrap(try legacy.decodeIfPresent([PromptItem].self, forKey: .monthlyItems) ?? [])
        yearlyLists       = wrap(try legacy.decodeIfPresent([PromptItem].self, forKey: .yearlyItems) ?? [])
        eventsLists       = wrap(try legacy.decodeIfPresent([PromptItem].self, forKey: .eventsItems) ?? [])
        studyLists        = wrap(try legacy.decodeIfPresent([PromptItem].self, forKey: .studyItems) ?? [])
        mentalHealthLists = wrap(try legacy.decodeIfPresent([PromptItem].self, forKey: .mentalHealthItems) ?? [])
    }
}

extension PromptsState {
    var allCategoryLists: [[PromptList]] {
        [dailyLists, weeklyLists, workLists, monthlyLists, yearlyLists, eventsLists, studyLists, mentalHealthLists]
    }

    var allItems: [PromptItem] {
        allCategoryLists.flatMap { $0.allItems }
    }
}

/// Single source of truth for reading/writing prompts.json, replacing three previously
/// duplicated implementations (PromptsView, DoneApp, StatsView each had their own).
enum PromptsStore {
    private static let filename = "prompts.json"

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    private static var backupURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename + ".bak")
    }

    /// Safe loader:
    /// - Missing file → default `PromptsState()` (first run — one empty "General" list per category).
    /// - Decode failure → nil, so callers can avoid overwriting the file with empty/default state.
    static func loadSafe() -> PromptsState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PromptsState()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return try dec.decode(PromptsState.self, from: data)
        } catch {
            #if DEBUG
            print("❌ PromptsStore load error: \(error)")
            print("   → File: \(fileURL.path)")
            #endif
            return nil
        }
    }

    /// Same as `loadSafe()`, off the main thread, for use from a SwiftUI `.task`.
    static func loadSafeAsync() async -> PromptsState? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: loadSafe())
            }
        }
    }

    /// Loads prompts and migrates any legacy text-keyed alert rules to id-based keys in one
    /// step, so every call site gets the rules migration for free instead of re-triggering it.
    static func loadSafeWithRules() -> (state: PromptsState?, rules: [String: PromptRule]) {
        let state = loadSafe()
        let rules = PromptRulesStore.loadMigratingIfNeeded(using: state?.allItems ?? [])
        return (state, rules)
    }

    static func loadSafeWithRulesAsync() async -> (state: PromptsState?, rules: [String: PromptRule]) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: loadSafeWithRules())
            }
        }
    }

    static func save(_ state: PromptsState) {
        do {
            makeBackupIfNeeded()
            let enc = JSONEncoder()
            enc.outputFormatting = [.withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(state)
            try data.write(to: fileURL, options: [.atomic])
            #if DEBUG
            print("💾 PromptsStore: saved prompts.json (\(data.count) bytes)")
            #endif
        } catch {
            #if DEBUG
            print("❌ PromptsStore save error: \(error)")
            print("   → File: \(fileURL.path)")
            #endif
        }
    }

    private static func makeBackupIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
            try fm.copyItem(at: fileURL, to: backupURL)
        } catch {
            #if DEBUG
            print("⚠️ PromptsStore: backup failed: \(error)")
            #endif
        }
    }
}
