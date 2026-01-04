// File: Done/ViewModels/TimerNotesViewModel.swift
import Foundation
import Combine

@MainActor
final class TimerNotesViewModel: ObservableObject {

    @Published private(set) var notes: [TimerNote] = [] {
        didSet {
            #if DEBUG
            print("📝 TimerNotesViewModel: notes changed, count = \(notes.count)")
            #endif
        }
    }

    private let store = PersistedStore<TimerNote>(filename: "timer_notes.json")
    private var cancellables = Set<AnyCancellable>()
    private var hasFinishedInitialLoad = false

    init() {
        #if DEBUG
        print("🟡 TimerNotesViewModel init: loading notes…")
        print("   → Bundle: \(Bundle.main.bundleIdentifier ?? "nil")")
        #endif

        // Load from disk (do NOT trigger autosave from this)
        notes = store.load()

        hasFinishedInitialLoad = true

        #if DEBUG
        print("🟢 TimerNotesViewModel init: loaded \(notes.count) notes")
        #endif

        // Autosave whenever notes change (debounced)
        $notes
            .dropFirst() // ignore initial assignment to @Published
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] newNotes in
                guard let self else { return }
                guard self.hasFinishedInitialLoad else { return }

                #if DEBUG
                print("💾 TimerNotesViewModel autosave triggered, count = \(newNotes.count)")
                #endif

                self.store.save(newNotes)
            }
            .store(in: &cancellables)
    }

    // MARK: - Debug / Utilities

    /// Optional: force an immediate save (useful when debugging persistence)
    func saveNow() {
        #if DEBUG
        print("💾 TimerNotesViewModel.saveNow() called, count = \(notes.count)")
        #endif
        store.save(notes)
    }

    // MARK: - Mutations

    func add(text: String, durationSeconds: Int) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        #if DEBUG
        print("➕ TimerNotesViewModel.add(text:durationSeconds:)")
        #endif

        notes.insert(TimerNote(text: t, durationSeconds: durationSeconds), at: 0)
    }

    func delete(at offsets: IndexSet) {
        #if DEBUG
        print("🗑 TimerNotesViewModel.delete(at:), offsets = \(Array(offsets))")
        #endif

        notes.remove(atOffsets: offsets)
    }

    func markComplete(id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }

        #if DEBUG
        print("✅ TimerNotesViewModel.markComplete(id:), index = \(i)")
        #endif

        notes[i].completedAt = Date()
    }

    func update(id: UUID, text: String? = nil, durationSeconds: Int? = nil) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }

        #if DEBUG
        print("✏️ TimerNotesViewModel.update(id:), index = \(i), hasText = \(text != nil), hasDuration = \(durationSeconds != nil)")
        #endif

        if let text {
            notes[i].text = text
        }
        if let durationSeconds {
            notes[i].durationSeconds = durationSeconds
        }
    }
}
