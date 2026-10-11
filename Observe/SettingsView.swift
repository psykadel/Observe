import HomeKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editingNumberSetting: NumberSettingKind?
    @State private var didCopyTelemetry = false
    @State private var newHomeNetworkSSID = ""

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

                Section("Home Networks") {
                    Text(
                        "Add your home Wi-Fi networks so Observe can start all selected cameras live immediately when connected to any saved network."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    ForEach(preferences.homeNetworkSSIDs, id: \.self) { ssid in
                        HStack {
                            Text(ssid)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                store.removeHomeNetworkSSID(ssid)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(ssid)")
                        }
                    }

                    HStack {
                        TextField("Network Name", text: $newHomeNetworkSSID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addNewHomeNetwork)
                        Button("Add", action: addNewHomeNetwork)
                            .buttonStyle(.borderless)
                            .disabled(!canAddNewHomeNetwork)
                    }

                    if let currentWiFiSSID = store.currentWiFiSSID {
                        HStack {
                            Text(currentWiFiSSID)
                            Spacer()
                            Button {
                                store.addHomeNetworkSSID(currentWiFiSSID)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Add Current Wi-Fi Network")
                            .disabled(currentWiFiSSID.isEmpty || preferences.homeNetworkSSIDs.contains(currentWiFiSSID))
                        }
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

                Section("Snapshot Requests") {
                    Text("Limits how many camera snapshots Observe requests at once on a limited connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Picker("Snapshot Requests", selection: restrictedSnapshotRequestLimitBinding) {
                        ForEach(1...5, id: \.self) { limit in
                            Text("\(limit)").tag(limit)
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
                        valueText: NumberSettingKind.staleThreshold.displayValue(
                            preferences.staleVisualHighlightSeconds
                        )
                    ) {
                        editingNumberSetting = .staleThreshold
                    }
                }

                Section("Home Security") {
                    Toggle("Lock Status", isOn: lockStatusEnabledBinding)

                    if preferences.isLockStatusEnabled {
                        if store.lockOptions.isEmpty {
                            Text("No HomeKit locks available in this home.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.lockOptions) { option in
                                Toggle(isOn: lockSelectionBinding(for: option.id)) {
                                    homeSecurityOptionLabel(option)
                                }
                            }
                        }
                    }

                    Toggle("Home Temperature", isOn: homeTemperatureEnabledBinding)

                    if preferences.isHomeTemperatureEnabled {
                        if store.temperatureSensorOptions.isEmpty {
                            Text("No HomeKit temperature sensors available in this home.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.temperatureSensorOptions) { option in
                                Toggle(isOn: temperatureSelectionBinding(for: option.id)) {
                                    homeSecurityOptionLabel(option)
                                }
                            }
                        }

                        Stepper(value: homeTemperatureLowBinding, step: 1) {
                            LabeledContent("Acceptable Low") {
                                Text("\(preferences.homeTemperatureLowFahrenheit)°F")
                                    .monospacedDigit()
                            }
                        }

                        Stepper(value: homeTemperatureHighBinding, step: 1) {
                            LabeledContent("Acceptable High") {
                                Text("\(preferences.homeTemperatureHighFahrenheit)°F")
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Section("Success Indicator") {
                    Text(
                        "Displays a temporary green confirmation around the camera wall when every visible camera and each enabled Home Security check is healthy."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Toggle("Success Indicator", isOn: successIndicatorEnabledBinding)

                    if preferences.isSuccessIndicatorEnabled {
                        Toggle(
                            "Only Off Home Network",
                            isOn: successIndicatorOnlyOffHomeNetworkBinding
                        )
                    }
                }

                if !store.priorityOrderedFeeds.isEmpty {
                    Section("Battery Cameras") {
                        Text(
                            "Battery camera snapshots can go stale, look washed out, or miss focus. Turn this on to refresh them from a temporary live feed instead. You can control when Observe starts that live refresh, how long it waits before trusting the frame, and when the result is treated as stale again."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        Toggle(
                            "Enable Battery Camera Toggle Button",
                            isOn: batteryCameraVisibilityToggleBinding
                        )

                        Toggle(
                            "Show Battery Percentages",
                            isOn: batteryPercentageBinding
                        )

                        NumberSettingRow(
                            title: "Start Live Capture After",
                            valueText: NumberSettingKind.batteryWakeTrigger.displayValue(
                                preferences.batteryWakeTriggerSeconds
                            ),
                            helperText: NumberSettingKind.batteryWakeTrigger.helperText
                        ) {
                            editingNumberSetting = .batteryWakeTrigger
                        }

                        NumberSettingRow(
                            title: "Wait Before Capturing",
                            valueText: NumberSettingKind.batteryCaptureWarmup.displayValue(
                                preferences.batteryCaptureWarmupSeconds
                            ),
                            helperText: NumberSettingKind.batteryCaptureWarmup.helperText
                        ) {
                            editingNumberSetting = .batteryCaptureWarmup
                        }

                        NumberSettingRow(
                            title: "Show As Stale",
                            valueText: NumberSettingKind.batteryStale.displayValue(
                                preferences.batteryStaleSeconds
                            ),
                            helperText: NumberSettingKind.batteryStale.helperText
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
                        cameraOrderRows(store.priorityOrderedFeeds, onMove: store.movePriority)
                    }
                }

                if !store.livePriorityOrderedFeeds.isEmpty {
                    Section("Live Order") {
                        Text(
                            "When the connection is constrained, Observe uses this order to decide which cameras receive available live-stream slots first."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        cameraOrderRows(store.livePriorityOrderedFeeds, onMove: store.moveLivePriority)
                    }
                }

                Section {
                    Button {
                        copyTelemetry()
                    } label: {
                        Label(
                            didCopyTelemetry ? "Copied Telemetry" : "Copy Telemetry",
                            systemImage: didCopyTelemetry ? "checkmark" : "doc.on.doc"
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(UIColor.systemGroupedBackground))
            .onAppear {
                store.requestHomeNetworkAccess()
            }
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
                .presentationDetents(numberSettingPresentationDetents)
            }
        }
    }

    private var numberSettingPresentationDetents: Set<PresentationDetent> {
        switch CameraWallPlatform.current {
        case .mac:
            return [.height(600), .large]
        case .iPhone:
            return [.medium, .large]
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

    private var canAddNewHomeNetwork: Bool {
        !newHomeNetworkSSID.isEmpty && !preferences.homeNetworkSSIDs.contains(newHomeNetworkSSID)
    }

    private func addNewHomeNetwork() {
        guard canAddNewHomeNetwork else { return }
        store.addHomeNetworkSSID(newHomeNetworkSSID)
        newHomeNetworkSSID = ""
    }

    private var lockStatusEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.isLockStatusEnabled },
            set: { store.setLockStatusEnabled($0) }
        )
    }

    private var homeTemperatureEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.isHomeTemperatureEnabled },
            set: { store.setHomeTemperatureEnabled($0) }
        )
    }

    private var successIndicatorEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.isSuccessIndicatorEnabled },
            set: { preferences.setSuccessIndicatorEnabled($0) }
        )
    }

    private var successIndicatorOnlyOffHomeNetworkBinding: Binding<Bool> {
        Binding(
            get: { preferences.isSuccessIndicatorOnlyOffHomeNetwork },
            set: { preferences.setSuccessIndicatorOnlyOffHomeNetwork($0) }
        )
    }

    private func lockSelectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { preferences.isLockSelected(id: id) },
            set: { store.setLockSelected($0, for: id) }
        )
    }

    private func temperatureSelectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { preferences.isTemperatureSensorSelected(id: id) },
            set: { store.setTemperatureSensorSelected($0, for: id) }
        )
    }

    private var homeTemperatureLowBinding: Binding<Int> {
        Binding(
            get: { preferences.homeTemperatureLowFahrenheit },
            set: { store.setHomeTemperatureLowFahrenheit($0) }
        )
    }

    private var homeTemperatureHighBinding: Binding<Int> {
        Binding(
            get: { preferences.homeTemperatureHighFahrenheit },
            set: { store.setHomeTemperatureHighFahrenheit($0) }
        )
    }

    private func homeSecurityOptionLabel(_ option: HomeSecurityOption) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(option.name)
            if let roomName = option.roomName {
                Text(roomName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func cameraOrderRows(
        _ feeds: [CameraFeedCoordinator],
        onMove: @escaping (IndexSet, Int) -> Void
    ) -> some View {
        if CameraWallPlatform.current == .mac {
            CameraOrderRows(feeds: feeds, onMove: onMove)
        } else {
            ForEach(feeds) { feed in
                cameraOrderRow(feed)
            }
            .onMove(perform: onMove)
        }
    }

    private func cameraOrderRow(_ feed: CameraFeedCoordinator) -> some View {
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

    private var staleThresholdBinding: Binding<Int> {
        Binding(
            get: { preferences.staleVisualHighlightSeconds },
            set: { preferences.setStaleVisualHighlightSeconds($0) }
        )
    }

    private var restrictedSnapshotRequestLimitBinding: Binding<Int> {
        Binding(
            get: { preferences.restrictedSnapshotRequestLimit },
            set: { preferences.setRestrictedSnapshotRequestLimit($0) }
        )
    }

    private func batteryWakeBinding(for feedID: String) -> Binding<Bool> {
        Binding(
            get: { preferences.isBatteryWakeCamera(id: feedID) },
            set: { preferences.setBatteryWakeEnabled($0, for: feedID) }
        )
    }

    private var batteryCameraVisibilityToggleBinding: Binding<Bool> {
        Binding(
            get: { preferences.showsBatteryCameraVisibilityToggle },
            set: { store.setBatteryCameraVisibilityToggleShown($0) }
        )
    }

    private var batteryPercentageBinding: Binding<Bool> {
        Binding(
            get: { preferences.showsBatteryPercentages },
            set: { preferences.setBatteryPercentagesShown($0) }
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

    private func copyTelemetry() {
        let report = store.telemetryReportText()
        #if canImport(UIKit)
        UIPasteboard.general.string = report
        #endif
        didCopyTelemetry = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopyTelemetry = false
        }
    }
}

/// Reordering stays inside this view instead of starting a Catalyst drag/drop session.
private struct CameraOrderRows: View {
    let feeds: [CameraFeedCoordinator]
    let onMove: (IndexSet, Int) -> Void

    @GestureState private var drag: (id: String, offset: CGFloat)?
    private let rowHeight: CGFloat = 52

    private var draggedID: String? { drag?.id }
    private var dragOffset: CGFloat { drag?.offset ?? 0 }
    private var sourceIndex: Int? { feeds.firstIndex { $0.id == draggedID } }

    private var targetIndex: Int? {
        guard let sourceIndex else { return nil }
        return min(max(sourceIndex + Int((dragOffset / rowHeight).rounded()), 0), feeds.count - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(feeds.enumerated()), id: \.element.id) { index, feed in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feed.name)
                        if let roomName = feed.roomName {
                            Text(roomName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: rowHeight)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .updating($drag) { value, state, _ in
                                    state = (feed.id, value.translation.height)
                                }
                                .onEnded { value in
                                    let target = min(max(index + Int((value.translation.height / rowHeight).rounded()), 0), feeds.count - 1)
                                    if target != index {
                                        onMove(IndexSet(integer: index), target > index ? target + 1 : target)
                                    }
                                }
                        )
                        .accessibilityLabel("Reorder \(feed.name)")
                }
                .frame(height: rowHeight)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .overlay(alignment: .bottom) {
                    if index < feeds.count - 1 { Divider() }
                }
                .offset(y: offset(for: index))
                .zIndex(draggedID == feed.id ? 1 : 0)
                .animation(draggedID == feed.id ? nil : .easeInOut(duration: 0.15), value: targetIndex)
                .accessibilityAction(named: "Move up") {
                    if index > 0 { onMove(IndexSet(integer: index), index - 1) }
                }
                .accessibilityAction(named: "Move down") {
                    if index < feeds.count - 1 { onMove(IndexSet(integer: index), index + 2) }
                }
            }
        }
    }

    private func offset(for index: Int) -> CGFloat {
        guard let sourceIndex, let targetIndex else { return 0 }
        if index == sourceIndex { return dragOffset }
        if sourceIndex < index && index <= targetIndex { return -rowHeight }
        if targetIndex <= index && index < sourceIndex { return rowHeight }
        return 0
    }
}
