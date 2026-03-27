import HomeKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var store: HomeKitCameraStore
    @ObservedObject var preferences: ObservePreferences

    var body: some View {
        NavigationStack {
            Form {
                Section("Home") {
                    if store.homes.isEmpty {
                        Text("No homes available.")
                    } else {
                        Picker("Selected Home", selection: selectedHomeBinding) {
                            ForEach(store.homes) { home in
                                Text(home.name).tag(home.id)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }

                    LabeledContent("Hub") {
                        Text(homeHubLabel)
                    }

                }

                Section("Wall") {
                    Picker("Density", selection: densityBinding) {
                        ForEach(WallDensity.allCases) { density in
                            Text(density.title).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Stale") {
                    Text(
                        "If a camera is showing an image older than this, Observe puts a red box around it so you can quickly tell it is not recent."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    HStack {
                        Text("Threshold")

                        Spacer()

                        TextField("60", value: staleThresholdBinding, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)

                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }

                    Button("Default") {
                        preferences.resetStaleVisualHighlightSeconds()
                    }
                    .disabled(preferences.staleVisualHighlightSeconds == preferences.defaultStaleVisualHighlightSeconds)
                }

                if !store.priorityOrderedFeeds.isEmpty {
                    Section("Camera Order") {
                        ForEach(store.priorityOrderedFeeds) { feed in
                            HStack {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feed.name)
                                    if let roomName = feed.roomName {
                                        Text(roomName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onMove(perform: store.movePriority)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Observe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                if !store.priorityOrderedFeeds.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        EditButton()
                    }
                }
            }
        }
    }

    private var selectedHomeBinding: Binding<String> {
        Binding(
            get: {
                preferences.selectedHomeID ?? store.homes.first?.id ?? ""
            },
            set: { store.selectHome(id: $0) }
        )
    }

    private var densityBinding: Binding<WallDensity> {
        Binding(
            get: { preferences.wallDensity },
            set: { preferences.wallDensity = $0 }
        )
    }

    private var staleThresholdBinding: Binding<Int> {
        Binding(
            get: { preferences.staleVisualHighlightSeconds },
            set: { preferences.setStaleVisualHighlightSeconds($0) }
        )
    }

    private var homeHubLabel: String {
        switch store.homeHubState {
        case .connected:
            "Connected"
        case .disconnected:
            "Disconnected"
        case .notAvailable:
            "Not available"
        @unknown default:
            "Unknown"
        }
    }
}
