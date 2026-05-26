// File: Done/Views/TimerView.swift
import SwiftUI
import UIKit

enum TimerMode: String, CaseIterable {
    case focus = "Focus"
    case personalBest = "Personal Best"
}

fileprivate enum TimerPhase {
    case setting, running, paused
}

struct TimerView: View {
    @EnvironmentObject private var notesVM: TimerNotesViewModel
    @EnvironmentObject private var rewardsVM: RewardsViewModel

    @State private var mode: TimerMode = .focus
    @State private var phase: TimerPhase = .setting
    @State private var targetSeconds: Int = 0
    @State private var elapsedSeconds: Int = 0
    @State private var timerHandle: Timer?
    @State private var showCompleteSheet = false
    @State private var noteText = ""
    @State private var rewardMessage: String? = nil
    @State private var rewardColor: Color = .blue

    private static let rewardColors: [Color] = [
        .blue, .purple, .orange, .green, .teal, .indigo, .mint, .cyan, .pink
    ]

    private var isOverTarget: Bool {
        targetSeconds > 0 && elapsedSeconds >= targetSeconds
    }

    private var arcColor: Color {
        isOverTarget ? .green : .accentColor
    }

    var body: some View {
        ZStack {
            VStack(spacing: 28) {
                Picker("Mode", selection: $mode) {
                    ForEach(TimerMode.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .disabled(phase != .setting)

                DialView(
                    targetSeconds: $targetSeconds,
                    elapsedSeconds: elapsedSeconds,
                    phase: phase,
                    arcColor: arcColor,
                    modeLabel: mode.rawValue
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 40)

                controlButtons
                    .padding(.horizontal, 24)

                Spacer()
            }
            .padding(.top, 16)

            if let message = rewardMessage {
                RewardOverlay(message: message, color: rewardColor) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        rewardMessage = nil
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: rewardMessage != nil)
        .navigationTitle("Timer")
        .onDisappear {
            timerHandle?.invalidate()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $showCompleteSheet) { completeSheet }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlButtons: some View {
        switch phase {
        case .setting:
            Button("Start") { startTimer() }
                .buttonStyle(.borderedProminent)
                .disabled(targetSeconds == 0)

        case .running:
            HStack(spacing: 16) {
                Button("Pause") { pauseTimer() }
                    .buttonStyle(.bordered)

                Button("Complete") {
                    pauseTimer()
                    noteText = ""
                    showCompleteSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

        case .paused:
            HStack(spacing: 16) {
                Button("Reset") { resetTimer() }
                    .buttonStyle(.bordered)
                    .tint(.red)

                Button("Resume") { startTimer() }
                    .buttonStyle(.borderedProminent)

                Button("Complete") {
                    noteText = ""
                    showCompleteSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
    }

    // MARK: - Complete sheet

    private var completeSheet: some View {
        NavigationStack {
            Form {
                Section("Optional note") {
                    TextField("What did you do / how did it go?", text: $noteText, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(3, reservesSpace: true)
                }
                Section("Duration") {
                    Text(formatted(elapsedSeconds))
                        .font(.title3.monospacedDigit())
                }
                if targetSeconds > 0 {
                    Section("Target") {
                        Text(formatted(targetSeconds))
                            .font(.title3.monospacedDigit())
                    }
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
                        notesVM.add(
                            text: text.isEmpty ? "Timer session" : text,
                            durationSeconds: elapsedSeconds
                        )

                        let shouldReward: Bool
                        switch mode {
                        case .personalBest:
                            // Beat the target
                            shouldReward = targetSeconds > 0 && elapsedSeconds < targetSeconds
                        case .focus:
                            // Went longer than planned
                            shouldReward = targetSeconds > 0 && elapsedSeconds > targetSeconds
                        }

                        resetTimer()
                        showCompleteSheet = false

                        if shouldReward {
                            let msg = rewardsVM.triggerRandomReward()
                            rewardColor = Self.rewardColors.randomElement() ?? .blue
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                rewardMessage = msg
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Timer control

    private func startTimer() {
        phase = .running
        UIApplication.shared.isIdleTimerDisabled = true
        timerHandle?.invalidate()
        timerHandle = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsedSeconds += 1
        }
    }

    private func pauseTimer() {
        phase = .paused
        UIApplication.shared.isIdleTimerDisabled = false
        timerHandle?.invalidate()
    }

    private func resetTimer() {
        timerHandle?.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .setting
        elapsedSeconds = 0
        targetSeconds = 0
    }

    private func formatted(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }
}

// MARK: - Reward overlay

private struct RewardOverlay: View {
    let message: String
    let color: Color
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            Text(message)
                .font(.title.bold())
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .padding(32)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .padding(40)
        }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                dismiss()
            }
        }
    }
}

// MARK: - Dial

private struct DialView: View {
    @Binding var targetSeconds: Int
    var elapsedSeconds: Int
    var phase: TimerPhase
    var arcColor: Color
    var modeLabel: String

    @State private var lastAngle: Double? = nil
    @State private var lastHapticMinute: Int = -1

    private let strokeWidth: CGFloat = 14

    private var displaySeconds: Int {
        phase == .setting ? targetSeconds : elapsedSeconds
    }

    // Completed full hours while in setting mode (drives the dimmed background ring)
    private var completedHours: Int {
        phase == .setting ? targetSeconds / 3600 : 0
    }

    private var progress: Double {
        switch phase {
        case .setting:
            guard targetSeconds > 0 else { return 0 }
            let remainder = targetSeconds % 3600
            // Keep arc full at the top of each hour rather than snapping back to zero
            return remainder == 0 ? 1.0 : Double(remainder) / 3600.0
        case .running, .paused:
            guard targetSeconds > 0 else { return 0 }
            return min(Double(elapsedSeconds) / Double(targetSeconds), 1.0)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let sz = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: sz / 2, y: sz / 2)

            ZStack {
                // Background track
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: strokeWidth)

                // Dimmed full ring for each completed hour — persists so colour never drops out
                if completedHours > 0 {
                    Circle()
                        .stroke(arcColor.opacity(0.25), lineWidth: strokeWidth)
                }

                // Progress arc
                if progress > 0 {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(arcColor, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(phase == .running ? .linear(duration: 1) : .none, value: progress)
                }

                // Tick marks
                Canvas { ctx, size in
                    let r = size.width / 2
                    let outerR = r - strokeWidth / 2 - 2
                    for i in 0..<60 {
                        let angle = Double(i) / 60.0 * 2 * .pi - .pi / 2
                        let major = i % 5 == 0
                        let len: CGFloat = major ? 10 : 5
                        let lw: CGFloat = major ? 2 : 1
                        var p = Path()
                        p.move(to: CGPoint(x: r + CGFloat(cos(angle)) * outerR,
                                           y: r + CGFloat(sin(angle)) * outerR))
                        p.addLine(to: CGPoint(x: r + CGFloat(cos(angle)) * (outerR - len),
                                              y: r + CGFloat(sin(angle)) * (outerR - len)))
                        ctx.stroke(p, with: .color(.gray.opacity(0.4)), lineWidth: lw)
                    }
                }

                // Center display
                VStack(spacing: 4) {
                    Text(formatted(displaySeconds))
                        .font(.system(.largeTitle, design: .monospaced).bold())

                    Text(modeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: sz, height: sz)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .contentShape(Circle().path(in: CGRect(x: 0, y: 0, width: sz, height: sz)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard phase == .setting else { return }
                        // value.location is in the GeometryReader's coordinate space;
                        // shift to the ZStack's local space (centered in geo)
                        let local = CGPoint(
                            x: value.location.x - (geo.size.width - sz) / 2,
                            y: value.location.y - (geo.size.height - sz) / 2
                        )
                        let angle = Self.polarAngle(from: local, center: center)
                        defer { lastAngle = angle }
                        guard let last = lastAngle else {
                            lastHapticMinute = targetSeconds / 60
                            return
                        }
                        var delta = angle - last
                        if delta > .pi { delta -= 2 * .pi }
                        if delta < -.pi { delta += 2 * .pi }
                        // clockwise (positive delta) adds time; 1 rotation = 1 hour
                        let added = Int(delta * 3600 / (2 * .pi))
                        targetSeconds = max(0, targetSeconds + added)
                        // Haptic click on each minute boundary
                        let currentMinute = targetSeconds / 60
                        if currentMinute != lastHapticMinute {
                            UISelectionFeedbackGenerator().selectionChanged()
                            lastHapticMinute = currentMinute
                        }
                    }
                    .onEnded { _ in
                        guard phase == .setting else { return }
                        targetSeconds = (targetSeconds / 60) * 60
                        lastAngle = nil
                        lastHapticMinute = -1
                    }
            )
        }
    }

    private static func polarAngle(from point: CGPoint, center: CGPoint) -> Double {
        let dx = point.x - center.x, dy = point.y - center.y
        var a = atan2(dy, dx)
        if a < 0 { a += 2 * .pi }
        return a
    }

    private func formatted(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }
}


#Preview {
    NavigationStack {
        TimerView()
            .environmentObject(TimerNotesViewModel())
            .environmentObject(RewardsViewModel())
    }
}
