// Path: Done/RewardsView.swift

import SwiftUI

struct RewardsView: View {
    // Persistence
    private let store = PersistedStore<String>(filename: "rewards.json")

    // Data
    @State private var rewards: [String] = []
    @State private var draft: String = ""
    @State private var lastShown: String?

    // Debounce saving (no Combine needed)
    @State private var saveWorkItem: DispatchWorkItem?

    // Default seed (only used if no file exists yet)
    private let defaultRewards: [String] = [
        "Nice work! 🎉",
        "Great focus 👏",
        "You did it 💪"
    ]

    var body: some View {
        NavigationStack {
            List {
                addSection
                rewardsSection
                lastTriggeredSection
                triggerSection
            }
            .navigationTitle("Rewards")
            .toolbar { EditButton() }
            .task {
                // Load once when the view appears
                rewards = store.load(default: defaultRewards)
            }
            .onChange(of: rewards) { _, newRewards in
                // Debounced autosave
                scheduleSave(newRewards)
            }
        }
    }

    // MARK: - Sections

    private var addSection: some View {
        Section("Add Reward") {
            HStack {
                TextField("New reward message", text: $draft)

                Button("Add") {
                    addReward()
                }
                .disabled(draftTrimmed.isEmpty)
            }
        }
    }

    private var rewardsSection: some View {
        Section("Your Rewards") {
            if rewards.isEmpty {
                Text("No rewards yet. Add one above.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rewards, id: \.self) { r in
                    Text(r)
                }
                .onDelete { offsets in
                    rewards.remove(atOffsets: offsets)

                    // If we deleted the lastShown text, clear it
                    if let last = lastShown, !rewards.contains(last) {
                        lastShown = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var lastTriggeredSection: some View {
        if let lastShown {
            Section("Last Triggered") {
                Text(lastShown)
            }
        }
    }

    private var triggerSection: some View {
        Section {
            Button("Trigger Random Reward") {
                triggerRandomReward()
            }
            .disabled(rewards.isEmpty)
        }
    }

    // MARK: - Actions

    private var draftTrimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addReward() {
        let t = draftTrimmed
        guard !t.isEmpty else { return }

        // Optional: avoid exact duplicates
        if !rewards.contains(t) {
            rewards.append(t)
        }

        draft = ""
    }

    private func triggerRandomReward() {
        guard !rewards.isEmpty else { return }

        // Avoid immediate repeat if possible
        if let last = lastShown, rewards.count > 1 {
            let filtered = rewards.filter { $0 != last }
            lastShown = (filtered.randomElement() ?? rewards.randomElement())
        } else {
            lastShown = rewards.randomElement()
        }
    }

    // MARK: - Debounced save

    private func scheduleSave(_ newRewards: [String]) {
        saveWorkItem?.cancel()

        let work = DispatchWorkItem {
            store.save(newRewards)
            #if DEBUG
            print("💾 RewardsView: autosaved \(newRewards.count) rewards")
            #endif
        }

        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

#Preview {
    RewardsView()
}
