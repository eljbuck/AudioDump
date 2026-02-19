import Foundation

struct VoiceMemoSnapshot: Identifiable, Hashable {
    let id: UUID
    let date: Date
    let duration: TimeInterval
    let fileURL: URL

    init(id: UUID = UUID(), date: Date = Date(), duration: TimeInterval, fileURL: URL) {
        self.id = id
        self.date = date
        self.duration = duration
        self.fileURL = fileURL
    }

    var title: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var formattedDuration: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
