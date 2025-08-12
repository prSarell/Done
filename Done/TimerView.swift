import SwiftUI

struct TimerView: View {
    @State private var seconds: Int = 0
    @State private var running = false
    @State private var timer: Timer?

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
            }

            Spacer()
        }
        .padding()
        .onDisappear { timer?.invalidate() }
        .navigationTitle("Timer")
    }

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
    TimerView()
}
//
//  TimerView.swift
//  Done
//
//  Created by Patrick Sarell on 23/8/2025.
//

