import SwiftUI

final class RewardsViewModel: ObservableObject {
    private let store = PersistedStore<String>(filename: "rewards.json")

    private let defaultRewards: [String] = [
        "Nice work!",
        "Nailed it 👏",
        "You did it 💪",
        "Fire! 🔥",
        "Crushed it!",
        "You're on a roll! 🌀",
        "That's what I'm talking about! ✨",
        "From little things big things can grow. 🐾",
        "Discipline looks good on you 👊",
        "One session closer 🎯",
        "Time is an illusion.",
        "Corks punch! You've done it!",
        "They said you'd never make it, but you finally came through!",
        "Turns out you're pretty good at this.",
        "You did it.",
        "In a universe of infinite improbability, you smashed it. ♾️",
        "Tomorrow you'll thank yourself",
        "Legend 👑",
        "Another one in the bag! 🎒",
        "Keep the momentum going! 🚀"
    ]

    // All messages that have ever been shipped as defaults — used to identify custom additions
    private let allShippedDefaults: Set<String> = [
        "Nice work! 🎉", "Great focus 👏", "You did it 💪",
        "Proud of you! 🙌", "You made time for what matters ⏱",
        "Consistency is everything 🔑", "Effort compounds. Keep going! ⚡",
        "Nice work!", "Nailed it 👏", "Fire! 🔥", "Crushed it!",
        "You're on a roll! 🌀", "That's what I'm talking about! ✨",
        "From little things big things can grow. 🐾", "Discipline looks good on you 👊",
        "One session closer 🎯", "Time is an illusion.", "Corks punch! You've done it!",
        "They said you'd never make it, but you finally came through!",
        "Turns out you're pretty good at this.", "You did it.",
        "In a universe of infinite improbability, you smashed it. ♾️",
        "Tomorrow you'll thank yourself", "Legend 👑",
        "Another one in the bag! 🎒", "Keep the momentum going! 🚀"
    ]

    private let defaultsVersionKey = "rewards_defaults_version"
    private let currentDefaultsVersion = 4

    @Published var rewards: [String] = []
    @Published var lastShown: String?

    init() {
        let loaded = store.load(default: defaultRewards)
        let savedVersion = UserDefaults.standard.integer(forKey: defaultsVersionKey)

        if savedVersion < currentDefaultsVersion {
            // Keep any messages the user added themselves (not from old shipped defaults)
            let custom = loaded.filter { !allShippedDefaults.contains($0) }
            let merged = defaultRewards + custom.filter { !defaultRewards.contains($0) }
            rewards = merged
            store.save(merged)
            UserDefaults.standard.set(currentDefaultsVersion, forKey: defaultsVersionKey)
        } else {
            rewards = loaded
        }
    }

    @discardableResult
    func triggerRandomReward() -> String? {
        guard !rewards.isEmpty else { return nil }
        if let last = lastShown, rewards.count > 1 {
            let filtered = rewards.filter { $0 != last }
            lastShown = filtered.randomElement() ?? rewards.randomElement()
        } else {
            lastShown = rewards.randomElement()
        }
        return lastShown
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !rewards.contains(t) else { return }
        rewards.append(t)
        store.save(rewards)
    }

    func remove(at offsets: IndexSet) {
        rewards.remove(atOffsets: offsets)
        if let last = lastShown, !rewards.contains(last) { lastShown = nil }
        store.save(rewards)
    }
}
