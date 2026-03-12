//
//  mywisperApp.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import SwiftUI

@main
struct mywisperApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
