// Path: Done/PromptAlertEditor.swift

import SwiftUI

/// Shared day/date/time/recurrence alert editor, used by both PromptsView and StatsView
/// so this scheduling logic exists in exactly one place. The host view owns the actual
/// `PromptRule` storage (an in-memory `@State` dict that autosaves, or a disk-backed
/// store) and supplies it via `begin(rule:onCommit:)` — this model only edits the fields
/// and hands back the resulting rule (or nil, meaning "cleared") through `onCommit`.
final class PromptAlertEditorModel: ObservableObject {
    enum Recurrence { case yearly, fortnightly, monthly }

    @Published var isPresented = false
    @Published private(set) var hasExistingRule = false

    @Published var dayEnabled = false
    @Published var dateEnabled = false
    @Published var timeEnabled = false

    @Published var weekday: Int = 2   // 1 = Sunday … 7 = Saturday, default Monday
    @Published var date: Date = Date()
    @Published var time: Date = Date().addingTimeInterval(3600)

    // false = Once, true = Repeat
    @Published var repeats: Bool = true
    @Published var recurrence: Recurrence = .yearly

    private var onCommit: ((PromptRule?) -> Void)?

    // The editor only exposes day/date/time/repeat fields, but a rule can also carry
    // importance and an active-window size that this editor doesn't show. Both `save()`
    // and `clearRule()` build a fresh `PromptRule`, so without carrying these over
    // explicitly, every edit (even just toggling Once/Repeat) silently reset a prompt's
    // "Important" flag back to false.
    private var existingIsImportant: Bool?
    private var existingWindowMinutes: Int = 120

    func begin(rule: PromptRule?, onCommit: @escaping (PromptRule?) -> Void) {
        self.onCommit = onCommit
        hasExistingRule = rule != nil
        existingIsImportant = rule?.isImportant
        existingWindowMinutes = rule?.windowMinutes ?? 120

        let now = Date()
        let cal = Calendar.current

        dayEnabled = false
        dateEnabled = false
        timeEnabled = false
        weekday = cal.component(.weekday, from: now)
        date = now
        time = now.addingTimeInterval(3600)
        repeats = true
        recurrence = .yearly

        if let rule {
            if let wd = rule.weekday {
                dayEnabled = true
                weekday = wd
            }

            if let d = rule.date {
                dateEnabled = true
                date = d
            }

            if let h = rule.timeHour, let m = rule.timeMinute {
                if let composed = cal.date(bySettingHour: h, minute: m, second: 0, of: now) {
                    timeEnabled = true
                    time = composed
                } else {
                    timeEnabled = true
                }
            }

            if let oneOff = rule.oneOff {
                repeats = !oneOff
            } else {
                // Legacy rule with no explicit oneOff — infer from recurrence structure
                switch rule.recurrenceKind {
                case .oneOff:
                    repeats = false
                default:
                    repeats = true
                }
            }

            if rule.monthlyDay != nil || (rule.monthlyIsLastDay ?? false) {
                recurrence = .monthly
                repeats = true
            } else if rule.fortnightlyAnchorDate != nil {
                recurrence = .fortnightly
                repeats = true
            } else {
                recurrence = .yearly
            }
        }

        DispatchQueue.main.async {
            self.isPresented = true
        }
    }

    func cancel() {
        isPresented = false
    }

    func clearRule() {
        // Clearing removes the schedule but must not lose the item's repeat/one-off
        // identity — committing bare `nil` here previously made the item indistinguishable
        // from a genuine one-off, so it got purged by purgeCompletedOneOffPrompts the next
        // time it was marked done, even for ordinary recurring prompts.
        var rule = PromptRule(oneOff: !repeats)
        rule.isImportant = existingIsImportant
        rule.windowMinutes = existingWindowMinutes
        onCommit?(rule)
        isPresented = false
    }

    func save() {
        guard dayEnabled || dateEnabled || timeEnabled else {
            var rule = PromptRule(oneOff: !repeats)
            rule.isImportant = existingIsImportant
            rule.windowMinutes = existingWindowMinutes
            onCommit?(rule)
            isPresented = false
            return
        }

        var rule = PromptRule()
        rule.isImportant = existingIsImportant
        rule.windowMinutes = existingWindowMinutes
        let cal = Calendar.current

        if dayEnabled { rule.weekday = weekday } else { rule.weekday = nil }

        if dateEnabled {
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            rule.date = cal.date(from: comps)
        } else {
            rule.date = nil
        }

        if timeEnabled {
            let comps = cal.dateComponents([.hour, .minute], from: time)
            rule.timeHour = comps.hour
            rule.timeMinute = comps.minute
        } else {
            rule.timeHour = nil
            rule.timeMinute = nil
        }

        rule.oneOff = !repeats

        if dateEnabled && repeats {
            switch recurrence {
            case .monthly:
                let comps = cal.dateComponents([.day], from: date)
                if let d = comps.day {
                    if let range = cal.range(of: .day, in: .month, for: date),
                       d == range.count {
                        rule.monthlyIsLastDay = true
                        rule.monthlyDay = nil
                    } else {
                        rule.monthlyDay = d
                        rule.monthlyIsLastDay = false
                    }
                }
                rule.month = nil
                rule.day = nil
                rule.fortnightlyAnchorDate = nil

            case .fortnightly:
                rule.fortnightlyAnchorDate = date
                rule.monthlyDay = nil
                rule.monthlyIsLastDay = nil
                rule.month = nil
                rule.day = nil

            case .yearly:
                let comps = cal.dateComponents([.month, .day], from: date)
                rule.month = comps.month
                rule.day = comps.day
                rule.monthlyDay = nil
                rule.monthlyIsLastDay = nil
                rule.fortnightlyAnchorDate = nil
            }
        } else {
            rule.month = nil
            rule.day = nil
            rule.monthlyDay = nil
            rule.monthlyIsLastDay = nil
            rule.fortnightlyAnchorDate = nil
        }

        onCommit?(rule)
        isPresented = false
    }

    static func label(for rule: PromptRule?) -> String {
        guard let rule else { return "Alert" }

        let hasDay = (rule.weekday != nil)
        let hasDate = (rule.date != nil)
        let hasTime = (rule.timeHour != nil && rule.timeMinute != nil)

        if !hasDay && !hasDate && !hasTime { return "Alert" }

        let cal = Calendar.current
        let dfDate = DateFormatter()
        dfDate.dateStyle = .medium
        dfDate.timeStyle = .none

        let dfTime = DateFormatter()
        dfTime.dateStyle = .none
        dfTime.timeStyle = .short

        if let date = rule.date {
            var dateToShow = date
            if hasTime,
               let h = rule.timeHour,
               let m = rule.timeMinute,
               let composed = cal.date(bySettingHour: h, minute: m, second: 0, of: date) {
                dateToShow = composed
            }

            // A date always implies a specific weekday, so show it even if the user
            // never touched the separate "Day" toggle (which is for weekly recurrence).
            let dayName = weekdayName(for: cal.component(.weekday, from: dateToShow))
            let dateStr = dfDate.string(from: dateToShow)

            if hasTime {
                let timeStr = dfTime.string(from: dateToShow)
                return "\(dayName), \(dateStr) \(timeStr)"
            } else {
                return "\(dayName), \(dateStr)"
            }
        }

        if let wd = rule.weekday {
            let dayName = weekdayName(for: wd)

            if hasTime {
                let now = Date()
                if let h = rule.timeHour,
                   let m = rule.timeMinute,
                   let t = cal.date(bySettingHour: h, minute: m, second: 0, of: now) {
                    let timeStr = dfTime.string(from: t)
                    return "\(dayName) \(timeStr)"
                } else {
                    return dayName
                }
            } else {
                return dayName
            }
        }

        if hasTime,
           let h = rule.timeHour,
           let m = rule.timeMinute {
            let now = Date()
            if let t = cal.date(bySettingHour: h, minute: m, second: 0, of: now) {
                return dfTime.string(from: t)
            } else {
                return "Time set"
            }
        }

        return "Alert"
    }

    static func weekdayName(for weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        guard weekday >= 1, weekday <= symbols.count else { return "Day" }
        return symbols[weekday - 1]
    }
}

struct PromptAlertEditorSheet: View {
    @ObservedObject var editor: PromptAlertEditorModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Day / Date / Time") {
                    Toggle("Day (weekday)", isOn: $editor.dayEnabled)

                    if editor.dayEnabled {
                        Picker("Weekday", selection: $editor.weekday) {
                            ForEach(1...7, id: \.self) { wd in
                                Text(PromptAlertEditorModel.weekdayName(for: wd)).tag(wd)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxHeight: 150)
                    }

                    Toggle("Date", isOn: $editor.dateEnabled)

                    if editor.dateEnabled {
                        DatePicker("Date", selection: $editor.date, displayedComponents: [.date])
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(maxHeight: 180)
                    }

                    Toggle("Time", isOn: $editor.timeEnabled)

                    if editor.timeEnabled {
                        DatePicker("Time", selection: $editor.time, displayedComponents: [.hourAndMinute])
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(maxHeight: 180)
                    }
                }

                Section("Repeat") {
                    Picker("Repeat", selection: $editor.repeats) {
                        Text("Once").tag(false)
                        Text("Repeat").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if editor.dateEnabled && editor.repeats {
                        Picker("Recurrence", selection: $editor.recurrence) {
                            Text("Yearly").tag(PromptAlertEditorModel.Recurrence.yearly)
                            Text("Fortnightly").tag(PromptAlertEditorModel.Recurrence.fortnightly)
                            Text("Monthly").tag(PromptAlertEditorModel.Recurrence.monthly)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    Text("You can turn on any combination of Day, Date, and Time.\n\nIf both Day and Date are on, the Date wins for scheduling. \"Yearly\" repeats on the same date each year. \"Fortnightly\" repeats every 14 days from the selected date. \"Monthly\" repeats on the same day of each month.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editor.cancel() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if editor.hasExistingRule {
                        Button("Clear") { editor.clearRule() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { editor.save() }
                }
            }
        }
    }
}
