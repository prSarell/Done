// File: Done/Views/TimerView.swift
import SwiftUI

struct TimerView: View {
    @EnvironmentObject private var notesVM: TimerNotesViewModel   // <-- get the VM from DoneApp

    @State private var seconds: Int = 0
    @State private var running = false
    @State private var timer: Timer?

    @State private var showCompleteSheet = false
    @State private var noteText: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(formatted(seconds))
                .font(.system(.largeTitle, design: .monospaced))
                .bold()
                .padding(.top, 32)

            HStack(spacing: 12) {
                Button(running ? "Pause" : "Start") {
                    running ? pause() : start()
                }
                .buttonStyle(.borderedProminent)

                Button("Reset") { reset() }
                    .buttonStyle(.bordered)

                Button("Complete") {
                    pause()
                    noteText = ""
                    showCompleteSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(seconds == 0)
            }

            Spacer()
        }
        .padding()
        .onDisappear { timer?.invalidate() }
        .navigationTitle("Timer")
        .sheet(isPresented: $showCompleteSheet) {
            NavigationStack {
                Form {
                    Section("Optional note") {
                        TextField("What did you do / how did it go?", text: $noteText, axis: .vertical)
                            .textInputAutocapitalization(.sentences)
                            .lineLimit(3, reservesSpace: true)
                    }
                    Section("Duration") {
                        Text(formatted(seconds))
                            .font(.title3.monospacedDigit())
                    }
                }
                .navigationTitle("Save Session")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showCompleteSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                            let finalText = text.isEmpty ? "Timer session" : text
                            notesVM.add(text: finalText, durationSeconds: seconds)
                            reset()
                            showCompleteSheet = false
                        }
                        .disabled(seconds == 0)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Timer controls

    private func start() {
        running = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            seconds += 1
        }
    }

    private func pause() {
        running = false
        timer?.invalidate()
    }

    private func reset() {
        pause()
        seconds = 0
    }

    private func formatted(_ s: Int) -> String {
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }
}

#Preview {
    TimerView().environmentObject(TimerNotesViewModel())
}
