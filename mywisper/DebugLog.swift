//
//  DebugLog.swift
//  mywisper
//
//  Tiny rolling file log for session routing and dual-race decisions.
//  The unified log proved unreliable for retrieving this app's NSLog output,
//  and print() is invisible for Finder-launched builds — a plain file in
//  Application Support is the one channel that always works.
//

import Foundation

enum DebugLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mywisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private static let queue = DispatchQueue(label: "mywisper.debuglog")
    private static let maxBytes = 512 * 1024

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func log(_ message: String) {
        NSLog("mywisper: %@", message)
        queue.async {
            let line = "\(stamp.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
            // Roll: keep the newer half when the file outgrows the cap.
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > maxBytes,
               let contents = try? Data(contentsOf: url) {
                try? contents.suffix(maxBytes / 2).write(to: url)
            }
        }
    }
}
