import AppKit

/// Central sound playback for the app's audio cues.
///
/// Supports two sources transparently:
///   1. Built-in macOS system sounds (resolved by name via `NSSound(named:)`).
///   2. Custom sounds bundled under `Contents/Resources/Sounds/*.mp3`.
///
/// The custom library is **discovered at runtime** — drop a new `.mp3` into
/// `mywisper/Sounds/` (it's a folder reference in the Xcode project) and it shows up
/// automatically in Settings; rename a file and its display name follows. The file
/// named `error.mp3` is reserved as the dedicated failure sound and is not offered as a
/// selectable cue.
enum SoundLibrary {
    /// Reserved id (file stem) for the dedicated error sound: `Sounds/error.mp3`.
    static let errorSoundName = "error"

    /// Built-in macOS system sounds offered as cue options.
    static let systemSounds = ["Pop", "Tink", "Glass", "Purr", "Bottle", "Hero", "Ping", "Submarine"]

    /// Custom cue sounds bundled under `Resources/Sounds` (display name = file stem),
    /// excluding the reserved error sound. Sorted for a stable picker order.
    static let customSounds: [String] = {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "mp3", subdirectory: "Sounds") else {
            return []
        }
        return urls
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.lowercased() != errorSoundName }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    /// All selectable cue sounds: system sounds followed by custom bundled sounds.
    static var allCueSounds: [String] { systemSounds + customSounds }

    /// Retains the currently-playing sound so async playback isn't cut off by ARC
    /// deallocating a local `NSSound` before it finishes.
    private static var current: NSSound?

    /// Resolve a sound by name: a bundled custom mp3 takes precedence over a same-named
    /// system sound, otherwise fall back to the macOS system sound.
    static func sound(named name: String) -> NSSound? {
        if let url = Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Sounds") {
            return NSSound(contentsOf: url, byReference: true)
        }
        return NSSound(named: NSSound.Name(name))
    }

    /// Play the named cue sound (system or custom). No-op if it can't be resolved.
    static func play(named name: String) {
        guard let sound = sound(named: name) else { return }
        current = sound
        sound.play()
    }

    /// Play the dedicated error sound (`Resources/Sounds/error.mp3`). Falls back to the
    /// macOS "Basso" system sound if the file is missing.
    static func playError() {
        if let url = Bundle.main.url(forResource: errorSoundName, withExtension: "mp3", subdirectory: "Sounds"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            current = sound
            sound.play()
        } else {
            NSSound(named: NSSound.Name("Basso"))?.play()
        }
    }
}
