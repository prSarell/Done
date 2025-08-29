//
//  rewardsView.swift
//  Done
//
//  Created by Patrick Sarell on 23/8/2025.
//

import SwiftUI

struct RewardsView: View {
    @State private var rewards: [String] = [
        "Nice work! 🎉",
        "Great focus 👏",
        "You did it 💪"
    ]
    @State private var draft = ""
    @State private var lastShown: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Add Reward") {
                    HStack {
                        TextField("New reward message", text: $draft)
                        Button("Add") {
                            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            rewards.append(t)
                            draft = ""
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("Your Rewards") {
                    ForEach(rewards, id: \.self) { r in Text(r) }
                        .onDelete { rewards.remove(atOffsets: $0) }
                }

                if let lastShown {
                    Section("Last Triggered") { Text(lastShown) }
                }

                Section {
                    Button("Trigger Random Reward") {
                        if let r = rewards.randomElement() {
                            lastShown = r
                        }
                    }
                }
            }
            .navigationTitle("Rewards")
            .toolbar { EditButton() }
        }
    }
}

#Preview {
    RewardsView()
}

