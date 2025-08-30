import Foundation

public struct TimerNote: Identifiable, Codable, Equatable {
    public let id: UUID
    public var text: String
    public var createdAt: Date
    public var durationSeconds: Int
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        durationSeconds: Int = 0,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.completedAt = completedAt
    }
}
