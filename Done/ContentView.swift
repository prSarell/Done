import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            PromptsView()
                .tabItem { Label("Prompts", systemImage: "text.quote") }

            TimerView()
                .tabItem { Label("Timer", systemImage: "timer") }

            RewardsView()
                .tabItem { Label("Rewards", systemImage: "gift") }
        }
    }
}

#Preview {
    ContentView()
}

