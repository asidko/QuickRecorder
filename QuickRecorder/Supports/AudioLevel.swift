//
//  AudioLevel.swift
//  QuickRecorder
//

import Accelerate
import AVFoundation

enum AudioLevel {
    private static let target: Float = 0.063 // -24 dBFS, quiet enough that two tracks at once still fit
    private static let silent: Float = 0.001 // -60 dBFS; below this a track holds noise, not sound
    private static let ceiling: Float = 0.7 // headroom left for the other track and for encoder overshoot
    private static let minGain: Float = 0.125 // -18 dB
    private static let maxGain: Float = 32 // +30 dB
    private static let blockLength = 8192 // about 85 ms of 48 kHz stereo, short enough to follow speech

    // Gain that brings a track to the level every other track is brought to. A microphone and
    // system audio arrive at whatever level their own sources happened to use, so summing them
    // as captured leaves one of the two inaudible.
    static func matchVolume(for track: AVAssetTrack, in asset: AVAsset) -> Float {
        let (level, peak) = measure(track, in: asset)
        guard level > silent else { return 1 }
        let gain = peak > 0 ? min(target / level, ceiling / peak) : target / level
        return min(max(gain, minGain), maxGain)
    }

    // The level a track carries sound at, and how high it peaks while doing so. Both ignore the
    // extremes, so neither a stray click nor the pauses between words can stand in for the level
    // of a whole track.
    private static func measure(_ track: AVAssetTrack, in asset: AVAsset) -> (level: Float, peak: Float) {
        let (blockRMS, blockPeak) = blockLevels(of: track, in: asset)
        guard !blockRMS.isEmpty else { return (0, 0) }
        let sorted = blockRMS.sorted()
        let floor = percentile(sorted, 0.1) // the track while nobody is speaking
        let active = sorted.drop { $0 <= floor * 4 } // 12 dB above that floor is somebody speaking
        // Continuous sound never rises above its own floor, so its overall level stands in.
        let level = active.isEmpty ? percentile(sorted, 0.9) : percentile(active, 0.5)
        return (level, percentile(blockPeak.sorted(), 0.99))
    }

    // Value that the given fraction of an already sorted collection falls below.
    private static func percentile<C: RandomAccessCollection>(_ sorted: C, _ fraction: Float) -> Float where C.Element == Float {
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.index(sorted.startIndex, offsetBy: Int(Float(sorted.count - 1) * fraction))]
    }

    // RMS and peak of every block of a track, decoded once from start to end.
    private static func blockLevels(of track: AVAssetTrack, in asset: AVAsset) -> ([Float], [Float]) {
        guard let reader = try? AVAssetReader(asset: asset) else { return ([], []) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { return ([], []) }
        reader.add(output)
        guard reader.startReading() else { return ([], []) }

        var blockRMS = [Float]()
        var blockPeak = [Float]()
        var squareSum: Float = 0
        var peak: Float = 0
        var filled = 0 // samples already in the block being accumulated
        while let sample = output.copyNextSampleBuffer() {
            try? sample.withAudioBufferList { list, _ in
                for buffer in list {
                    guard let data = buffer.mData else { continue }
                    let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                                      count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                    var offset = 0
                    while offset < samples.count {
                        let chunk = UnsafeBufferPointer(rebasing: samples[offset ..< offset + min(blockLength - filled, samples.count - offset)])
                        squareSum += vDSP.sumOfSquares(chunk)
                        peak = max(peak, vDSP.maximumMagnitude(chunk))
                        offset += chunk.count
                        filled += chunk.count
                        if filled == blockLength {
                            blockRMS.append((squareSum / Float(blockLength)).squareRoot())
                            blockPeak.append(peak)
                            squareSum = 0; peak = 0; filled = 0
                        }
                    }
                }
            }
        }
        reader.cancelReading()
        return (blockRMS, blockPeak)
    }
}
