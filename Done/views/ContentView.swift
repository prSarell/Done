import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            PromptsView()
                .tabItem { Label("Prompts", systemImage: "text.quote") }

            NavigationStack {
                TimerView()   // now unambiguous
            }
            .tabItem { Label("Timer", systemImage: "timer") }

            RewardsView()
                .tabItem { Label("Rewards", systemImage: "gift") }

            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(TimerNotesViewModel())
        .environmentObject(RewardsViewModel())
}

