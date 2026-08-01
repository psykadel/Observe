import HomeKit
import SwiftUI

struct CameraWallView: View {
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var store: HomeKitCameraStore
    @ObservedObject var preferences: ObservePreferences

    @State private var selectedFeed: CameraFeedCoordinator?
    @State private var showsSettings = false
    @State private var hasRequestedLaunchMaximize = false
    @State private var showsRestrictedStartupOverlay = false
    @State private var successIndicatorOpenState = SuccessIndicatorOpenState()
    @State private var successIndicatorAnimationID: UUID?

    private var wallPlatform: CameraWallPlatform { .current }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            content
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsRestrictedStartupOverlay,
               let presentation = store.restrictedStartupOverlayPresentation {
                RestrictedStartupOverlay(
                    presentation: presentation,
                    homeHubState: store.homeHubState
                )
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if let successIndicatorAnimationID {
                SuccessIndicatorGlow(cornerRadius: successIndicatorCornerRadius)
                    .id(successIndicatorAnimationID)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                if preferences.isLockStatusEnabled {
                    lockStatusIndicator
                }

                if preferences.isHomeTemperatureEnabled {
                    temperatureStatusIndicator
                }

                Spacer(minLength: 8)

                if showsBatteryCameraToggle {
                    Button {
                        store.setBatteryCameraVisibilityEnabled(!preferences.isBatteryCameraVisibilityEnabled)
                    } label: {
                        Image(systemName: preferences.isBatteryCameraVisibilityEnabled ? "video.fill" : "video.slash.fill")
                            .foregroundStyle(preferences.isBatteryCameraVisibilityEnabled ? .white : .white.opacity(0.58))
                            .wallStatusControlStyle()
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
                        .foregroundStyle(.white)
                        .wallStatusControlStyle()
                }
                .accessibilityLabel("Settings")
            }
            .padding(.top, 8)
            .padding(.horizontal, 10)
        }
        .sheet(isPresented: $showsSettings) {
            settingsSheet
        }
        .fullScreenCover(item: $selectedFeed) { feed in
            CameraDetailView(feed: feed, store: store)
        }
        .onAppear {
            beginSuccessIndicatorOpen()
        }
        .onChange(of: store.isSuccessIndicatorHealthy) { _, isHealthy in
            evaluateSuccessIndicator(isHealthy: isHealthy)
        }
        .onChange(of: preferences.isSuccessIndicatorEnabled) { _, isEnabled in
            if isEnabled {
                evaluateSuccessIndicator(isHealthy: store.isSuccessIndicatorHealthy)
            } else {
                successIndicatorAnimationID = nil
            }
        }
        .onChange(of: showsSettings) { _, isPresented in
            guard !isPresented else { return }
            evaluateSuccessIndicator(isHealthy: store.isSuccessIndicatorHealthy)
        }
        .onChange(of: selectedFeed?.id) { _, selectedFeedID in
            guard selectedFeedID == nil else { return }
            evaluateSuccessIndicator(isHealthy: store.isSuccessIndicatorHealthy)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                beginSuccessIndicatorOpen()
            }
            if CameraWallPresentation.shouldClearSelection(
                scenePhase: phase,
                hasSelectedFeed: selectedFeed != nil
            ) {
                selectedFeed = nil
            }
        }
        .task(id: store.restrictedStartupOverlayPresentation != nil) {
            guard store.restrictedStartupOverlayPresentation != nil else {
                withAnimation(.easeOut(duration: 0.16)) {
                    showsRestrictedStartupOverlay = false
                }
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  store.restrictedStartupOverlayPresentation != nil else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showsRestrictedStartupOverlay = true
            }
        }
        .task(id: successIndicatorAnimationID) {
            guard let animationID = successIndicatorAnimationID else { return }
            do {
                try await Task.sleep(for: .seconds(SuccessIndicatorAnimationTimeline.duration))
            } catch {
                return
            }
            guard !Task.isCancelled, successIndicatorAnimationID == animationID else { return }
            successIndicatorAnimationID = nil
        }
        .maximizeMainWindowOnLaunch(
            platform: wallPlatform,
            hasRequestedMaximize: $hasRequestedLaunchMaximize
        )
    }

    private var successIndicatorCornerRadius: CGFloat {
        switch wallPlatform {
        case .iPhone: 34
        case .mac: 14
        }
    }

    private func evaluateSuccessIndicator(isHealthy: Bool) {
        guard !showsSettings, selectedFeed == nil else { return }
        guard successIndicatorOpenState.shouldAnimate(
            isEnabled: preferences.isSuccessIndicatorEnabled,
            isHealthy: isHealthy
        ) else { return }

        successIndicatorAnimationID = UUID()
    }

    private func beginSuccessIndicatorOpen() {
        successIndicatorAnimationID = nil
        successIndicatorOpenState.beginOpen()
        evaluateSuccessIndicator(isHealthy: store.isSuccessIndicatorHealthy)
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

    private var lockStatusIndicator: some View {
        let presentation: (systemName: String, color: Color, value: String) = switch store.lockIndicatorState {
        case .loading:
            ("lock.fill", .gray, "Loading")
        case .locked:
            ("lock.fill", .green, "All Selected Locks Are Locked")
        case .alert:
            ("lock.open.fill", .red, "A Selected Lock Is Not Confirmed Locked")
        }

        return Image(systemName: presentation.systemName)
            .foregroundStyle(presentation.color)
            .wallStatusControlStyle()
            .accessibilityElement()
            .accessibilityLabel("Lock Status")
            .accessibilityValue(presentation.value)
    }

    private var temperatureStatusIndicator: some View {
        let presentation: (text: String, color: Color, value: String) = switch store.temperatureIndicatorState {
        case .loading:
            ("—°", .gray, "Loading")
        case .alert:
            ("—°", .red, "Temperature Unavailable")
        case .value(let temperature, let isInRange):
            (
                "\(temperature)°",
                isInRange ? .green : .red,
                "\(temperature) Degrees Fahrenheit, \(isInRange ? "Within Range" : "Outside Range")"
            )
        }

        return Text(presentation.text)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(presentation.color)
            .wallStatusControlStyle()
            .accessibilityElement()
            .accessibilityLabel("Home Temperature")
            .accessibilityValue(presentation.value)
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

struct RestrictedStartupOverlay: View {
    let presentation: RestrictedStartupOverlayPresentation
    let homeHubState: HMHomeHubState

    private var hubPresentation: (icon: String, color: Color, text: String) {
        switch homeHubState {
        case .connected:
            ("checkmark.circle.fill", .green, "Home Hub Connected")
        case .disconnected:
            ("exclamationmark.circle.fill", .yellow, "Home Hub Disconnected")
        case .notAvailable:
            ("minus.circle.fill", .white.opacity(0.48), "Home Hub Not Available")
        @unknown default:
            ("questionmark.circle.fill", .white.opacity(0.48), "Home Hub Status Unknown")
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.44)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                statusRow(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    text: "Home Found"
                )
                statusRow(
                    icon: hubPresentation.icon,
                    color: hubPresentation.color,
                    text: hubPresentation.text
                )

                Divider()
                    .overlay(.white.opacity(0.14))

                HStack(alignment: .top, spacing: 13) {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.white.opacity(0.68))
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(presentation.cameraCountText)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)

                        Text(presentation.activityText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 390, alignment: .leading)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 30, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Restricted Mode Startup")
        .accessibilityValue(
            "Home Found. \(hubPresentation.text). \(presentation.cameraCountText). \(presentation.activityText)."
        )
    }

    private func statusRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 26)

            Text(text)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }
}

private struct SuccessIndicatorGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let cornerRadius: CGFloat
    let reduceMotionOverride: Bool?

    @State private var startedAt: Date?

    private let glowColor = Color(red: 0.18, green: 1, blue: 0.34)
    private let electricGreen = Color(red: 0.4, green: 1, blue: 0.58)

    init(cornerRadius: CGFloat, reduceMotionOverride: Bool? = nil) {
        self.cornerRadius = cornerRadius
        self.reduceMotionOverride = reduceMotionOverride
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = startedAt.map { context.date.timeIntervalSince($0) } ?? 0
            let usesReducedMotion = reduceMotionOverride ?? reduceMotion
            let presentation = SuccessIndicatorAnimationTimeline.presentation(
                at: elapsed,
                reduceMotion: usesReducedMotion
            )

            GeometryReader { proxy in
                ZStack {
                    radiantAura(presentation: presentation)
                    resolvedCore(presentation: presentation)

                    if !usesReducedMotion {
                        travelingCurrent(presentation: presentation)
                        chasingTrails(presentation: presentation)
                    }

                    SuccessIndicatorSparkles(
                        elapsed: elapsed,
                        intensity: presentation.sparkleIntensity,
                        color: electricGreen
                    )
                    .padding(6)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .compositingGroup()
                .blendMode(.screen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear {
            startedAt = Date()
        }
    }

    private func rimShape(inset: CGFloat = 5) -> some InsettableShape {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .inset(by: inset)
    }

    private func radiantAura(
        presentation: SuccessIndicatorAnimationPresentation
    ) -> some View {
        ZStack {
            rimShape()
                .stroke(glowColor.opacity(0.4), lineWidth: 13)
                .blur(radius: 7 + (8 * presentation.radiance))

            rimShape()
                .stroke(electricGreen.opacity(0.22), lineWidth: 24)
                .blur(radius: 15 + (10 * presentation.radiance))

            rimShape(inset: 7)
                .stroke(glowColor.opacity(0.16), lineWidth: 34)
                .blur(radius: 24)
        }
        .opacity(presentation.radiance * presentation.drawProgress)
    }

    private func resolvedCore(
        presentation: SuccessIndicatorAnimationPresentation
    ) -> some View {
        rimShape()
            .trim(from: 0, to: presentation.drawProgress)
            .stroke(
                AngularGradient(
                    colors: [
                        glowColor.opacity(0.62),
                        electricGreen,
                        .white.opacity(0.94),
                        glowColor,
                        glowColor.opacity(0.62)
                    ],
                    center: .center,
                    angle: .degrees(presentation.trailPhase * 360)
                ),
                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: glowColor.opacity(0.95), radius: 5)
            .shadow(color: electricGreen.opacity(0.7), radius: 11)
            .opacity(presentation.coreOpacity)
    }

    private func travelingCurrent(
        presentation: SuccessIndicatorAnimationPresentation
    ) -> some View {
        SuccessIndicatorTrail(
            cornerRadius: cornerRadius,
            start: presentation.trailPhase,
            length: 0.18,
            lineWidth: 8,
            color: .white
        )
        .shadow(color: electricGreen, radius: 8)
        .shadow(color: glowColor, radius: 16)
        .opacity(presentation.trailOpacity)
    }

    private func chasingTrails(
        presentation: SuccessIndicatorAnimationPresentation
    ) -> some View {
        ZStack {
            SuccessIndicatorTrail(
                cornerRadius: cornerRadius,
                start: presentation.trailPhase - 0.11,
                length: 0.09,
                lineWidth: 4,
                color: electricGreen
            )
            SuccessIndicatorTrail(
                cornerRadius: cornerRadius,
                start: presentation.trailPhase - 0.22,
                length: 0.055,
                lineWidth: 3,
                color: glowColor
            )
        }
        .blur(radius: 1.2)
        .opacity(presentation.trailOpacity * 0.82)
    }
}

private struct SuccessIndicatorTrail: View {
    let cornerRadius: CGFloat
    let start: Double
    let length: Double
    let lineWidth: CGFloat
    let color: Color

    private var normalizedStart: Double {
        let remainder = start.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    var body: some View {
        let end = normalizedStart + length
        ZStack {
            segment(from: normalizedStart, to: min(end, 1))
            if end > 1 {
                segment(from: 0, to: end - 1)
            }
        }
    }

    private func segment(from: Double, to: Double) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .inset(by: 5)
            .trim(from: from, to: to)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
    }
}

private struct SuccessIndicatorSparkles: View {
    let elapsed: TimeInterval
    let intensity: Double
    let color: Color

    private let seeds: [(x: Double, y: Double, phase: Double, size: Double)] = [
        (0.11, 0.012, 0.03, 7),
        (0.34, 0.01, 0.41, 4),
        (0.72, 0.012, 0.72, 6),
        (0.985, 0.16, 0.18, 5),
        (0.988, 0.47, 0.56, 7),
        (0.986, 0.81, 0.87, 4),
        (0.78, 0.988, 0.34, 6),
        (0.48, 0.99, 0.66, 5),
        (0.17, 0.987, 0.94, 7),
        (0.012, 0.76, 0.49, 4),
        (0.014, 0.43, 0.79, 6),
        (0.013, 0.19, 0.12, 5)
    ]

    var body: some View {
        Canvas { context, size in
            guard intensity > 0 else { return }

            for seed in seeds {
                let twinkle = 0.35 + (0.65 * abs(sin((elapsed * 5.4) + (seed.phase * .pi * 2))))
                let opacity = intensity * twinkle
                let center = CGPoint(x: size.width * seed.x, y: size.height * seed.y)
                let radius = seed.size * (0.72 + (0.28 * twinkle))
                let sparkle = sparklePath(center: center, radius: radius)

                context.drawLayer { glowContext in
                    glowContext.addFilter(.blur(radius: 3.5))
                    glowContext.fill(sparkle, with: .color(color.opacity(opacity)))
                }
                context.fill(sparkle, with: .color(.white.opacity(opacity * 0.92)))
            }
        }
        .allowsHitTesting(false)
    }

    private func sparklePath(center: CGPoint, radius: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addLine(to: CGPoint(x: center.x + radius * 0.2, y: center.y - radius * 0.2))
        path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x + radius * 0.2, y: center.y + radius * 0.2))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        path.addLine(to: CGPoint(x: center.x - radius * 0.2, y: center.y + radius * 0.2))
        path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x - radius * 0.2, y: center.y - radius * 0.2))
        path.closeSubpath()
        return path
    }
}

#if DEBUG
#Preview("Restricted Startup") {
    RestrictedStartupOverlay(
        presentation: RestrictedStartupOverlayPresentation(
            cameraCount: 7,
            checkingCount: 3,
            waitingCount: 4,
            retryingCount: 0
        ),
        homeHubState: .connected
    )
    .background(Color.black)
}

#Preview("Success Indicator Glow") {
    ZStack {
        SuccessIndicatorGlowPreviewWall()
        SuccessIndicatorGlow(cornerRadius: 34, reduceMotionOverride: false)
    }
    .frame(width: 390, height: 844)
}

#Preview("Success Indicator Glow — Reduce Motion") {
    ZStack {
        SuccessIndicatorGlowPreviewWall()
        SuccessIndicatorGlow(cornerRadius: 34, reduceMotionOverride: true)
    }
    .frame(width: 390, height: 844)
}

private struct SuccessIndicatorGlowPreviewWall: View {
    private let tileGradient = LinearGradient(
        colors: [.gray.opacity(0.66), .black, .green.opacity(0.16)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                VStack(spacing: 8) {
                    previewTile(height: proxy.size.height * 0.25)
                    previewTile(height: proxy.size.height * 0.25)
                    previewTile(height: proxy.size.height * 0.2)
                    HStack(spacing: 8) {
                        previewTile(height: proxy.size.height * 0.18)
                        previewTile(height: proxy.size.height * 0.18)
                    }
                }
                .frame(width: max(0, proxy.size.width - 16))
                .padding(8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func previewTile(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(tileGradient)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 7) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Live").font(.caption.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.82))
                .padding(14)
            }
    }
}
#endif

private extension View {
    func wallStatusControlStyle() -> some View {
        font(.subheadline.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
    }
}
