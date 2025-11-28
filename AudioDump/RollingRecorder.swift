import AVFoundation
import Atomics

/// A recorder that continuously keeps only the last `rollingWindowSeconds` of mic audio in memory.
/// When `saveSnapshot()` is called, it writes exactly that window to an .m4a file.
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
    private let sampleRate: Double
    private let channelCount: AVAudioChannelCount = 1
    private let format: AVAudioFormat

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
        self.sampleRate = preferredSampleRate
        // mono, non-interleaved float
        self.format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: preferredSampleRate,
                                    channels: channelCount,
                                    interleaved: false)!
        self.maxSamples = Int(preferredSampleRate * rollingWindowSeconds)
        self.buffer = Array(repeating: 0, count: maxSamples)
    }

    // MARK: - Public API

    func start() async throws {
        try await configureSessionIfNeeded()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        // converter if needed
        let needsConversion = inputFormat != format
        let converter: AVAudioConverter? = needsConversion ? AVAudioConverter(from: inputFormat, to: format) : nil

        // remove existing taps if any
        input.removeTap(onBus: 0)

        // reset buffer info
        writeIndex.store(0, ordering: .relaxed)
        isBufferFilled.store(false, ordering: .relaxed)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // ensure buffer has frames
            guard buffer.frameLength > 0 else { return }

            var useBuffer: AVAudioPCMBuffer? = buffer

            if let converter {
                let capacityFrames = 2048
                guard let converted = AVAudioPCMBuffer(pcmFormat: self.format,
                                                       frameCapacity: AVAudioFrameCount(capacityFrames)) else {
                    return
                }
                converted.frameLength = 0

                let srcBuffer: AVAudioPCMBuffer? = buffer
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    if let src = srcBuffer, src.frameLength > 0 {
                        outStatus.pointee = .haveData
                        return src
                    } else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                }

                var convError: NSError?
                let status = converter.convert(to: converted, error: &convError, withInputFrom: inputBlock)
                guard status == .haveData, converted.frameLength > 0 else {
                    return
                }
                useBuffer = converted
            }

            guard let finalBuffer = useBuffer,
                  finalBuffer.frameLength > 0,
                  let channelData = finalBuffer.floatChannelData else { return }

            let frames = Int(finalBuffer.frameLength)
            let samplesPtr = channelData[0]

            let currentIndex = self.writeIndex.load(ordering: .relaxed)
            var newIndex = currentIndex
            // write into circular buffer
            let remaining = self.maxSamples - currentIndex
            if frames <= remaining {
                // single copy
                memcpy(&self.buffer[currentIndex], samplesPtr, frames * MemoryLayout<Float>.size)
                newIndex = currentIndex + frames
                
                if newIndex >= self.maxSamples {
                    newIndex = 0
                    self.isBufferFilled.store(true, ordering: .relaxed)
                }
            } else {
                // wrap around: split into two copies
                let first = remaining
                let second = frames - first
                memcpy(&self.buffer[currentIndex], samplesPtr, first * MemoryLayout<Float>.size)
                memcpy(&self.buffer[0], samplesPtr.advanced(by: first), second * MemoryLayout<Float>.size)
                newIndex = second
                self.isBufferFilled.store(true, ordering: .relaxed)
            }
            // publish new write index
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

    /// Writes the last `rollingWindowSeconds` from the circular buffer to a new .m4a file.
    /// Returns the file URL and duration actually written (may be less if not enough buffered yet).
    func saveSnapshot(to url: URL) throws -> TimeInterval {
        // read atomics
        let currentIndex = writeIndex.load(ordering: .acquiring)
        let filled = isBufferFilled.load(ordering: .acquiring)
        // snapshot copy of samples
        let samplesToWrite: [Float]
        let framesAvailable: Int

        if filled {
            framesAvailable = maxSamples
            // reconstruct in chronological order ending at writeIndex
            samplesToWrite = Array(buffer[currentIndex..<maxSamples] + buffer[0..<currentIndex])
        } else {
            framesAvailable = currentIndex
            samplesToWrite = Array(buffer[0..<currentIndex])
        }

        if framesAvailable == 0 {
            throw RecorderError.fileWriteFailed
        }

        // prepare output format: AAC in an .m4a container
        guard let aacFormat = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: 128_000
        ]) else {
            throw RecorderError.formatUnavailable
        }

        // create the output file
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: aacFormat.settings)
        } catch {
            throw RecorderError.fileWriteFailed
        }

        // stream in chunks to avoid large allocations
        let chunkFrames = 4096
        var offset = 0

        let totalFrames = framesAvailable
        let duration = Double(totalFrames) / sampleRate

        while offset < totalFrames {
            let framesThisChunk = min(chunkFrames, totalFrames - offset)
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesThisChunk)) else {
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
            // use updated option to avoid deprecation
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setPreferredSampleRate(sampleRate)
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
        
        let newMaxSamples = max(1, Int(sampleRate * rollingWindowSeconds))
        if newMaxSamples != maxSamples {
            // if we change size, reset indices and allocate a new buffer
            maxSamples = newMaxSamples
            buffer = Array(repeating: 0, count: maxSamples)
            writeIndex.store(0, ordering: .relaxed)
            isBufferFilled.store(false, ordering: .relaxed)
        }
    }
}
