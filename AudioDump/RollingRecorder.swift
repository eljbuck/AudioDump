import AVFoundation
import Atomics

/// A recorder that continuously keeps only the last `rollingWindowSeconds` of mic audio in memory.
/// When `saveSnapshot()` is called, it writes exactly that window to a linear PCM file (.caf) in mono Float32.
final class RollingRecorder {
    enum RecorderError: Error {
        case microphonePermissionDenied
        case engineNotRunning
        case formatUnavailable
        case fileWriteFailed
        case sessionSetupFailed
    }

    // public config
    var rollingWindowSeconds: TimeInterval {
        didSet {
            if rollingWindowSeconds < 1 { rollingWindowSeconds = 1 }
            reallocateBufferIfNeeded()
        }
    }

    // engine/session
    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()

    // capture audio format (Float32, mono)
    private let preferredSampleRate: Double
    private let channelCount: AVAudioChannelCount = 1
    private var format: AVAudioFormat
    private var actualSampleRate: Double

    // circular buffer of Float32 samples (mono)
    private var buffer: [Float]

    // atomics avoid producer-consumer race conditions
    private let writeIndex = ManagedAtomic<Int>(0)
    private let isBufferFilled = ManagedAtomic<Bool>(false)
    private var maxSamples: Int

    // state
    private(set) var isRecording: Bool = false

    init(rollingWindowSeconds: TimeInterval = 30, preferredSampleRate: Double = 44100) {
        self.rollingWindowSeconds = rollingWindowSeconds
        self.preferredSampleRate = preferredSampleRate

        // canonical mono, non-interleaved float; we will adapt actualSampleRate after engine is configured
        let canonicalFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: preferredSampleRate,
                                            channels: channelCount,
                                            interleaved: false)!
        self.format = canonicalFormat
        self.actualSampleRate = canonicalFormat.sampleRate

        self.maxSamples = Int(canonicalFormat.sampleRate * rollingWindowSeconds)
        self.buffer = Array(repeating: 0, count: maxSamples)
    }

    // MARK: - Public API

    func start() async throws {
        try await configureSessionIfNeeded()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
//        print("inputFormat = \(inputFormat)")

        let inputIsFloatMonoNonInterleaved =
            inputFormat.commonFormat == .pcmFormatFloat32 &&
            inputFormat.channelCount == channelCount &&
            inputFormat.isInterleaved == false

        // only convert if the input is not Float32 mono non-interleaved.
        let needsConversion = !inputIsFloatMonoNonInterleaved

        // if input is already Float32 mono non-interleaved, adopt its sample rate exactly.
        if inputIsFloatMonoNonInterleaved {
            self.format = inputFormat
            self.actualSampleRate = inputFormat.sampleRate
        } else {
            // otherwise, target our preferred mono Float32 non-interleaved at preferredSampleRate.
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: preferredSampleRate,
                                             channels: channelCount,
                                             interleaved: false) else {
                throw RecorderError.formatUnavailable
            }
            self.format = target
            self.actualSampleRate = target.sampleRate
        }

        // reallocate buffer to match the actual sample rate
        maxSamples = max(1, Int(actualSampleRate * rollingWindowSeconds))
        buffer = Array(repeating: 0, count: maxSamples)
        writeIndex.store(0, ordering: .relaxed)
        isBufferFilled.store(false, ordering: .relaxed)

        // prepare converter if needed
        let converter: AVAudioConverter? = needsConversion ? AVAudioConverter(from: inputFormat, to: format) : nil

        // remove existing taps if any
        input.removeTap(onBus: 0)

        // helper to hold atomic state safely captured by @Sendable closure
        final class OneShotFlag {
            let handedOut = ManagedAtomic<Bool>(false)
        }

        // install tap
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard buffer.frameLength > 0 else { return }

            var useBuffer: AVAudioPCMBuffer? = buffer

            if let converter {
                // allow the converter to produce up to a reasonable chunk; the actual produced frames may differ.
                let capacityFrames = max(Int(buffer.frameLength), 2048)
                guard let converted = AVAudioPCMBuffer(pcmFormat: self.format,
                                                       frameCapacity: AVAudioFrameCount(capacityFrames)) else {
                    return
                }
                converted.frameLength = 0

                // capture the source buffer by value and avoid mutable captured vars.
                let sourceOnce = buffer
                let flag = OneShotFlag()
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    if !flag.handedOut.load(ordering: .relaxed), sourceOnce.frameLength > 0 {
                        flag.handedOut.store(true, ordering: .relaxed)
                        outStatus.pointee = .haveData
                        return sourceOnce
                    } else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                }

                var convError: NSError?
                let status = converter.convert(to: converted, error: &convError, withInputFrom: inputBlock)
                guard (status == .haveData || status == .inputRanDry), converted.frameLength > 0 else {
                    return
                }
                useBuffer = converted
            } else {
                // sanity check: ensure non-interleaved mono Float32
                guard buffer.format.commonFormat == .pcmFormatFloat32,
                      buffer.format.channelCount == self.channelCount,
                      buffer.format.isInterleaved == false else {
                    return
                }
            }

            guard let finalBuffer = useBuffer,
                  finalBuffer.frameLength > 0,
                  let channelData = finalBuffer.floatChannelData else { return }

            let frames = Int(finalBuffer.frameLength)
            let samplesPtr = channelData[0]

            let currentIndex = self.writeIndex.load(ordering: .relaxed)
            var newIndex = currentIndex

            let remaining = self.maxSamples - currentIndex
            if frames <= remaining {
                memcpy(&self.buffer[currentIndex], samplesPtr, frames * MemoryLayout<Float>.size)
                newIndex = currentIndex + frames

                if newIndex >= self.maxSamples {
                    newIndex = 0
                    self.isBufferFilled.store(true, ordering: .relaxed)
                }
            } else {
                let first = remaining
                let second = frames - first
                memcpy(&self.buffer[currentIndex], samplesPtr, first * MemoryLayout<Float>.size)
                memcpy(&self.buffer[0], samplesPtr.advanced(by: first), second * MemoryLayout<Float>.size)
                newIndex = second
                self.isBufferFilled.store(true, ordering: .relaxed)
            }

            self.writeIndex.store(newIndex, ordering: .releasing)
        }

        do {
            try engine.start()
            isRecording = true
        } catch {
            throw RecorderError.engineNotRunning
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
    }

    /// Writes the last `rollingWindowSeconds` from the circular buffer to a new linear PCM file (.caf).
    /// Returns the duration actually written (may be less if not enough buffered yet).
    func saveSnapshot(to url: URL) throws -> TimeInterval {
        // read atomics
        let currentIndex = writeIndex.load(ordering: .acquiring)
        let filled = isBufferFilled.load(ordering: .acquiring)

        // snapshot copy of samples
        let samplesToWrite: [Float]
        let framesAvailable: Int

        if filled {
            framesAvailable = maxSamples
            samplesToWrite = Array(buffer[currentIndex..<maxSamples] + buffer[0..<currentIndex])
        } else {
            framesAvailable = currentIndex
            samplesToWrite = Array(buffer[0..<currentIndex])
        }

        if framesAvailable == 0 {
            throw RecorderError.fileWriteFailed
        }

        // Prepare linear PCM (Float32 mono) settings matching our canonical format
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: actualSampleRate,
                                            channels: channelCount,
                                            interleaved: false) else {
            throw RecorderError.formatUnavailable
        }

        // Create the output file (use CAF/WAV in the caller for the URL extension)
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: pcmFormat.settings)
        } catch {
            throw RecorderError.fileWriteFailed
        }

        // stream in chunks to avoid large allocations
        let chunkFrames = 4096
        var offset = 0

        let totalFrames = framesAvailable
        let duration = Double(totalFrames) / actualSampleRate

        while offset < totalFrames {
            let framesThisChunk = min(chunkFrames, totalFrames - offset)
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                                   frameCapacity: AVAudioFrameCount(framesThisChunk)) else {
                throw RecorderError.fileWriteFailed
            }
            pcmBuffer.frameLength = AVAudioFrameCount(framesThisChunk)

            // copy samples into buffer
            if let dst = pcmBuffer.floatChannelData?.pointee {
                samplesToWrite.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress {
                        memcpy(dst, base.advanced(by: offset), framesThisChunk * MemoryLayout<Float>.size)
                    }
                }
            } else {
                throw RecorderError.fileWriteFailed
            }

            do {
                try audioFile.write(from: pcmBuffer)
            } catch {
                throw RecorderError.fileWriteFailed
            }

            offset += framesThisChunk
        }

        return duration
    }

    // MARK: - Private

    private func configureSessionIfNeeded() async throws {
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setPreferredSampleRate(preferredSampleRate)
            try session.setActive(true, options: [])
        } catch {
            throw RecorderError.sessionSetupFailed
        }

        // iOS 17+: use AVAudioApplication.* APIs
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            let status = AVAudioApplication.shared.recordPermission
            if status == .undetermined {
                let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
                if !granted { throw RecorderError.microphonePermissionDenied }
            } else if status == .denied {
                throw RecorderError.microphonePermissionDenied
            }
        } else {
            // Pre-iOS 17 fallback
            let status = session.recordPermission
            if status == .undetermined {
                let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    session.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
                if !granted { throw RecorderError.microphonePermissionDenied }
            } else if status == .denied {
                throw RecorderError.microphonePermissionDenied
            }
        }
    }

    private func reallocateBufferIfNeeded() {
        if isRecording { return }

        let newMaxSamples = max(1, Int(actualSampleRate * rollingWindowSeconds))
        if newMaxSamples != maxSamples {
            maxSamples = newMaxSamples
            buffer = Array(repeating: 0, count: maxSamples)
            writeIndex.store(0, ordering: .relaxed)
            isBufferFilled.store(false, ordering: .relaxed)
        }
    }
}
