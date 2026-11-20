//
//  LegacyMigration.swift
//  MyWhisper
//
//  One-time upgrade from the misspelled "mywisper" identity (v1.6.5 and earlier,
//  bundle ID com.barssoft.mywisper) to MyWhisper (com.barssoft.mywhisper).
//
//  macOS treats a new bundle ID as a brand-new app, so without this the user would lose
//  their settings, history, pending recordings and gigabytes of downloaded models. Runs
//  from MyWhisperApp.init — BEFORE SettingsManager, DebugLog or any store touches disk —
//  and only once (guarded by a flag in the new defaults domain).
//
//  What can't be migrated: macOS privacy grants (Microphone, Accessibility, Input
//  Monitoring) and Launch-at-Login are tied to the app identity and must be granted again.
//

import AppKit

enum LegacyMigration {
    static let legacyBundleID = "com.barssoft.mywisper"
    private static let legacyFolderName = "mywisper"
    private static let newFolderName = "MyWhisper"
    private static let doneKey = "legacyMywisperMigrationDone"

    /// What happened, for the debug log (written after the folders are in place).
    private static var report: [String] = []

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        quitLegacyApp()
        migrateApplicationSupport()
        migrateDefaults(into: defaults)
        trashLegacyApp()

        defaults.set(true, forKey: doneKey)
        if !report.isEmpty {
            DebugLog.log("migration from mywisper: " + report.joined(separator: "; "))
        }
    }

    // MARK: - Running copy

    /// The old app would fight us for the hotkeys and the menu bar.
    private static func quitLegacyApp() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID)
        for app in running {
            app.terminate()
        }
        if !running.isEmpty {
            report.append("quit \(running.count) running legacy instance(s)")
        }
    }

    // MARK: - Application Support (models, history, pending recordings)

    private static func migrateApplicationSupport() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = appSupport.appendingPathComponent(legacyFolderName, isDirectory: true)
        let new = appSupport.appendingPathComponent(newFolderName, isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { return }

        if !fm.fileExists(atPath: new.path) {
            // Same volume → an instant rename, even for gigabytes of models.
            do {
                try fm.moveItem(at: old, to: new)
                report.append("moved Application Support folder")
            } catch {
                report.append("could not move Application Support folder: \(error.localizedDescription)")
            }
            return
        }

        // The new folder already exists: merge item by item, never overwrite.
        mergeContents(of: old, into: new)
        if let leftovers = try? fm.contentsOfDirectory(atPath: old.path), leftovers.isEmpty {
            try? fm.removeItem(at: old)
        }
        report.append("merged Application Support folder")
    }

    private static func mergeContents(of source: URL, into destination: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: item, to: target)
            } else if isDirectory {
                mergeContents(of: item, into: target)
                if let rest = try? fm.contentsOfDirectory(atPath: item.path), rest.isEmpty {
                    try? fm.removeItem(at: item)
                }
            }
        }
    }

    // MARK: - Settings (UserDefaults)

    private static func migrateDefaults(into defaults: UserDefaults) {
        guard let legacy = defaults.persistentDomain(forName: legacyBundleID), !legacy.isEmpty else { return }
        let current = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]

        var copied = 0
        for (key, value) in legacy where current[key] == nil {
            defaults.set(rewritePaths(in: value), forKey: key)
            copied += 1
        }
        report.append("copied \(copied) setting(s)")
    }

    /// Stored absolute paths (e.g. the selected Whisper model) point into the old folders.
    private static func rewritePaths(in value: Any) -> Any {
        switch value {
        case let string as String:
            return string
                .replacingOccurrences(of: "/Application Support/\(legacyFolderName)/", with: "/Application Support/\(newFolderName)/")
                .replacingOccurrences(of: "/\(legacyFolderName).app/", with: "/\(newFolderName).app/")
        case let array as [Any]:
            return array.map(rewritePaths(in:))
        case let dictionary as [String: Any]:
            return dictionary.mapValues(rewritePaths(in:))
        default:
            return value
        }
    }

    // MARK: - Old app bundle

    /// Move the old mywisper.app to the Trash so the user doesn't end up with two dictation
    /// apps. Only touches the standard Applications folders, never build/ copies.
    private static func trashLegacyApp() {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/\(legacyFolderName).app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(legacyFolderName).app")
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            guard url.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
                  Bundle(url: url)?.bundleIdentifier == legacyBundleID else { continue }
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                report.append("moved \(url.path) to Trash")
            } catch {
                report.append("could not trash \(url.path): \(error.localizedDescription)")
            }
        }
    }
}
