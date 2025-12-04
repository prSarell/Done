import Foundation

/// Tiny JSON file store for arrays of Codable items.
/// Files live in the app's Documents directory; atomic writes to avoid corruption.
public final class PersistedStore<Item: Codable> {
    
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    // MARK: - Init
    
    public init(filename: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = docs.appendingPathComponent(filename)
        
        // Encoder configuration
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        
        // Decoder configuration
        decoder.dateDecodingStrategy = .iso8601
        
        #if DEBUG
        print("📂 PersistedStore init for \(Item.self)")
        print("   → Documents dir: \(docs.path)")
        print("   → File: \(fileURL.lastPathComponent)")
        let existsAtInit = FileManager.default.fileExists(atPath: fileURL.path)
        print("   → File exists at init? \(existsAtInit)")
        #endif
    }
    
    
    // MARK: - Load
    
    /// Loads all items from disk. Returns default value if:
    /// - file doesn't exist
    /// - decode fails
    /// - any error occurs
    /// Prints detailed logs in DEBUG builds.
    public func load(default value: [Item] = []) -> [Item] {
        
        do {
            // No file?
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                #if DEBUG
                print("📂 PersistedStore: No file at \(fileURL.path), returning default")
                #endif
                return value
            }
            
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
            return value
        }
    }
    
    
    // MARK: - Save
    
    /// Saves items to disk synchronously.
    /// Uses atomic writes to avoid file corruption.
    public func save(_ items: [Item]) {
        do {
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: [.atomic])
            
            #if DEBUG
            print("💾 PersistedStore: Saved \(items.count) \(Item.self) items to \(fileURL.lastPathComponent)")
            print("📂 PersistedStore: File path: \(fileURL.path)")
            #endif
            
        } catch {
            #if DEBUG
            print("❌ PersistedStore save error for \(fileURL.lastPathComponent): \(error)")
            #endif
        }
    }
}
