// Path: Done/RewardsView.swift

import SwiftUI

struct RewardsView: View {
    @EnvironmentObject private var rewardsVM: RewardsViewModel
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            List {
                addSection
                rewardsSection
                lastTriggeredSection
            }
            .navigationTitle("Rewards")
            .toolbar { EditButton() }
        }
    }

    // MARK: - Sections

    private var addSection: some View {
        Section("Add Reward") {
            HStack {
                TextField("New reward message", text: $draft)

                Button("Add") {
                    rewardsVM.add(draft)
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var rewardsSection: some View {
        Section("Your Rewards") {
            if rewardsVM.rewards.isEmpty {
                Text("No rewards yet. Add one above.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rewardsVM.rewards, id: \.self) { r in
                    Text(r)
                }
                .onDelete { offsets in
                    rewardsVM.remove(at: offsets)
                }
            }
        }
    }

    @ViewBuilder
    private var lastTriggeredSection: some View {
        if let lastShown = rewardsVM.lastShown {
            Section("Last Triggered") {
                Text(lastShown)
            }
        }
    }

}

#Preview {
    RewardsView()
        .environmentObject(RewardsViewModel())
}
