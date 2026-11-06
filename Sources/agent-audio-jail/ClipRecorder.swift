import AVFoundation
import Foundation

struct ClipRecorderSummary {
    let lastSoundAt: Date?
    let lastPeak: Float
    let clipPaths: [String]
}

/// Turns a continuous tap stream into finalized WAV clips: a clip opens on the first
/// non-silent buffer and closes after `silenceTimeout` of silence or `maximumClipSeconds`.
/// `append` and `finishClip` must be called on the owning session's serial queue.
final class ClipRecorder {
    static let silencePeak: Float = 0.0001
    static let silenceTimeout: TimeInterval = 2
    static let maximumClipSeconds: Double = 120
    static let retainedClipCount = 20

    private let directory: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var clipFrameCount: AVAudioFramePosition = 0
    private var clipSequence = 0
    private var lastSoundAt: Date?
    private var lastPeak: Float = 0
    private var clipPaths: [String] = []

    init(directory: URL) {
        self.directory = directory
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let peak = measurePeak(of: buffer)
        let now = Date()
        lock.withLock {
            lastPeak = peak
            if peak > Self.silencePeak { lastSoundAt = now }
        }

        if peak > Self.silencePeak, file == nil {
            openClip(format: buffer.format)
        }
        guard let file else { return }
        if file.processingFormat != buffer.format {
            finishClip()
            if peak > Self.silencePeak { openClip(format: buffer.format) }
            return
        }

        do {
            try file.write(from: buffer)
            clipFrameCount += AVAudioFramePosition(buffer.frameLength)
        } catch {
            log("clip write failed in \(directory.lastPathComponent): \(error)")
            finishClip()
            return
        }

        let silentFor = now.timeIntervalSince(lock.withLock { lastSoundAt } ?? now)
        let clipSeconds = Double(clipFrameCount) / buffer.format.sampleRate
        if silentFor > Self.silenceTimeout || clipSeconds > Self.maximumClipSeconds {
            finishClip()
        }
    }

    func finishClip() {
        guard file != nil else { return }
        file = nil
        clipFrameCount = 0
        pruneOldClips()
    }

    func summarize() -> ClipRecorderSummary {
        lock.withLock {
            ClipRecorderSummary(lastSoundAt: lastSoundAt, lastPeak: lastPeak, clipPaths: clipPaths)
        }
    }

    private func openClip(format: AVAudioFormat) {
        clipSequence += 1
        let url = directory.appendingPathComponent(String(format: "clip-%@-%03d.wav", makeTimestamp(), clipSequence))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            clipFrameCount = 0
            lock.withLock { clipPaths.append(url.path) }
        } catch {
            log("could not open clip \(url.path): \(error)")
            file = nil
        }
    }

    private func pruneOldClips() {
        let expired: [String] = lock.withLock {
            let overflow = clipPaths.count - Self.retainedClipCount
            guard overflow > 0 else { return [] }
            let removed = Array(clipPaths.prefix(overflow))
            clipPaths.removeFirst(overflow)
            return removed
        }
        for path in expired {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

private func measurePeak(of buffer: AVAudioPCMBuffer) -> Float {
    guard let channels = buffer.floatChannelData else { return 0 }
    let channelCount = Int(buffer.format.channelCount)
    let pointerCount = buffer.format.isInterleaved ? 1 : channelCount
    let samplesPerPointer = Int(buffer.frameLength) * (buffer.format.isInterleaved ? channelCount : 1)
    var peak: Float = 0
    for pointerIndex in 0..<pointerCount {
        let samples = channels[pointerIndex]
        for sampleIndex in 0..<samplesPerPointer {
            peak = max(peak, abs(samples[sampleIndex]))
        }
    }
    return peak
}

private func makeTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}
