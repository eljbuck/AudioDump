import AVFoundation
import Combine

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var rollingWindowSeconds: Double = 30 {
        didSet {
            recorder.rollingWindowSeconds = rollingWindowSeconds
        }
    }
    @Published var snapshots: [VoiceMemoSnapshot] = []

    let player = AudioPlayer()

    private let recorder = RollingRecorder(rollingWindowSeconds: 30)
    private let fileManager = FileManager.default

    init() {
        Task {
            await loadExistingSnapshots()
        }
    }

    func startRecording() {
        Task {
            do {
                try await recorder.start()
                isRecording = true
            } catch {
                // TODO: surface error to user
                isRecording = false
            }
        }
    }

    func stopRecording() {
        recorder.stop()
        isRecording = false
    }

    func saveSnapshot() {
        // create unique filename in Documents
        let url = documentsDirectory()
            .appendingPathComponent(snapshotFilename())
            .appendingPathExtension("m4a")

        do {
            let duration = try recorder.saveSnapshot(to: url)
            let snapshot = VoiceMemoSnapshot(date: Date(), duration: duration, fileURL: url)
            snapshots.insert(snapshot, at: 0)
        } catch {
            // TODO: surface error to user and optionally remove file if created
            try? fileManager.removeItem(at: url)
        }
    }

    func deleteSnapshot(_ snapshot: VoiceMemoSnapshot) {
        if let idx = snapshots.firstIndex(of: snapshot) {
            snapshots.remove(at: idx)
        }
        try? fileManager.removeItem(at: snapshot.fileURL)
    }

    func play(_ snapshot: VoiceMemoSnapshot) {
        player.play(url: snapshot.fileURL)
    }

    // MARK: - Persistence

    private func loadExistingSnapshots() async {
        let dir = documentsDirectory()
        let contents = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        // filter only .m4a files created by us
        let m4as = contents.filter { $0.pathExtension.lowercased() == "m4a" }
        // sort newest first
        let sorted = m4as.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return lDate > rDate
        }

        var loaded: [VoiceMemoSnapshot] = []
        for url in sorted {
            let asset = AVURLAsset(url: url)

            // load duration
            let seconds: Double
            do {
                let cmDuration = try await asset.load(.duration)
                let value = CMTimeGetSeconds(cmDuration)
                seconds = value.isFinite ? value : rollingWindowSeconds
            } catch {
                seconds = rollingWindowSeconds
            }

            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let snapshot = VoiceMemoSnapshot(date: created, duration: seconds, fileURL: url)
            loaded.append(snapshot)
        }

        self.snapshots = loaded
    }

    private func documentsDirectory() -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private func snapshotFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Snapshot_\(formatter.string(from: Date()))"
    }
}
