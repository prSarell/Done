// Path: Done/Models/PromptModels.swift

import Foundation

// Codable-friendly model
struct PromptItem: Identifiable, Hashable, Codable {
    var id: UUID
    var text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

enum PromptCategory: String, CaseIterable, Identifiable, Codable {
    case daily = "Daily"
    case weekly = "Weekly"
    case work = "Work"
    case monthly = "Monthly"
    case yearly = "Yearly"
    case events = "Events"
    case study = "Study"
    case mentalHealth = "Health"

    var id: String { rawValue }
}

extension PromptCategory {
    /// Stable key used for Settings.bundle UserDefaults keys — independent of `rawValue`
    /// (a user-facing display string) so a future label change can't break saved settings.
    var settingsKey: String {
        switch self {
        case .daily: "daily"
        case .weekly: "weekly"
        case .work: "work"
        case .monthly: "monthly"
        case .yearly: "yearly"
        case .events: "events"
        case .study: "study"
        case .mentalHealth: "mentalhealth"
        }
    }
}

/// A named sub-list of prompts within a category (e.g. "Shopping" inside Daily).
struct PromptList: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var items: [PromptItem]

    init(id: UUID = UUID(), name: String = "General", items: [PromptItem] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

extension Array where Element == PromptList {
    var allItems: [PromptItem] { flatMap(\.items) }
}
