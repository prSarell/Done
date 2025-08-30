import Foundation

/// Tiny JSON file store for arrays of Codable items.
/// Files live in the app's Documents directory; atomic writes to avoid corruption.
public final class PersistedStore<Item: Codable> {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "PersistedStore.\(Item.self)", qos: .utility)

    public init(filename: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = docs.appendingPathComponent(filename)
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load(default value: [Item] = []) -> [Item] {
        (try? Data(contentsOf: fileURL))
            .flatMap { try? decoder.decode([Item].self, from: $0) } ?? value
    }

    public func save(_ items: [Item]) {
        queue.async {
            do {
                let data = try self.encoder.encode(items)
                try data.write(to: self.fileURL, options: .atomic)
            } catch {
                #if DEBUG
                print("PersistedStore save error:", error)
                #endif
            }
        }
    }
}
