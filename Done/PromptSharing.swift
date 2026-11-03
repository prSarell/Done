// Path: Done/PromptSharing.swift
//
// Sharing prompts between people's copies of Done!. A share is a small JSON file
// (`.doneprompts`) holding either one prompt or a whole list, with each prompt's alert
// rule. It's a one-time copy: nothing syncs afterwards, and Done/Skip history and the
// sender's Settings (quiet hours, banners slider) are never included.
//
// The file type is declared in Done-Info.plist (UTExportedTypeDeclarations +
// CFBundleDocumentTypes) so Messages / AirDrop / Files offer to open it in Done!.

import Foundation
import UIKit

// MARK: - File format

struct PromptShareFile: Codable, Equatable {
    static let currentVersion = 1
    static let fileExtension = "doneprompts"

    enum Kind: String, Codable { case prompt, list }

    struct SharedPrompt: Codable, Equatable {
        var text: String
        var rule: PromptRule?
    }

    var version: Int = PromptShareFile.currentVersion
    var kind: Kind
    /// `PromptCategory.settingsKey` of the category it was shared from.
    var category: String
    /// The list it came from — the new list's name, or the list a single prompt goes into.
    var listName: String
    var prompts: [SharedPrompt]

    var sourceCategory: PromptCategory {
        PromptCategory.allCases.first { $0.settingsKey == category } ?? .daily
    }

    // MARK: Building

    static func forList(_ list: PromptList, category: PromptCategory, rules: [String: PromptRule]) -> PromptShareFile {
        PromptShareFile(
            kind: .list,
            category: category.settingsKey,
            listName: list.name,
            prompts: list.items.map { SharedPrompt(text: $0.text, rule: rules[$0.id.uuidString]) }
        )
    }

    static func forPrompt(_ item: PromptItem, listName: String, category: PromptCategory, rules: [String: PromptRule]) -> PromptShareFile {
        PromptShareFile(
            kind: .prompt,
            category: category.settingsKey,
            listName: listName,
            prompts: [SharedPrompt(text: item.text, rule: rules[item.id.uuidString])]
        )
    }

    // MARK: Reading / writing

    enum ReadError: LocalizedError {
        case tooLarge, unreadable, newerVersion, empty

        var errorDescription: String? {
            switch self {
            case .tooLarge, .unreadable: return "This file isn't a Done! share, or it's damaged."
            case .newerVersion: return "This was shared from a newer version of Done!. Update the app to open it."
            case .empty: return "There are no prompts in this share."
            }
        }
    }

    static let maxFileBytes = 1_000_000
    static let maxPrompts = 500
    static let maxTextLength = 1_000

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes and sanitises a received file. Anything out of range is dropped rather than
    /// trusted — a share can come from anyone.
    static func decode(_ data: Data) throws -> PromptShareFile {
        guard data.count <= maxFileBytes else { throw ReadError.tooLarge }
        let file: PromptShareFile
        do { file = try JSONDecoder().decode(PromptShareFile.self, from: data) }
        catch { throw ReadError.unreadable }
        guard file.version <= currentVersion else { throw ReadError.newerVersion }

        var clean = file
        clean.listName = String(file.listName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        if clean.listName.isEmpty { clean.listName = "Shared" }
        clean.prompts = file.prompts.prefix(maxPrompts).compactMap { prompt in
            let text = String(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTextLength))
            guard !text.isEmpty else { return nil }
            return SharedPrompt(text: text, rule: prompt.rule.map(sanitised))
        }
        guard !clean.prompts.isEmpty else { throw ReadError.empty }
        return clean
    }

    private static func sanitised(_ rule: PromptRule) -> PromptRule {
        var r = rule
        func inRange(_ v: Int?, _ range: ClosedRange<Int>) -> Int? { v.flatMap { range.contains($0) ? $0 : nil } }
        r.timeHour = inRange(r.timeHour, 0...23)
        r.timeMinute = inRange(r.timeMinute, 0...59)
        if r.timeHour == nil || r.timeMinute == nil { r.timeHour = nil; r.timeMinute = nil }
        r.weekday = inRange(r.weekday, 1...7)
        r.month = inRange(r.month, 1...12)
        r.day = inRange(r.day, 1...31)
        if r.month == nil || r.day == nil { r.month = nil; r.day = nil }
        r.monthlyDay = inRange(r.monthlyDay, 1...31)
        r.windowMinutes = min(max(r.windowMinutes, 0), 24 * 60)
        return r
    }

    /// Writes the share to a fresh temporary file named after the list or prompt.
    func writeTemporaryFile() throws -> URL {
        let raw = kind == .list ? listName : (prompts.first?.text ?? listName)
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var name = raw.components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        name = String(name.prefix(40)).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Done! prompts" }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedPrompts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name).appendingPathExtension(Self.fileExtension)
        try encoded().write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Importing (pure, unit-tested)

enum PromptShareDestination: Hashable {
    /// A new list named after the share.
    case newList
    /// An existing list in the chosen category.
    case existing(UUID)
}

struct PromptShareImport {
    var lists: [PromptList]
    var rules: [String: PromptRule]
    var added: Int
    /// Prompts the destination list already has (same text, ignoring case).
    var skippedDuplicates: Int
    /// Once prompts whose date has already gone by.
    var skippedPast: Int

    /// The default "Add to" choice: a list share becomes a new list; a single prompt goes
    /// into a list with the sender's list name if there is one, else the first list.
    static func defaultDestination(for file: PromptShareFile, in lists: [PromptList]) -> PromptShareDestination {
        guard file.kind == .prompt else { return .newList }
        let match = lists.first { $0.name.caseInsensitiveCompare(file.listName) == .orderedSame } ?? lists.first
        return match.map { .existing($0.id) } ?? .newList
    }

    /// Adds the share's prompts to one category's lists. Every prompt gets a fresh ID so
    /// nothing collides with the receiver's own prompts.
    static func apply(
        _ file: PromptShareFile,
        destination: PromptShareDestination,
        lists: [PromptList],
        rules: [String: PromptRule],
        now: Date = Date()
    ) -> PromptShareImport {
        var lists = lists
        var rules = rules
        var skippedPast = 0
        var skippedDuplicates = 0

        let targetIndex: Int
        switch destination {
        case .existing(let id):
            if let idx = lists.firstIndex(where: { $0.id == id }) {
                targetIndex = idx
            } else {
                lists.append(PromptList(name: file.listName))
                targetIndex = lists.count - 1
            }
        case .newList:
            lists.append(PromptList(name: file.listName))
            targetIndex = lists.count - 1
        }

        var existingTexts = Set(lists[targetIndex].items.map { $0.text.lowercased() })
        var added = 0

        for shared in file.prompts {
            if let rule = shared.rule, rule.isOneOff, rule.date != nil, rule.shouldAutoDelete(after: now) {
                skippedPast += 1
                continue
            }
            let key = shared.text.lowercased()
            guard !existingTexts.contains(key) else {
                skippedDuplicates += 1
                continue
            }
            existingTexts.insert(key)

            let item = PromptItem(text: shared.text)
            lists[targetIndex].items.append(item)
            // Same default as adding a prompt by hand: repeat, so it survives being done.
            rules[item.id.uuidString] = shared.rule ?? PromptRule(oneOff: false)
            added += 1
        }

        return PromptShareImport(lists: lists, rules: rules, added: added,
                                 skippedDuplicates: skippedDuplicates, skippedPast: skippedPast)
    }
}

// MARK: - Receiving (Messages / AirDrop / Files → Done!)

struct PendingPromptImport: Identifiable {
    let id = UUID()
    let file: PromptShareFile
}

/// Holds a received share until the Prompts screen has loaded and can show it.
@MainActor
final class PromptShareInbox: ObservableObject {
    static let shared = PromptShareInbox()
    private init() {}

    @Published var pending: PendingPromptImport?
    @Published var errorMessage: String?

    /// Returns true if the URL was a Done! share (whether or not it could be read).
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == PromptShareFile.fileExtension else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            pending = PendingPromptImport(file: try PromptShareFile.decode(data))
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't open this share."
        }
        return true
    }
}

// MARK: - Sending

enum PromptSharePresenter {
    /// Writes the share to a temporary file and shows the iOS share sheet for it.
    @MainActor
    static func share(_ file: PromptShareFile) {
        guard let url = try? file.writeTemporaryFile() else { return }
        // Let a context menu finish dismissing before presenting over it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let top = topViewController() else { return }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = top.view
                popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            top.present(sheet, animated: true)
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
