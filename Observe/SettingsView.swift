import HomeKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editingNumberSetting: NumberSettingKind?

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

                if SettingsPresentation.showsWallDensitySection(for: .current) {
                    Section("Wall") {
                        Picker("Density", selection: densityBinding) {
                            ForEach(WallDensity.selectableCases(for: .current)) { density in
                                Text(density.title).tag(density)
                            }
                        }
                        .pickerStyle(.segmented)

                    }
                }

                Section("Camera Names") {
                    Picker("Show Camera Names", selection: cameraNameVisibilityBinding) {
                        ForEach(CameraNameVisibility.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
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

                    NumberSettingRow(
                        title: "Threshold",
                        value: preferences.staleVisualHighlightSeconds
                    ) {
                        editingNumberSetting = .staleThreshold
                    }
                }

                if !store.priorityOrderedFeeds.isEmpty {
                    Section("Battery Cameras") {
                        Text(
                            "Battery camera snapshots can go stale, look washed out, or miss focus. Turn this on to refresh them from a temporary live feed instead. You can control when Observe starts that live refresh, how long it waits before trusting the frame, and when the result is treated as stale again."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        NumberSettingRow(
                            title: "Start Live Capture After",
                            value: preferences.batteryWakeTriggerSeconds
                        ) {
                            editingNumberSetting = .batteryWakeTrigger
                        }

                        NumberSettingRow(
                            title: "Wait Before Capturing",
                            value: preferences.batteryCaptureWarmupSeconds
                        ) {
                            editingNumberSetting = .batteryCaptureWarmup
                        }

                        NumberSettingRow(
                            title: "Show As Stale",
                            value: preferences.batteryStaleSeconds
                        ) {
                            editingNumberSetting = .batteryStale
                        }

                        ForEach(store.priorityOrderedFeeds) { feed in
                            Toggle(
                                isOn: batteryWakeBinding(for: feed.id)
                            ) {
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
                    }
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
                ToolbarItem(placement: doneToolbarPlacement) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingNumberSetting) { setting in
                NumberSettingEditor(
                    setting: setting,
                    value: numberBinding(for: setting)
                )
                .presentationDetents([.height(420), .medium])
            }
        }
    }

    private var doneToolbarPlacement: ToolbarItemPlacement {
        switch SettingsPresentation.doneButtonPlacement(for: .current) {
        case .leading:
            .cancellationAction
        case .trailing:
            .confirmationAction
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

    private var cameraNameVisibilityBinding: Binding<CameraNameVisibility> {
        Binding(
            get: { preferences.cameraNameVisibility },
            set: { preferences.cameraNameVisibility = $0 }
        )
    }

    private var staleThresholdBinding: Binding<Int> {
        Binding(
            get: { preferences.staleVisualHighlightSeconds },
            set: { preferences.setStaleVisualHighlightSeconds($0) }
        )
    }

    private func batteryWakeBinding(for feedID: String) -> Binding<Bool> {
        Binding(
            get: { preferences.isBatteryWakeCamera(id: feedID) },
            set: { preferences.setBatteryWakeEnabled($0, for: feedID) }
        )
    }

    private var batteryWakeTriggerBinding: Binding<Int> {
        Binding(
            get: { preferences.batteryWakeTriggerSeconds },
            set: { preferences.setBatteryWakeTriggerSeconds($0) }
        )
    }

    private var batteryStaleBinding: Binding<Int> {
        Binding(
            get: { preferences.batteryStaleSeconds },
            set: { preferences.setBatteryStaleSeconds($0) }
        )
    }

    private var batteryCaptureWarmupBinding: Binding<Int> {
        Binding(
            get: { preferences.batteryCaptureWarmupSeconds },
            set: { preferences.setBatteryCaptureWarmupSeconds($0) }
        )
    }

    private func numberBinding(for setting: NumberSettingKind) -> Binding<Int> {
        switch setting {
        case .staleThreshold:
            staleThresholdBinding
        case .batteryWakeTrigger:
            batteryWakeTriggerBinding
        case .batteryCaptureWarmup:
            batteryCaptureWarmupBinding
        case .batteryStale:
            batteryStaleBinding
        }
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

enum NumberSettingKind: String, Identifiable {
    case staleThreshold
    case batteryWakeTrigger
    case batteryCaptureWarmup
    case batteryStale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .staleThreshold:
            "Threshold"
        case .batteryWakeTrigger:
            "Start Live Capture After"
        case .batteryCaptureWarmup:
            "Wait Before Capturing"
        case .batteryStale:
            "Show As Stale"
        }
    }

    var presets: [Int] {
        switch self {
        case .batteryCaptureWarmup:
            [3, 5, 8, 10, 15]
        case .staleThreshold, .batteryWakeTrigger:
            [15, 30, 45, 60, 90, 120]
        case .batteryStale:
            [60, 90, 120, 180, 300]
        }
    }

    var step: Int {
        switch self {
        case .batteryCaptureWarmup:
            1
        case .staleThreshold, .batteryWakeTrigger, .batteryStale:
            5
        }
    }

    var minimumValue: Int { 1 }
}

struct NumberSettingDraft: Equatable {
    private(set) var value: Int
    private(set) var text: String
    let minimumValue: Int

    init(value: Int, minimumValue: Int) {
        self.minimumValue = max(1, minimumValue)
        let sanitizedValue = max(self.minimumValue, value)
        self.value = sanitizedValue
        self.text = "\(sanitizedValue)"
    }

    mutating func adjust(by delta: Int) {
        setValue(value + delta)
    }

    mutating func setValue(_ newValue: Int) {
        value = max(minimumValue, newValue)
        text = "\(value)"
    }

    mutating func updateText(_ newText: String) {
        text = newText
        guard let parsed = Int(newText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        value = max(minimumValue, parsed)
    }
}

private struct NumberSettingRow: View {
    let title: String
    let value: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(value) sec")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NumberSettingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var value: Int
    @State private var draft: NumberSettingDraft

    let setting: NumberSettingKind

    init(setting: NumberSettingKind, value: Binding<Int>) {
        self.setting = setting
        self._value = value
        self._draft = State(
            initialValue: NumberSettingDraft(
                value: value.wrappedValue,
                minimumValue: setting.minimumValue
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                VStack(spacing: 4) {
                    Text("\(draft.value)")
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("seconds")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 18) {
                    adjustmentButton(systemName: "minus", delta: -setting.step)
                    adjustmentButton(systemName: "plus", delta: setting.step)
                }

                TextField("Seconds", text: textBinding)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                presetGrid

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .navigationTitle(setting.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        value = draft.value
                        dismiss()
                    }
                }
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { draft.text },
            set: { draft.updateText($0) }
        )
    }

    private var presetGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            spacing: 10
        ) {
            ForEach(setting.presets, id: \.self) { preset in
                Button("\(preset)s") {
                    draft.setValue(preset)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private func adjustmentButton(systemName: String, delta: Int) -> some View {
        Button {
            draft.adjust(by: delta)
        } label: {
            Image(systemName: systemName)
                .font(.title2.weight(.semibold))
                .frame(width: 82, height: 48)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(delta < 0 ? "Decrease" : "Increase")
    }
}
