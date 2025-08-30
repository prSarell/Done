import Foundation
import Combine

@MainActor
final class TimerNotesViewModel: ObservableObject {
    @Published private(set) var notes: [TimerNote] = []

    private let store = PersistedStore<TimerNote>(filename: "timer_notes.json")
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Load from disk
        notes = store.load()

        // Autosave whenever notes change (debounced)
        $notes
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.store.save($0) }
            .store(in: &cancellables)
    }

    // MARK: - Mutations

    func add(text: String, durationSeconds: Int) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        notes.insert(TimerNote(text: t, durationSeconds: durationSeconds), at: 0)
    }

    func delete(at offsets: IndexSet) {
        notes.remove(atOffsets: offsets)
    }

    func markComplete(id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].completedAt = Date()
    }

    func update(id: UUID, text: String? = nil, durationSeconds: Int? = nil) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        if let text { notes[i].text = text }
        if let durationSeconds { notes[i].durationSeconds = durationSeconds }
    }
}
