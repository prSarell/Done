import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            PromptsView()
                .tabItem { Label("Prompts", systemImage: "text.quote") }
                .tag(0)

            NavigationStack {
                TimerView()   // now unambiguous
            }
            .tabItem { Label("Timer", systemImage: "timer") }
            .tag(1)

            RewardsView()
                .tabItem { Label("Rewards", systemImage: "gift") }
                .tag(2)

            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(3)
        }
        // A shared prompt/list opened from Messages, AirDrop or Files: show it on Prompts.
        .onOpenURL { url in
            if PromptShareInbox.shared.receive(url) { selectedTab = 0 }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(TimerNotesViewModel())
        .environmentObject(RewardsViewModel())
}

