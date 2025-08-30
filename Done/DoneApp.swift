import SwiftUI

@main
struct DoneApp: App {
    // Provide the notes VM app-wide so TimerView can save notes
    @StateObject private var notesVM = TimerNotesViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notesVM)
                .onAppear {
                    NotificationsManager.shared.requestAuthorization()
                }
        }
    }
}

