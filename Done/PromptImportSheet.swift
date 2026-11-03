// Path: Done/PromptImportSheet.swift
//
// Shown when a shared `.doneprompts` file is opened: previews the prompts and lets the
// receiver pick the category and list before adding them. See PromptSharing.swift.

import SwiftUI

struct PromptImportSheet: View {
    let file: PromptShareFile
    /// The receiver's current lists for a category.
    let listsFor: (PromptCategory) -> [PromptList]
    let rules: [String: PromptRule]
    let onAdd: (PromptCategory, PromptShareDestination) -> Void
    let onCancel: () -> Void

    @State private var category: PromptCategory
    @State private var destination: PromptShareDestination

    init(
        file: PromptShareFile,
        listsFor: @escaping (PromptCategory) -> [PromptList],
        rules: [String: PromptRule],
        onAdd: @escaping (PromptCategory, PromptShareDestination) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.file = file
        self.listsFor = listsFor
        self.rules = rules
        self.onAdd = onAdd
        self.onCancel = onCancel
        let category = file.sourceCategory
        _category = State(initialValue: category)
        _destination = State(initialValue: PromptShareImport.defaultDestination(for: file, in: listsFor(category)))
    }

    private var lists: [PromptList] { listsFor(category) }

    /// Dry run of the import, so the counts shown match exactly what Add will do.
    private var preview: PromptShareImport {
        PromptShareImport.apply(file, destination: destination, lists: lists, rules: rules)
    }

    private var title: String {
        file.kind == .list ? file.listName : "Shared Prompt"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(file.prompts.enumerated()), id: \.offset) { _, prompt in
                        HStack {
                            Text(prompt.text).lineLimit(2)
                            Spacer()
                            Text(PromptAlertEditorModel.label(for: prompt.rule))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(file.prompts.count == 1 ? "1 prompt" : "\(file.prompts.count) prompts")
                }

                Section {
                    Picker("Category", selection: $category) {
                        ForEach(PromptCategory.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Add to", selection: $destination) {
                        Text("New list: \(file.listName)").tag(PromptShareDestination.newList)
                        ForEach(lists) { list in
                            Text(list.name).tag(PromptShareDestination.existing(list.id))
                        }
                    }
                } footer: {
                    if let note = skipNote { Text(note) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: category) { _, newCategory in
                destination = PromptShareImport.defaultDestination(for: file, in: listsFor(newCategory))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd(category, destination) }
                        .disabled(preview.added == 0)
                }
            }
        }
    }

    private var skipNote: String? {
        let p = preview
        var parts: [String] = []
        if p.skippedDuplicates > 0 {
            parts.append("\(p.skippedDuplicates) already in this list")
        }
        if p.skippedPast > 0 {
            parts.append("\(p.skippedPast) with a date that's passed")
        }
        guard !parts.isEmpty else { return nil }
        return "Skipping " + parts.joined(separator: ", ") + "."
    }
}
