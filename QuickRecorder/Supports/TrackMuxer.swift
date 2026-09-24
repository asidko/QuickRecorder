//
//  TrackMuxer.swift
//  QuickRecorder
//

import AVFoundation

// Copies a video track and a set of audio tracks into a new file without re-encoding. The audio
// tracks form one alternate group, so a player offers them as a choice instead of playing them
// together; the first one is the group's default and the only one enabled.
enum TrackMuxer {
    struct AudioTrack {
        let track: AVAssetTrack
        let asset: AVAsset // the track's own asset, which the track holds only weakly
        let title: String // name a player lists the track under
    }

    // One source track feeding one writer input.
    private struct Lane {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
    }

    static func write(video: AVAssetTrack, in videoAsset: AVAsset, audio: [AudioTrack], to url: URL, fileType: AVFileType, completion: @escaping (Error?) -> Void) {
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
            // Every track stops where the video does, so no audio plays past the last frame.
            let range = CMTimeRange(start: .zero, end: video.timeRange.end)
            let videoLane = try lane(for: video, in: videoAsset, writer: writer, range: range)
            let audioLanes = try audio.map { item in
                let lane = try lane(for: item.track, in: item.asset, writer: writer, range: range)
                lane.input.metadata = trackName(item.title)
                return lane
            }
            let group = AVAssetWriterInputGroup(inputs: audioLanes.map(\.input), defaultInput: audioLanes.first?.input)
            guard writer.canAdd(group) else { throw failure("Failed to group the audio tracks.") }
            writer.add(group)

            let lanes = [videoLane] + audioLanes
            for lane in lanes where !lane.reader.startReading() {
                throw lane.reader.error ?? failure("Failed to read a source track.")
            }
            guard writer.startWriting() else { throw writer.error ?? failure("Failed to start writing.") }
            writer.startSession(atSourceTime: .zero)
            pump(lanes) { finish(writer, lanes: lanes, completion: completion) }
        } catch {
            completion(error)
        }
    }

    private static func lane(for track: AVAssetTrack, in asset: AVAsset, writer: AVAssetWriter, range: CMTimeRange) throws -> Lane {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw failure("Failed to read a source track.") }
        reader.add(output)
        let format = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
        let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
        input.transform = track.preferredTransform
        guard writer.canAdd(input) else { throw failure("Failed to add a track to the output file.") }
        writer.add(input)
        return Lane(reader: reader, output: output, input: input)
    }

    // Feeds every lane on its own queue, as the writer asks for data, and calls back once all of
    // them have run dry or stopped on an error.
    private static func pump(_ lanes: [Lane], completion: @escaping () -> Void) {
        let group = DispatchGroup()
        for lane in lanes {
            group.enter()
            lane.input.requestMediaDataWhenReady(on: DispatchQueue(label: "com.lihaoyun6.QuickRecorder.muxer")) {
                while lane.input.isReadyForMoreMediaData {
                    guard let sample = lane.output.copyNextSampleBuffer(), lane.input.append(sample) else {
                        lane.input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        group.notify(queue: .global(qos: .userInitiated), execute: completion)
    }

    // Once writing has started, the file at the output URL is this writer's own, so a failure
    // removes it rather than leave a broken file under the name the caller asked for.
    private static func finish(_ writer: AVAssetWriter, lanes: [Lane], completion: @escaping (Error?) -> Void) {
        let fail: (Error) -> Void = { error in
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: writer.outputURL)
            completion(error)
        }
        if let failed = lanes.first(where: { $0.reader.status == .failed }) {
            return fail(failed.reader.error ?? failure("Failed to read a source track."))
        }
        guard writer.status == .writing else { return fail(writer.error ?? failure("Failed to write the output file.")) }
        writer.finishWriting {
            guard writer.status == .completed else { return fail(writer.error ?? failure("Failed to write the output file.")) }
            completion(nil)
        }
    }

    // The name under both keys players read it from: QuickTime's own, and the title that
    // ffmpeg-based players take from a mov. An mp4 keeps only the first, as a 3GPP title.
    private static func trackName(_ title: String) -> [AVMetadataItem] {
        return [AVMetadataIdentifier.quickTimeUserDataTrackName, .quickTimeUserDataFullName].map { identifier in
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = title as NSString
            item.extendedLanguageTag = "und"
            return item
        }
    }

    private static func failure(_ message: String) -> NSError {
        return NSError(domain: "TrackMuxerError", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
