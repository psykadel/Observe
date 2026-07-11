import SwiftUI

struct CameraTileView: View {
    @ObservedObject var feed: CameraFeedCoordinator
    let fixedWidth: CGFloat?
    let fixedHeight: CGFloat?
    let staleVisualThreshold: TimeInterval
    let isBatteryCamera: Bool
    var showsName = true
    var showsBatteryPercentage = false
    var surfaceMode: CameraSurfaceMode = .wall

    private let tileAspectRatio: CGFloat = 16 / 9

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = feed.status(at: context.date)
            let initialPresentation = InitialCameraTilePolicy.presentation(
                hasFreshImageThisSession: feed.hasFreshImageThisSession,
                displayedStillDate: feed.cameraSource == nil ? nil : feed.displayedStillDate,
                staleThreshold: staleVisualThreshold,
                now: context.date
            )
            let showsLaunchPlaceholder = initialPresentation == .launchPlaceholder
            let displayedCameraSource = showsLaunchPlaceholder ? nil : feed.cameraSource
            let showsStaleBorder = showsLaunchPlaceholder
                || feed.isVisuallyStale(at: context.date, threshold: staleVisualThreshold)
            let showsPlaceholder = displayedCameraSource == nil
            let batteryPercentageLabel = BatteryPercentageOverlayPolicy.label(for: feed.batteryPercentage)
            let showsBatteryPercentageOverlay = BatteryPercentageOverlayPolicy.showsOverlay(
                showsBatteryPercentages: showsBatteryPercentage,
                isBatteryCamera: isBatteryCamera,
                batteryPercentage: feed.batteryPercentage
            )

            ZStack(alignment: .bottomLeading) {
                CameraSurfaceView(
                    cameraSource: displayedCameraSource,
                    aspectRatio: feed.displayAspectRatio,
                    mode: surfaceMode
                )
                .overlay {
                    if showsPlaceholder {
                        placeholder()
                    }
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 4) {
                    if showsName {
                        Text(feed.name)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }

                    if !showsLaunchPlaceholder {
                        statusLine(status: status)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(width: fixedWidth)
            .frame(height: fixedHeight)
            .background(Color.black.opacity(0.92))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(
                        showsStaleBorder ? Color.red.opacity(0.82) : Color.white.opacity(0.06),
                        lineWidth: showsStaleBorder ? 2 : 1
                    )
            }
            .overlay(alignment: .topTrailing) {
                if showsBatteryPercentageOverlay, let batteryPercentageLabel {
                    batteryPercentageOverlay(label: batteryPercentageLabel)
                        .padding(10)
                }
            }
            .aspectRatio(fixedHeight == nil ? tileAspectRatio : nil, contentMode: .fit)
        }
    }

    private func batteryPercentageOverlay(label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "battery.100percent")
                .font(.system(size: 10, weight: .semibold))

            Text(label)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.78))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.44), in: Capsule())
        .accessibilityLabel("Battery \(label)")
    }

    private func statusLine(status: CameraStatusSnapshot) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor(for: status))
                .frame(width: 8, height: 8)

            Text(status.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
    }

    private func statusColor(for status: CameraStatusSnapshot) -> Color {
        switch status.indicator {
        case .green:
            return .green
        case .yellow:
            return .yellow
        case .red:
            return .red
        case .neutral:
            return Color.white.opacity(0.4)
        }
    }

    private func placeholder() -> some View {
        ZStack {
            Color.black

            VStack(spacing: 10) {
                Image(systemName: "video.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
            }
        }
    }
}
