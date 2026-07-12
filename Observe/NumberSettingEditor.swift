import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum NumberSettingKind: String, CaseIterable, Identifiable {
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

    var minimumValue: Int {
        switch self {
        case .staleThreshold, .batteryWakeTrigger, .batteryCaptureWarmup, .batteryStale:
            1
        }
    }

    var defaultValue: Int {
        switch self {
        case .staleThreshold:
            Int(CameraSchedulingDefaults.staleVisualHighlightThreshold)
        case .batteryWakeTrigger:
            Int(CameraSchedulingDefaults.batteryWakeTriggerThreshold)
        case .batteryCaptureWarmup:
            Int(CameraSchedulingDefaults.batteryCaptureWarmup)
        case .batteryStale:
            Int(CameraSchedulingDefaults.batteryStaleThreshold)
        }
    }

    var unitName: String {
        switch self {
        case .staleThreshold, .batteryWakeTrigger, .batteryCaptureWarmup, .batteryStale:
            "seconds"
        }
    }

    var shortUnit: String {
        switch self {
        case .staleThreshold, .batteryWakeTrigger, .batteryCaptureWarmup, .batteryStale:
            "s"
        }
    }

    func displayValue(_ value: Int) -> String {
        switch self {
        case .staleThreshold, .batteryWakeTrigger, .batteryCaptureWarmup, .batteryStale:
            "\(value) sec"
        }
    }

    func presetLabel(_ value: Int) -> String {
        "\(value)\(shortUnit)"
    }

    var helperText: String? {
        switch self {
        case .staleThreshold:
            nil
        case .batteryWakeTrigger:
            "When a battery camera still gets this old, start a live capture."
        case .batteryCaptureWarmup:
            "After live starts, wait this long before saving the still."
        case .batteryStale:
            "Mark a battery still stale when it gets this old."
        }
    }
}

struct NumberSettingDraft: Equatable {
    private(set) var value: Int
    private(set) var text: String
    let minimumValue: Int

    init(value: Int, minimumValue: Int) {
        self.minimumValue = max(0, minimumValue)
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

struct NumberSettingRow: View {
    let title: String
    let valueText: String
    var helperText: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(valueText)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                if let helperText {
                    Text(helperText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NumberSettingEditor: View {
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
        if isMac {
            VStack(spacing: 0) {
                macHeader
                editorContent
            }
            .background(Color(UIColor.systemGroupedBackground))
            .frame(height: 600)
        } else {
            NavigationStack {
                editorContent
                    .navigationTitle(setting.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                dismiss()
                            } label: {
                                toolbarButtonLabel("Cancel")
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button {
                                value = draft.value
                                dismiss()
                            } label: {
                                toolbarButtonLabel("Done")
                            }
                        }
                    }
            }
        }
    }

    private var isMac: Bool {
        CameraWallPlatform.current == .mac
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { draft.text },
            set: { draft.updateText($0) }
        )
    }

    private var editorContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                currentValueCard

                HStack(spacing: 12) {
                    adjustmentButton(systemName: "minus", delta: -setting.step)
                    adjustmentButton(systemName: "plus", delta: setting.step)
                }

                TextField(setting.unitName.capitalized, text: textBinding)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title3.monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                presetGrid

                resetButton
            }
            .padding(.horizontal, 24)
            .padding(.top, isMac ? 26 : 22)
            .padding(.bottom, isMac ? 36 : 30)
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    private var macHeader: some View {
        HStack(spacing: 16) {
            macToolbarButton("Cancel") {
                dismiss()
            }

            Text(setting.title)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)

            macToolbarButton("Done") {
                value = draft.value
                dismiss()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func macToolbarButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .frame(width: 92, height: 38)
                .background(
                    Color(UIColor.secondarySystemGroupedBackground),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func toolbarButtonLabel(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 64)
    }

    private var currentValueCard: some View {
        VStack(spacing: 4) {
            Text(setting.displayValue(draft.value))
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(setting.unitName)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var presetGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            spacing: 10
        ) {
            ForEach(setting.presets, id: \.self) { preset in
                Button(setting.presetLabel(preset)) {
                    draft.setValue(preset)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var resetButton: some View {
        Button {
            draft.setValue(setting.defaultValue)
        } label: {
            HStack {
                Label("Reset to Default", systemImage: "arrow.counterclockwise")
                Spacer()
                Text(setting.displayValue(setting.defaultValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func adjustmentButton(systemName: String, delta: Int) -> some View {
        Button {
            draft.adjust(by: delta)
        } label: {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.bordered)
        .tint(.accentColor)
        .accessibilityLabel(delta < 0 ? "Decrease" : "Increase")
    }
}
