import Foundation

struct PromptHistoryEntry: Codable { let text: String; let when: Date }

enum PromptSelector {
    /// Filter prompts that are eligible at the given moment according to rules
    static func eligible(from prompts: [PromptItem],
                         rules: [String: PromptRule],
                         at moment: Date,
                         cal: Calendar = .current) -> [PromptItem] {
        prompts.filter { item in
            guard let rule = rules[item.text] else { return true } // no rule -> eligible
            return rule.isActive(at: moment, calendar: cal)
        }
    }

    /// Pick one, avoiding immediate repeat when possible
    static func pickOne(from eligible: [PromptItem],
                        avoiding lastText: String?) -> PromptItem? {
        guard !eligible.isEmpty else { return nil }
        if let lastText, eligible.count > 1 {
            let pool = eligible.filter { $0.text != lastText }
            return (pool.isEmpty ? eligible : pool).randomElement()
        }
        return eligible.randomElement()
    }
}
