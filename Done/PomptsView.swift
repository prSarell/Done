import SwiftUI

// In-memory item model (we can swap to SwiftData later)
struct PromptItem: Identifiable, Hashable {
    let id = UUID()
    var text: String
}

enum PromptCategory: String, CaseIterable, Identifiable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case yearly = "Yearly"
    case events = "Events"
    case study = "Study"
    case mentalHealth = "Mental Health"

    var id: String { rawValue }
}

struct PromptsView: View {
    @State private var selectedCategory: PromptCategory = .daily

    // Separate lists per category (simple in-memory arrays for now)
    @State private var dailyItems:        [PromptItem] = []
    @State private var weeklyItems:       [PromptItem] = []
    @State private var monthlyItems:      [PromptItem] = []
    @State private var yearlyItems:       [PromptItem] = []
    @State private var eventsItems:       [PromptItem] = []
    @State private var studyItems:        [PromptItem] = []
    @State private var mentalHealthItems: [PromptItem] = []

    // Draft input for the single-line add row
    @State private var draftText: String = ""

    // Grid layout for two visible rows (4 on first row, remaining wrap to second)
    private let tabColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // ---- Two-line tab grid ----
                LazyVGrid(columns: tabColumns, alignment: .center, spacing: 8) {
                    ForEach(PromptCategory.allCases) { cat in
                        Button {
                            selectedCategory = cat
                        } label: {
                            Text(cat.rawValue)
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .padding(.horizontal, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(selectedCategory == cat
                                              ? Color.accentColor.opacity(0.18)
                                              : Color.secondary.opacity(0.10))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(selectedCategory == cat
                                                ? Color.accentColor
                                                : Color.secondary.opacity(0.35), lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(.horizontal)

                List {
                    // --- Single-line add row ---
                    Section(header: Text("Add \(selectedCategory.rawValue) Item")) {
                        HStack(spacing: 8) {
                            TextField(placeholderText, text: $draftText)
                                .textInputAutocapitalization(.sentences)

                            Button("Add") { addDraft() }
                                .disabled(addDisabled)
                        }
                    }

                    // --- Current list for the selected tab ---
                    Section("\(selectedCategory.rawValue) List") {
                        let binding = itemsBinding(for: selectedCategory)
                        let itemsToShow = binding.wrappedValue

                        if itemsToShow.isEmpty {
                            Text("No items yet. Add one above.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(itemsToShow) { item in
                                Text(item.text)
                                    .lineLimit(2)
                            }
                            .onDelete { indexSet in
                                deleteItems(at: indexSet, in: selectedCategory)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Prompts")
            .toolbar { EditButton() }
        }
    }

    // MARK: - Add / Delete

    private var addDisabled: Bool {
        draftTextTrimmed.isEmpty
    }

    private func addDraft() {
        guard !draftTextTrimmed.isEmpty else { return }
        let newItem = PromptItem(text: draftTextTrimmed)

        switch selectedCategory {
        case .daily:        dailyItems.append(newItem)
        case .weekly:       weeklyItems.append(newItem)
        case .monthly:      monthlyItems.append(newItem)
        case .yearly:       yearlyItems.append(newItem)
        case .events:       eventsItems.append(newItem)
        case .study:        studyItems.append(newItem)
        case .mentalHealth: mentalHealthItems.append(newItem)
        }

        draftText = ""
    }

    private func deleteItems(at indexSet: IndexSet, in category: PromptCategory) {
        switch category {
        case .daily:        dailyItems.remove(atOffsets: indexSet)
        case .weekly:       weeklyItems.remove(atOffsets: indexSet)
        case .monthly:      monthlyItems.remove(atOffsets: indexSet)
        case .yearly:       yearlyItems.remove(atOffsets: indexSet)
        case .events:       eventsItems.remove(atOffsets: indexSet)
        case .study:        studyItems.remove(atOffsets: indexSet)
        case .mentalHealth: mentalHealthItems.remove(atOffsets: indexSet)
        }
    }

    // MARK: - Helpers

    private func itemsBinding(for category: PromptCategory) -> Binding<[PromptItem]> {
        switch category {
        case .daily:        return $dailyItems
        case .weekly:       return $weeklyItems
        case .monthly:      return $monthlyItems
        case .yearly:       return $yearlyItems
        case .events:       return $eventsItems
        case .study:        return $studyItems
        case .mentalHealth: return $mentalHealthItems
        }
    }

    private var draftTextTrimmed: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var placeholderText: String {
        switch selectedCategory {
        case .daily:        return "e.g. Get Milk"
        case .weekly:       return "e.g. Team stand-up Monday 9am"
        case .monthly:      return "e.g. Dog worming tablets"
        case .yearly:       return "e.g. Renew rego"
        case .events:       return "e.g. School concert"
        case .study:        return "e.g. Read chapter 3"
        case .mentalHealth: return "e.g. 10-min walk / breathe"
        }
    }
}

#Preview { PromptsView() }

