// File: Done/Storage/PersistedStore.swift (or wherever you keep it)
import Foundation

/// Tiny JSON file store for arrays of Codable items.
/// Files live in the app's Documents directory; atomic writes to avoid corruption.
///
/// HARDENED:
/// - logs bundle id + container path
/// - keeps a .bak backup before overwriting
/// - quarantines corrupt files instead of silently returning default forever
/// - optional guard: prevents overwriting an existing non-empty file with an empty array
public final class PersistedStore<Item: Codable> {

    private let fileURL: URL
    private let backupURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// When true, `save([])` will NOT overwrite an existing non-empty file.
    /// This protects against common "load failed -> default [] -> auto-save []" wipes.
    private let preventEmptyOverwrite: Bool

    // MARK: - Init

    public init(filename: String, preventEmptyOverwrite: Bool = true) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = docs.appendingPathComponent(filename)
        self.backupURL = docs.appendingPathComponent(filename + ".bak")
        self.preventEmptyOverwrite = preventEmptyOverwrite

        // Encoder configuration
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        // Decoder configuration
        decoder.dateDecodingStrategy = .iso8601

        #if DEBUG
        print("📂 PersistedStore init for \(Item.self)")
        print("   → Bundle: \(Bundle.main.bundleIdentifier ?? "nil")")
        print("   → Documents dir: \(docs.path)")
        print("   → File: \(fileURL.lastPathComponent)")
        let existsAtInit = FileManager.default.fileExists(atPath: fileURL.path)
        print("   → File exists at init? \(existsAtInit)")
        if existsAtInit, let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber {
            print("   → File size at init: \(size.intValue) bytes")
        }
        #endif
    }

    // MARK: - Load

    /// Loads all items from disk.
    /// - Returns `value` if no file exists.
    /// - If decode fails, quarantines the corrupt file and returns `value`.
    public func load(default value: [Item] = []) -> [Item] {

        // No file?
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            #if DEBUG
            print("📂 PersistedStore: No file at \(fileURL.path), returning default")
            #endif
            return value
        }

        do {
            // Read bytes
            let data = try Data(contentsOf: fileURL)

            #if DEBUG
            print("📂 PersistedStore: Loaded \(data.count) bytes from \(fileURL.lastPathComponent)")
            #endif

            // Decode items
            let decoded = try decoder.decode([Item].self, from: data)

            #if DEBUG
            print("📦 PersistedStore: Decoded \(decoded.count) \(Item.self) items")
            #endif

            return decoded

        } catch {
            #if DEBUG
            print("❌ PersistedStore load error for \(fileURL.lastPathComponent): \(error)")
            #endif

            // Quarantine the corrupt file so we don't keep re-reading it
            quarantineCorruptFile(reason: "decode-failed")

            return value
        }
    }

    // MARK: - Save

    /// Saves items to disk synchronously.
    /// Uses atomic writes to avoid file corruption.
    public func save(_ items: [Item]) {

        // Optional guard to prevent accidental wipes
        if preventEmptyOverwrite, items.isEmpty {
            if let existingCount = try? existingItemCount(), existingCount > 0 {
                #if DEBUG
                print("🛡️ PersistedStore: Refusing to overwrite non-empty file with empty array (\(existingCount) existing).")
                print("   → File: \(fileURL.lastPathComponent)")
                #endif
                return
            }
        }

        do {
            // Backup current file (best-effort)
            makeBackupIfNeeded()

            // Encode + write
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: [.atomic])

            #if DEBUG
            print("💾 PersistedStore: Saved \(items.count) \(Item.self) items to \(fileURL.lastPathComponent)")
            print("📂 PersistedStore: File path: \(fileURL.path)")
            // Verify write
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            let bytes = (try? Data(contentsOf: fileURL).count) ?? -1
            print("   → Verify exists: \(exists), bytes: \(bytes)")
            #endif

        } catch {
            #if DEBUG
            print("❌ PersistedStore save error for \(fileURL.lastPathComponent): \(error)")
            #endif
        }
    }

    // MARK: - Helpers

    private func makeBackupIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }

        do {
            // Remove old backup if present
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
            try fm.copyItem(at: fileURL, to: backupURL)

            #if DEBUG
            if let size = try? fm.attributesOfItem(atPath: backupURL.path)[.size] as? NSNumber {
                print("🗄️ PersistedStore: Backup created \(backupURL.lastPathComponent) (\(size.intValue) bytes)")
            } else {
                print("🗄️ PersistedStore: Backup created \(backupURL.lastPathComponent)")
            }
            #endif
        } catch {
            #if DEBUG
            print("⚠️ PersistedStore: Backup failed: \(error)")
            #endif
        }
    }

    private func quarantineCorruptFile(reason: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }

        let ts = ISO8601DateFormatter().string(from: Date())
        let quarantined = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(reason)-\(ts)")

        do {
            try fm.moveItem(at: fileURL, to: quarantined)
            #if DEBUG
            print("🧯 PersistedStore: Quarantined corrupt file → \(quarantined.lastPathComponent)")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ PersistedStore: Failed to quarantine corrupt file: \(error)")
            #endif
        }
    }

    private func existingItemCount() throws -> Int {
        let data = try Data(contentsOf: fileURL)
        let decoded = try decoder.decode([Item].self, from: data)
        return decoded.count
    }
}

