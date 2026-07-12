import SwiftUI

struct CameraWallView: View {
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var store: HomeKitCameraStore
    @ObservedObject var preferences: ObservePreferences

    @State private var selectedFeed: CameraFeedCoordinator?
    @State private var showsSettings = false
    @State private var hasRequestedLaunchMaximize = false

    private var wallPlatform: CameraWallPlatform { .current }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            content
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                if showsBatteryCameraToggle {
                    Button {
                        store.setBatteryCameraVisibilityEnabled(!preferences.isBatteryCameraVisibilityEnabled)
                    } label: {
                        Image(systemName: preferences.isBatteryCameraVisibilityEnabled ? "video.fill" : "video.slash.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(preferences.isBatteryCameraVisibilityEnabled ? .white : .white.opacity(0.58))
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(
                        preferences.isBatteryCameraVisibilityEnabled
                            ? "Hide Battery Cameras"
                            : "Show Battery Cameras"
                    )
                    .accessibilityValue(preferences.isBatteryCameraVisibilityEnabled ? "Enabled" : "Disabled")
                }

                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Settings")
            }
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
        .sheet(isPresented: $showsSettings) {
            settingsSheet
        }
        .fullScreenCover(item: $selectedFeed) { feed in
            CameraDetailView(feed: feed, store: store)
        }
        .onChange(of: scenePhase) { _, phase in
            if CameraWallPresentation.shouldClearSelection(
                scenePhase: phase,
                hasSelectedFeed: selectedFeed != nil
            ) {
                selectedFeed = nil
            }
        }
        .maximizeMainWindowOnLaunch(
            platform: wallPlatform,
            hasRequestedMaximize: $hasRequestedLaunchMaximize
        )
    }

    @ViewBuilder
    private var settingsSheet: some View {
        switch wallPlatform {
        case .mac:
            SettingsView(store: store, preferences: preferences)
                .frame(height: 600)
                .presentationDetents([.height(600), .large])
        case .iPhone:
            SettingsView(store: store, preferences: preferences)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.authorizationStatus.contains(.authorized) {
            if store.homes.isEmpty {
                placeholder(
                    title: "No Homes Found",
                    subtitle: "Add a Home in Apple Home, then reopen Observe."
                )
            } else if store.feeds.isEmpty {
                placeholder(
                    title: "No Cameras Found",
                    subtitle: "Observe shows HomeKit camera accessories from the selected home."
                )
            } else if store.wallFeeds.isEmpty {
                placeholder(
                    title: "No Active Cameras",
                    subtitle: noActiveCamerasSubtitle
                )
            } else {
                cameraWall
            }
        } else if store.authorizationStatus.contains(.determined) || store.authorizationStatus.contains(.restricted) {
            placeholder(
                title: "Allow Home Access",
                subtitle: "Observe needs Home access to load your cameras."
            )
        } else {
            placeholder(
                title: "Home Status Unknown",
                subtitle: "Reopen Observe after Home access is available."
            )
        }
    }

    @ViewBuilder
    private var cameraWall: some View {
        let density = preferences.effectiveWallDensity(for: wallPlatform)
        if density == .auto {
            cameraAutoWall
        } else {
            cameraGrid
        }
    }

    private var cameraGrid: some View {
        GeometryReader { proxy in
            let density = preferences.effectiveWallDensity(for: wallPlatform)
            let layout = CameraWallLayout(
                density: density,
                availableSize: proxy.size,
                cameraCount: store.wallFeeds.count
            )
            let items = layout.items(for: store.wallFeeds)
            let showsNames = preferences.cameraNameVisibility.showsName(
                isOneColumnLayout: density == .oneColumn
            )

            ScrollView(.vertical, showsIndicators: layout.requiresScrolling) {
                LazyVGrid(columns: layout.columns, spacing: layout.spacing) {
                    ForEach(items) { item in
                        switch item {
                        case .feed(let feed):
                            cameraTileButton(
                                feed: feed,
                                width: layout.tileWidth,
                                height: layout.tileHeight,
                                showsName: showsNames
                            )
                        case .placeholder:
                            Color.clear
                                .frame(width: layout.tileWidth, height: layout.tileHeight)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(minHeight: layout.requiresScrolling ? nil : proxy.size.height, alignment: .top)
            }
            .scrollDisabled(!layout.requiresScrolling)
            .gesture(densityGesture)
            .simultaneousGesture(wallSwipeGesture)
        }
    }

    private var showsBatteryCameraToggle: Bool {
        BatteryCameraVisibilityPolicy.showsToggle(
            showsSetting: preferences.showsBatteryCameraVisibilityToggle,
            hasBatteryCameras: store.hasBatteryWakeCameras
        )
    }

    private var noActiveCamerasSubtitle: String {
        if preferences.showsBatteryCameraVisibilityToggle,
           !preferences.isBatteryCameraVisibilityEnabled,
           store.hasBatteryWakeCameras {
            return "Battery cameras are hidden by the battery camera toggle."
        }

        return "Observe hides cameras only when HomeKit reports them as off."
    }

    @ViewBuilder
    private var cameraAutoWall: some View {
        switch wallPlatform {
        case .iPhone:
            cameraPhoneAutoWall
        case .mac:
            cameraMacAutoWall
        }
    }

    private var cameraPhoneAutoWall: some View {
        GeometryReader { proxy in
            let layout = CameraWallAutoLayout(availableSize: proxy.size)
            let visibleFeeds = Array(store.wallFeeds.prefix(CameraWallAutoLayout.maxCameraCount))
            let cameras = visibleFeeds.map {
                CameraWallAutoLayout.Camera(id: $0.id, aspectRatio: $0.displayAspectRatio)
            }
            let tiles = layout.tiles(for: cameras)
            let oneColumnTileIDs = CameraWallNamePresentation.oneColumnTileIDs(in: tiles)
            let feedsByID = Dictionary(uniqueKeysWithValues: visibleFeeds.map { ($0.id, $0) })

            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    if let feed = feedsByID[tile.id] {
                        cameraTileButton(
                            feed: feed,
                            width: tile.frame.width,
                            height: tile.frame.height,
                            showsName: preferences.cameraNameVisibility.showsName(
                                isOneColumnLayout: oneColumnTileIDs.contains(tile.id)
                            ),
                            surfaceMode: .wallFit
                        )
                        .frame(width: tile.frame.width, height: tile.frame.height)
                        .position(x: tile.frame.midX, y: tile.frame.midY)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .gesture(densityGesture)
            .simultaneousGesture(wallSwipeGesture)
        }
    }

    private var cameraMacAutoWall: some View {
        GeometryReader { proxy in
            let layout = CameraWallMacAutoLayout(availableSize: proxy.size)
            let visibleFeeds = store.wallFeeds
            let cameras = visibleFeeds.map {
                CameraWallAutoLayout.Camera(id: $0.id, aspectRatio: $0.displayAspectRatio)
            }
            let result = layout.layout(for: cameras)
            let oneColumnTileIDs = CameraWallNamePresentation.oneColumnTileIDs(in: result.tiles)
            let feedsByID = Dictionary(uniqueKeysWithValues: visibleFeeds.map { ($0.id, $0) })

            ZStack(alignment: .topLeading) {
                ForEach(result.tiles) { tile in
                    if let feed = feedsByID[tile.id] {
                        cameraTileButton(
                            feed: feed,
                            width: tile.frame.width,
                            height: tile.frame.height,
                            showsName: preferences.cameraNameVisibility.showsName(
                                isOneColumnLayout: oneColumnTileIDs.contains(tile.id)
                            ),
                            surfaceMode: .wallFit
                        )
                        .frame(width: tile.frame.width, height: tile.frame.height)
                        .position(x: tile.frame.midX, y: tile.frame.midY)
                    }
                }
            }
            .frame(width: result.contentSize.width, height: result.contentSize.height)
        }
    }

    private var densityGesture: some Gesture {
        MagnifyGesture()
            .onEnded { value in
                store.adjustDensity(with: value.magnification)
            }
    }

    private func cameraTileButton(
        feed: CameraFeedCoordinator,
        width: CGFloat?,
        height: CGFloat?,
        showsName: Bool,
        surfaceMode: CameraSurfaceMode = .wall
    ) -> some View {
        let isBatteryCamera = preferences.isBatteryWakeCamera(id: feed.id)
        return CameraWallTileButton(
            feed: feed,
            fixedWidth: width,
            fixedHeight: height,
            staleVisualThreshold: isBatteryCamera
                ? preferences.batteryStaleThreshold
                : preferences.staleVisualHighlightThreshold,
            isBatteryCamera: isBatteryCamera,
            showsName: showsName,
            showsBatteryPercentage: preferences.showsBatteryPercentages,
            surfaceMode: surfaceMode
        ) {
            store.focusOn(feed: feed)
            selectedFeed = feed
        }
    }

    private var wallSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 36)
            .onEnded { value in
                let width = value.translation.width
                let height = value.translation.height
                guard abs(width) > abs(height) * 1.5 else { return }

                store.adjustDensity(withHorizontalSwipe: width)
            }
    }

    private func placeholder(title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "video.badge.ellipsis")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
