//
//  DoneApp.swift
//  Done
//
//  Created by Patrick Sarell on 9/8/2025.
//

import SwiftUI

@main
struct DoneApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    NotificationsManager.shared.requestAuthorization()
                }
        }
    }
}
