import HomeKit
import SwiftUI

struct CameraWallView: View {
    @ObservedObject var store: HomeKitCameraStore
    @ObservedObject var preferences: ObservePreferences

    @State private var selectedFeed: CameraFeedCoordinator?
    @State private var showsSettings = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            content
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 6)

            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(store: store, preferences: preferences)
        }
        .fullScreenCover(item: $selectedFeed) { feed in
            CameraDetailView(feed: feed, store: store)
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
                    title: "No Cameras Online",
                    subtitle: "Observe hides offline cameras from the wall until they reconnect."
                )
            } else {
                cameraGrid
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

    private var cameraGrid: some View {
        GeometryReader { proxy in
            let layout = CameraWallLayout(
                density: preferences.wallDensity,
                availableSize: proxy.size,
                cameraCount: store.wallFeeds.count
            )
            let items = layout.items(for: store.wallFeeds)

            ScrollView(.vertical, showsIndicators: layout.requiresScrolling) {
                LazyVGrid(columns: layout.columns, spacing: layout.spacing) {
                    ForEach(items) { item in
                        switch item {
                        case .feed(let feed):
                            Button {
                                store.focusOn(feed: feed)
                                selectedFeed = feed
                            } label: {
                                CameraTileView(
                                    feed: feed,
                                    fixedWidth: layout.tileWidth,
                                    fixedHeight: layout.tileHeight,
                                    staleVisualThreshold: preferences.staleVisualHighlightThreshold
                                )
                            }
                            .buttonStyle(.plain)
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
            .gesture(
                MagnifyGesture()
                    .onEnded { value in
                        store.adjustDensity(with: value.magnification)
                    }
            )
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
    }
}

private struct CameraWallLayout {
    let density: WallDensity
    let availableSize: CGSize
    let cameraCount: Int

    let spacing: CGFloat = 8

    var tileWidth: CGFloat {
        let usableWidth = max(availableSize.width - CGFloat(max(0, density.columnCount - 1)) * spacing, 0)
        return floor(usableWidth / CGFloat(density.columnCount))
    }

    var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(tileWidth), spacing: spacing, alignment: .top),
            count: density.columnCount
        )
    }

    var tileHeight: CGFloat? {
        let visibleRows = density.preferredVisibleRows
        let totalSpacing = CGFloat(max(0, visibleRows - 1)) * spacing
        let usableHeight = max(availableSize.height - totalSpacing, 0)
        return floor(usableHeight / CGFloat(visibleRows))
    }

    var requiresScrolling: Bool {
        if cameraCount <= density.visibleCameraCount {
            return false
        }

        guard let tileHeight else { return true }
        let rowCount = Int(ceil(Double(cameraCount) / Double(density.columnCount)))
        let totalHeight = CGFloat(rowCount) * tileHeight + CGFloat(max(0, rowCount - 1)) * spacing
        return totalHeight > availableSize.height
    }

    func items(for feeds: [CameraFeedCoordinator]) -> [CameraWallItem] {
        var items = feeds.map(CameraWallItem.feed)

        if density == .twoColumns, feeds.count.isMultiple(of: 2) == false {
            items.append(.placeholder(id: "wall-placeholder"))
        }
        return items
    }
}

private enum CameraWallItem: Identifiable {
    case feed(CameraFeedCoordinator)
    case placeholder(id: String)

    var id: String {
        switch self {
        case .feed(let feed):
            feed.id
        case .placeholder(let id):
            id
        }
    }
}
