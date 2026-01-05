//
//  PromptStatusStore.swift
//  Done
//
//  Created by Patrick Sarell on 6/1/2026.
//

// Path: Done/Storage/PromptStatusStore.swift

import Foundation

public enum PromptAction: String, Codable {
    case done
    case skipped
}

public struct PromptActionEvent: Codable, Equatable, Identifiable {
    public let id: UUID
    public let promptID: UUID
    public let promptText: String
    public let action: PromptAction
    public let occurredAt: Date

    public init(
        id: UUID = UUID(),
        promptID: UUID,
        promptText: String,
        action: PromptAction,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.promptID = promptID
        self.promptText = promptText
        self.action = action
        self.occurredAt = occurredAt
    }
}

public enum PromptStatusStore {
    private static let filename = "prompt_actions.json"

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(filename)
    }

    public static func load() -> [PromptActionEvent] {
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                #if DEBUG
                print("📂 PromptStatusStore: No file at \(fileURL.path), returning empty")
                #endif
                return []
            }

            let data = try Data(contentsOf: fileURL)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let decoded = try dec.decode([PromptActionEvent].self, from: data)

            #if DEBUG
            print("📦 PromptStatusStore: Loaded \(decoded.count) events (\(data.count) bytes)")
            #endif

            return decoded
        } catch {
            #if DEBUG
            print("❌ PromptStatusStore load error: \(error)")
            #endif
            return []
        }
    }

    public static func append(_ event: PromptActionEvent) {
        var events = load()
        events.insert(event, at: 0)
        save(events)
    }

    public static func save(_ events: [PromptActionEvent]) {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(events)
            try data.write(to: fileURL, options: [.atomic])

            #if DEBUG
            print("💾 PromptStatusStore: Saved \(events.count) events (\(data.count) bytes)")
            #endif
        } catch {
            #if DEBUG
            print("❌ PromptStatusStore save error: \(error)")
            #endif
        }
    }
}
