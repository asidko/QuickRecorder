//
//  DiskSpace.swift
//  QuickRecorder
//

import Foundation

enum DiskSpace {
    static let startThreshold: Int64 = 2_000_000_000
    static let stopThreshold: Int64 = 500_000_000
    private static let pollInterval: TimeInterval = 5

    private static var timer: Timer?

    static func availableBytes(at path: String) -> Int64? {
        guard let values = try? path.url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else { return nil }
        return Int64(capacity)
    }

    static func fileSize(at path: String) -> Int64? {
        guard let values = try? path.url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    static func formatted(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func startMonitoring(_ path: String, onExhausted: @escaping (String) -> Void) {
        stopMonitoring()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            guard let free = availableBytes(at: path), free < stopThreshold else { return }
            stopMonitoring()
            onExhausted(String(format: "The output disk is almost full, only %@ left.".local, formatted(free)))
        }
        timer?.tolerance = 1
    }

    static func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
}
