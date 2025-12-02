import Foundation

/// Helper used by RandomPromptScheduler to decide which prompts are
/// eligible to show at a given time, based on per-prompt PromptRule.
enum PromptSelector {

    /// Returns the subset of prompts that are "active" at `time`,
    /// according to any PromptRule stored in `rules` keyed by prompt text.
    static func eligible(
        from prompts: [PromptItem],
        rules: [String: PromptRule],
        at time: Date,
        cal: Calendar = .current
    ) -> [PromptItem] {
        return prompts.filter { item in
            // Look up a rule by the prompt's text.
            // If there's no rule, treat it as always eligible.
            guard let rule = rules[item.text] else { return true }
            return rule.isActive(at: time, calendar: cal)
        }
    }
}
