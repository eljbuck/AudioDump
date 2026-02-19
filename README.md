# AudioDump

An iOS audio memo recorder that records a fixed window length of audio (15s-300s). Uses AVFoundation and SwiftUI. Records in mono, 44.1kHz, AAC.

## Motivation

My composition process typically starts at the piano and ends hours later with, if I'm lucky, one usable idea that I've captured on Voice Memos. If I'm not, it's because I find compositional inspiration like recalling dreams: it rarely happens and when it does, it usually escapes me before I can record it. To mitigate, I have historically resorted to recording entire writing sessions, but (re: it rarely happens), these files end up being hundreds of MB. This project attempts to save space on my phone by recording a rolling buffer of the past few minutes (like a dashcam, but for half-baked musical ideas). Record your entire session and when inspiration strikes, hit "Save Snapshot."

## Requirements
- Xcode 15+
- iOS 16+ (runs on iOS 17 as well)
- Microphone access

## Usage
- Clone the repo
- Open AudioDump.xcodeproj
- Ensure the project has a Privacy - Microphone Usage Description (NSMicrophoneUsageDescription) in Info.plist
- Build and run on a device or simulator
- Tap “Start Recording”, then “Save Snapshot” to create .m4a files in the app’s Documents directory

![home view](/assets/home.png "AudioDump home view")
![recording view](/assets/recording.png "AudioDump recording view")

## Notes

This uses an SPSC ring buffer with Swift Atomics to ensure real-time thread is non-blocking while facillitating UI background thread with consistent, ordered reads.

## Known Issues

- Audio set up only happens on "Start Recording", so when the user's first action is to playback snapshots, they do not start until the user presses "Start Recording"
- Playback should be disallowed while recording

## Features To Add

- [ ] Add tests
- [ ] Add transport control for snapshot playback
  - [ ] pause
  - [ ] seek ±15 seconds
  - [ ] add playhead/seek bar
  - [ ] scrubbing
- [ ] Rename stored snapshots
- [ ] Group snapshots in folders by session
- [ ] Add time-domain or level visualizer
