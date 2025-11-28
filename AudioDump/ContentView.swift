//
//  ContentView.swift
//  AudioDump
//
//  Created by Ethan Buck on 11/27/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var vm = RecorderViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                List {
                    if vm.snapshots.isEmpty {
                        Text("No snapshots yet. Start recording, then tap “Save Snapshot” to capture the last few minutes.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ForEach(vm.snapshots) { snapshot in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(snapshot.title)
                                        .font(.headline)
                                    Text(snapshot.formattedDuration)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    vm.play(snapshot)
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                }
                                .buttonStyle(.plain)
                            }
                            .contentShape(Rectangle())
                            .swipeActions {
                                Button(role: .destructive) {
                                    vm.deleteSnapshot(snapshot)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)

                Divider()

                VStack(spacing: 12) {
                    // rolling window control
                    VStack {
                        Text("Rolling window: \(Int(vm.rollingWindowSeconds))s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $vm.rollingWindowSeconds, in: 10...300, step: 5)
                            .disabled(vm.isRecording)  // lock while recording
                    }
                    .padding(.horizontal)

                    HStack(spacing: 16) {
                        if vm.isRecording {
                            Button {
                                vm.saveSnapshot()
                            } label: {
                                Label("Save Snapshot", systemImage: "square.and.arrow.down")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button(role: .destructive) {
                                vm.stopRecording()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                vm.startRecording()
                            } label: {
                                Label("Start Recording", systemImage: "record.circle")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
                .background(.thinMaterial)
            }
            .navigationTitle("AudioDump")
        }
    }
}

#Preview {
    ContentView()
}
