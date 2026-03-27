import SwiftUI

struct CameraTileView: View {
    @ObservedObject var feed: CameraFeedCoordinator
    let fixedWidth: CGFloat?
    let fixedHeight: CGFloat?

    private let tileAspectRatio: CGFloat = 16 / 9

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CameraSurfaceView(
                cameraSource: feed.cameraSource,
                aspectRatio: feed.displayAspectRatio,
                mode: .wall
            )
            .overlay {
                if feed.cameraSource == nil {
                    placeholder
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(feed.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                statusLine
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: fixedWidth)
        .frame(height: fixedHeight)
        .background(Color.black.opacity(0.92))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .aspectRatio(fixedHeight == nil ? tileAspectRatio : nil, contentMode: .fit)
    }

    @ViewBuilder
    private var statusLine: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let status = feed.status(at: context.date)

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
    }

    private func statusColor(for status: CameraStatusSnapshot) -> Color {
        if status.isLive {
            return .green
        }

        if feed.state == .starting || feed.state == .idle {
            return Color.white.opacity(0.4)
        }

        if let snapshotDate = feed.lastSnapshotDate {
            let age = Date().timeIntervalSince(snapshotDate)
            return age <= 10 ? .yellow : .red
        }

        return Color.white.opacity(0.4)
    }

    private var placeholder: some View {
        ZStack {
            Color.black

            VStack(spacing: 10) {
                Image(systemName: "video.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))

                Text(feed.status(at: .now).label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.66))
            }
        }
    }
}
