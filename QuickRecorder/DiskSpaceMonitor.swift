//
//  DiskSpaceMonitor.swift
//  QuickRecorder
//

import Foundation

class DiskSpaceMonitor {
    static let shared = DiskSpaceMonitor()

    static let startThreshold: Int64 = 2_000_000_000
    static let stopThreshold: Int64 = 500_000_000
    private static let pollInterval: TimeInterval = 5

    private var timer: Timer?
    private var watchedPath: String?

    static func availableBytes(at path: String) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    static func formatted(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func canHold(_ bytes: Int64, at path: String) -> Bool {
        guard let free = availableBytes(at: path) else { return true } // unreadable volume never blocks the user
        return free > bytes + stopThreshold
    }

    func start(watching path: String) {
        watchedPath = path
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: DiskSpaceMonitor.pollInterval, repeats: true) { [weak self] _ in
            self?.checkFreeSpace()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watchedPath = nil
    }

    private func checkFreeSpace() {
        guard let path = watchedPath,
              let free = DiskSpaceMonitor.availableBytes(at: path),
              free < DiskSpaceMonitor.stopThreshold else { return }
        stop()
        SCContext.showNotification(
            title: "Recording Stopped".local,
            body: String(format: "The output disk is almost full, only %@ left.".local, DiskSpaceMonitor.formatted(free)),
            id: "quickrecorder.error.\(UUID().uuidString)")
        SCContext.stopRecording()
    }
}
