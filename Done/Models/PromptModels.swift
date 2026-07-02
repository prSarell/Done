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
