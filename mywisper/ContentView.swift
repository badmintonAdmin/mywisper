//
//  MenuBarView.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import SwiftUI

struct MenuBarView: View {
    @ObservedObject var dictationManager: DictationManager

    var body: some View {
        Text(statusText)

        if !dictationManager.currentTranscription.isEmpty
            && !dictationManager.isRecording
            && !dictationManager.isTranscribing {
            Text(dictationManager.currentTranscription)
        }

        Divider()

        Button(dictationManager.isRecording ? "Stop Recording" : "Start Recording") {
            dictationManager.toggleRecording()
        }
        .keyboardShortcut("r")

        Text("Double-tap Fn to record")

        Divider()

        Picker("Language", selection: $dictationManager.selectedLanguage) {
            Text("English").tag("en-US")
            Text("Русский").tag("ru-RU")
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        if dictationManager.isRecording { return "● Recording..." }
        if dictationManager.isTranscribing { return "◌ Transcribing..." }
        return "● Ready"
    }
}
