//
//  AudioLevel.swift
//  QuickRecorder
//

import Accelerate
import AVFoundation

enum AudioLevel {
    private static let target: Float = 0.063 // -24 dBFS, quiet enough that two tracks at once still fit
    private static let silent: Float = 0.000316 // -70 dBFS; below this a track holds noise, not sound
    private static let ceiling: Float = 0.7 // per-track peak headroom; two tracks peaking together still sum above it
    private static let minGain: Float = 0.125 // -18 dB
    private static let maxGain: Float = 64 // +36 dB
    private static let blockFrames = 4096 // about 85 ms at 48 kHz, short enough to follow speech

    // Gain that brings a track to the level every other track is brought to. A microphone and
    // system audio arrive at whatever level their own sources happened to use, so summing them
    // as captured leaves one of the two inaudible.
    static func matchVolume(for track: AVAssetTrack, in asset: AVAsset) -> Float {
        let (level, peak) = measure(track, in: asset)
        guard level > silent else { return 1 }
        let gain = peak > 0 ? min(target / level, ceiling / peak) : target / level
        return min(max(gain, minGain), maxGain)
    }

    // The level a track carries sound at, and how high it peaks while doing so. The level ignores
    // both extremes, so neither a stray click nor the pauses between words can stand in for a whole
    // track; the peak keeps all but the highest thousandth, which is what the gain has to fit under.
    private static func measure(_ track: AVAssetTrack, in asset: AVAsset) -> (level: Float, peak: Float) {
        let (blockRMS, blockPeak) = blockLevels(of: track, in: asset)
        guard !blockRMS.isEmpty else { return (0, 0) }
        let sorted = blockRMS.sorted()
        let floor = percentile(sorted, 0.1) // the track while nobody is speaking
        let active = sorted.drop { $0 <= floor * 4 } // 12 dB above that floor is somebody speaking
        // Continuous sound never rises above its own floor, so its overall level stands in.
        let level = active.isEmpty ? percentile(sorted, 0.9) : percentile(active, 0.5)
        return (level, percentile(blockPeak.sorted(), 0.999))
    }

    // Value that the given fraction of an already sorted collection falls below.
    private static func percentile<C: RandomAccessCollection>(_ sorted: C, _ fraction: Float) -> Float where C.Element == Float {
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.index(sorted.startIndex, offsetBy: Int(Float(sorted.count - 1) * fraction))]
    }

    // RMS and peak of every block of a track, decoded once from start to end. A block's RMS sums
    // the power of all its channels, so a mono microphone filling one channel of a stereo track
    // measures the level it carries there rather than half of it. The peak spans every channel,
    // because one gain is applied to all of them.
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
        var channels = 0 // interleaved channels per frame, known once the first buffer arrives
        var unreadable = 0
        while let sample = output.copyNextSampleBuffer() {
            do {
                try sample.withAudioBufferList { list, _ in
                    for buffer in list {
                        guard let data = buffer.mData else { continue }
                        if channels == 0 { channels = max(1, Int(buffer.mNumberChannels)) }
                        let blockLength = blockFrames * channels
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
                                blockRMS.append((squareSum / Float(blockFrames)).squareRoot())
                                blockPeak.append(peak)
                                squareSum = 0; peak = 0; filled = 0
                            }
                        }
                    }
                }
            } catch { unreadable += 1 }
        }
        // A decode that stopped early would describe a prefix of the track as if it were the whole
        // of it, and a confident wrong gain is worse than none.
        guard reader.status == .completed else {
            print("Audio level measurement failed: \(String(describing: reader.error))")
            return ([], [])
        }
        // A track shorter than one block would otherwise measure as nothing at all.
        if filled > 0 {
            blockRMS.append((squareSum / Float(filled / channels)).squareRoot())
            blockPeak.append(peak)
        }
        if unreadable > 0 { print("Audio level measurement skipped \(unreadable) unreadable buffers") }
        if blockRMS.isEmpty { print("Audio level measurement read no audio from the track") }
        return (blockRMS, blockPeak)
    }
}
