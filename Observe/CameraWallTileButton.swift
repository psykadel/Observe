import SwiftUI

struct CameraWallTileButton: View {
    @ObservedObject var feed: CameraFeedCoordinator

    let fixedWidth: CGFloat?
    let fixedHeight: CGFloat?
    let staleVisualThreshold: TimeInterval
    let isBatteryCamera: Bool
    let showsName: Bool
    let showsBatteryPercentage: Bool
    let surfaceMode: CameraSurfaceMode
    let onSelect: () -> Void

    init(
        feed: CameraFeedCoordinator,
        fixedWidth: CGFloat?,
        fixedHeight: CGFloat?,
        staleVisualThreshold: TimeInterval,
        isBatteryCamera: Bool,
        showsName: Bool,
        showsBatteryPercentage: Bool,
        surfaceMode: CameraSurfaceMode = .wall,
        onSelect: @escaping () -> Void
    ) {
        self.feed = feed
        self.fixedWidth = fixedWidth
        self.fixedHeight = fixedHeight
        self.staleVisualThreshold = staleVisualThreshold
        self.isBatteryCamera = isBatteryCamera
        self.showsName = showsName
        self.showsBatteryPercentage = showsBatteryPercentage
        self.surfaceMode = surfaceMode
        self.onSelect = onSelect
    }

    var body: some View {
        Button(action: onSelect) {
            CameraTileView(
                feed: feed,
                fixedWidth: fixedWidth,
                fixedHeight: fixedHeight,
                staleVisualThreshold: staleVisualThreshold,
                isBatteryCamera: isBatteryCamera,
                showsName: showsName,
                showsBatteryPercentage: showsBatteryPercentage,
                surfaceMode: surfaceMode
            )
        }
        .buttonStyle(.plain)
    }
}
