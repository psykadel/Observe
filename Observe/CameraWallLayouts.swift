import SwiftUI

enum CameraWallPresentation {
    static func shouldClearSelection(scenePhase: ScenePhase, hasSelectedFeed: Bool) -> Bool {
        hasSelectedFeed && scenePhase == .background
    }
}

enum CameraWallNamePresentation {
    static func oneColumnTileIDs(in tiles: [CameraWallAutoLayout.Tile]) -> Set<String> {
        let tilesByRow = Dictionary(grouping: tiles) { tile in
            Int((tile.frame.midY * 100).rounded())
        }

        return tilesByRow.values.reduce(into: Set<String>()) { result, rowTiles in
            guard rowTiles.count == 1, let tile = rowTiles.first else { return }
            result.insert(tile.id)
        }
    }
}

struct CameraWallLayout {
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
        if density == .oneColumn, availableSize.width > availableSize.height {
            return nil
        }

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

enum CameraWallItem: Identifiable {
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

struct CameraWallAutoLayout {
    struct Camera: Identifiable, Equatable {
        let id: String
        let aspectRatio: CGFloat
    }

    struct Tile: Identifiable, Equatable {
        let id: String
        let frame: CGRect
        let aspectRatio: CGFloat
    }

    static let maxCameraCount = 10

    let availableSize: CGSize
    let spacing: CGFloat

    init(availableSize: CGSize, spacing: CGFloat = 8) {
        self.availableSize = availableSize
        self.spacing = spacing
    }

    func tiles(for cameras: [Camera]) -> [Tile] {
        let normalizedCameras = cameras.prefix(Self.maxCameraCount).map { camera in
            Camera(id: camera.id, aspectRatio: normalizedAspectRatio(camera.aspectRatio))
        }
        guard !normalizedCameras.isEmpty, availableSize.width > 0, availableSize.height > 0 else {
            return []
        }

        return rowPartitions(for: normalizedCameras.count)
            .compactMap { candidateLayout(for: normalizedCameras, rowSizes: $0) }
            .max { $0.score < $1.score }?
            .tiles ?? []
    }

    private func candidateLayout(for cameras: [Camera], rowSizes: [Int]) -> CandidateLayout? {
        var rowStartIndex = 0
        let rows = rowSizes.map { rowSize in
            let endIndex = rowStartIndex + rowSize
            defer { rowStartIndex = endIndex }
            return Array(cameras[rowStartIndex..<endIndex])
        }

        let rowHeights = rows.map { row in
            let rowSpacing = CGFloat(max(0, row.count - 1)) * spacing
            let aspectSum = row.reduce(CGFloat.zero) { $0 + $1.aspectRatio }
            return max((availableSize.width - rowSpacing) / aspectSum, 0)
        }

        let rowSpacing = CGFloat(max(0, rows.count - 1)) * spacing
        let unscaledRowHeight = rowHeights.reduce(CGFloat.zero, +)
        let unscaledHeight = unscaledRowHeight + rowSpacing
        guard unscaledHeight > 0, unscaledRowHeight > 0 else { return nil }

        let availableRowHeight = max(availableSize.height - rowSpacing, 0)
        let scale = min(1, availableRowHeight / unscaledRowHeight)
        let scaledRowHeights = rowHeights.map { $0 * scale }
        let scaledRowHeight = scaledRowHeights.reduce(CGFloat.zero, +)
        let distributedGap = (availableSize.height - scaledRowHeight) / CGFloat(rows.count + 1)
        let usesDistributedGaps = rows.count > 1 && distributedGap >= spacing
        let interRowGap = usesDistributedGaps ? distributedGap : spacing
        let totalHeight = scaledRowHeight + CGFloat(max(0, rows.count - 1)) * interRowGap
        let startY = usesDistributedGaps
            ? distributedGap
            : max((availableSize.height - totalHeight) / 2, 0)

        var tiles: [Tile] = []
        var y = startY
        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = scaledRowHeights[rowIndex]
            let rowWidth = row.reduce(CGFloat.zero) { $0 + $1.aspectRatio * rowHeight }
                + CGFloat(max(0, row.count - 1)) * spacing
            var x = max((availableSize.width - rowWidth) / 2, 0)

            for camera in row {
                let width = camera.aspectRatio * rowHeight
                let frame = CGRect(x: x, y: y, width: width, height: rowHeight)
                tiles.append(Tile(id: camera.id, frame: frame, aspectRatio: camera.aspectRatio))
                x += width + spacing
            }

            y += rowHeight + interRowGap
        }

        guard tiles.allSatisfy({ $0.frame.width > 0 && $0.frame.height > 0 }) else {
            return nil
        }

        return CandidateLayout(tiles: tiles, score: score(tiles: tiles, rowSizes: rowSizes))
    }

    private func score(tiles: [Tile], rowSizes: [Int]) -> CGFloat {
        let containerArea = max(availableSize.width * availableSize.height, 1)
        let tileAreas = tiles.map { $0.frame.width * $0.frame.height }
        let usefulArea = tileAreas.reduce(CGFloat.zero, +)
        let coverageScore = usefulArea / containerArea

        let averageArea = usefulArea / CGFloat(max(tiles.count, 1))
        let smallestArea = tileAreas.min() ?? 0
        let smallestTileScore = smallestArea / max(averageArea, 1)

        let priorityScore = tileAreas.enumerated().reduce(CGFloat.zero) { partial, pair in
            let weight = CGFloat(tiles.count - pair.offset) / CGFloat(tiles.count)
            return partial + weight * (pair.element / max(usefulArea, 1))
        }

        let variance = tileAreas.reduce(CGFloat.zero) { partial, area in
            let delta = (area - averageArea) / max(averageArea, 1)
            return partial + delta * delta
        } / CGFloat(max(tileAreas.count, 1))

        return coverageScore * 1_000
            + priorityScore * 80
            + smallestTileScore * 30
            + portraitPriorityRowScore(rowSizes: rowSizes)
            - variance * 35
            - CGFloat(rowSizes.count) * 1.5
    }

    private func rowPartitions(for count: Int) -> [[Int]] {
        var partitions: [[Int]] = []
        let maximumRowSize = isPortrait ? 2 : 5

        func build(remaining: Int, minimumRowSize: Int, current: [Int]) {
            if remaining == 0 {
                partitions.append(current)
                return
            }

            let largestRowSize = min(maximumRowSize, remaining)
            guard minimumRowSize <= largestRowSize else { return }

            for rowSize in minimumRowSize...largestRowSize {
                build(
                    remaining: remaining - rowSize,
                    minimumRowSize: rowSize,
                    current: current + [rowSize]
                )
            }
        }

        build(remaining: count, minimumRowSize: 1, current: [])
        return partitions
    }

    private func portraitPriorityRowScore(rowSizes: [Int]) -> CGFloat {
        guard isPortrait, rowSizes.count > 1 else { return 0 }

        let cameraCount = rowSizes.reduce(0, +)
        let preferredSingleRows = cameraCount >= 6 ? 2 : cameraCount >= 4 ? 1 : 0
        guard preferredSingleRows > 0 else { return 0 }

        let leadingSingleRows = rowSizes.prefix { $0 == 1 }.count
        if leadingSingleRows >= preferredSingleRows {
            return CGFloat(preferredSingleRows) * 320
        }

        return CGFloat(leadingSingleRows - preferredSingleRows) * 320
    }

    private var isPortrait: Bool {
        availableSize.height >= availableSize.width
    }

    private func normalizedAspectRatio(_ aspectRatio: CGFloat) -> CGFloat {
        let safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9
        return max(0.75, min(safeAspectRatio, 2.2))
    }

    private struct CandidateLayout {
        let tiles: [Tile]
        let score: CGFloat
    }
}

struct CameraWallMacAutoLayout {
    struct Layout: Equatable {
        let tiles: [CameraWallAutoLayout.Tile]
        let contentSize: CGSize
    }

    static let minimumTileWidth: CGFloat = 24
    static let preferredTileWidth: CGFloat = 220

    let availableSize: CGSize
    let spacing: CGFloat

    init(availableSize: CGSize, spacing: CGFloat = 8) {
        self.availableSize = availableSize
        self.spacing = spacing
    }

    func layout(for cameras: [CameraWallAutoLayout.Camera]) -> Layout {
        let normalizedCameras = cameras.map { camera in
            CameraWallAutoLayout.Camera(id: camera.id, aspectRatio: normalizedAspectRatio(camera.aspectRatio))
        }
        guard !normalizedCameras.isEmpty, availableSize.width > 0, availableSize.height > 0 else {
            return Layout(tiles: [], contentSize: availableSize)
        }

        return columnCounts(for: normalizedCameras.count)
            .compactMap { candidateLayout(for: normalizedCameras, columnCount: $0) }
            .max { $0.score < $1.score }?
            .layout ?? Layout(tiles: [], contentSize: availableSize)
    }

    private func candidateLayout(
        for cameras: [CameraWallAutoLayout.Camera],
        columnCount: Int
    ) -> CandidateLayout? {
        let safeSize = CGSize(
            width: max(availableSize.width, 1),
            height: max(availableSize.height, 1)
        )
        let columnSpacing = CGFloat(max(0, columnCount - 1)) * spacing
        guard safeSize.width > columnSpacing else { return nil }

        let unscaledTileWidth = max((safeSize.width - columnSpacing) / CGFloat(columnCount), 1)
        let rows = cameras.chunked(size: columnCount)

        let rowSpacing = CGFloat(max(0, rows.count - 1)) * spacing
        guard safeSize.height > rowSpacing else { return nil }

        let unscaledRowHeights = rows.map { row in
            row.map { unscaledTileWidth / $0.aspectRatio }.max() ?? 0
        }
        let unscaledTileHeight = unscaledRowHeights.reduce(CGFloat.zero, +)
        guard unscaledTileHeight > 0 else { return nil }

        let tileScale = min(1, (safeSize.height - rowSpacing) / unscaledTileHeight)
        let tileWidth = max(unscaledTileWidth * tileScale, 1)
        let rowHeights = unscaledRowHeights.map { max($0 * tileScale, 1) }
        let contentHeight = rowHeights.reduce(CGFloat.zero, +) + rowSpacing
        let startY = max((safeSize.height - contentHeight) / 2, 0)

        var tiles: [CameraWallAutoLayout.Tile] = []
        var y = startY
        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = rowHeights[rowIndex]
            let rowWidth = CGFloat(row.count) * tileWidth + CGFloat(max(0, row.count - 1)) * spacing
            var x = max((safeSize.width - rowWidth) / 2, 0)

            for camera in row {
                let tileHeight = tileWidth / camera.aspectRatio
                let frame = CGRect(
                    x: x,
                    y: y + max((rowHeight - tileHeight) / 2, 0),
                    width: tileWidth,
                    height: tileHeight
                )
                tiles.append(CameraWallAutoLayout.Tile(id: camera.id, frame: frame, aspectRatio: camera.aspectRatio))
                x += tileWidth + spacing
            }

            y += rowHeight + spacing
        }

        guard tiles.allSatisfy({ $0.frame.maxX <= safeSize.width + 0.01 && $0.frame.maxY <= safeSize.height + 0.01 }) else {
            return nil
        }

        return CandidateLayout(
            layout: Layout(tiles: tiles, contentSize: availableSize),
            score: score(
                tiles: tiles,
                contentHeight: contentHeight,
                columnCount: columnCount,
                rowCount: rows.count
            )
        )
    }

    private func columnCounts(for cameraCount: Int) -> [Int] {
        Array(1...max(cameraCount, 1))
    }

    private func score(
        tiles: [CameraWallAutoLayout.Tile],
        contentHeight: CGFloat,
        columnCount: Int,
        rowCount: Int
    ) -> CGFloat {
        let viewportArea = max(availableSize.width * availableSize.height, 1)
        let usefulArea = tiles.reduce(CGFloat.zero) { $0 + $1.frame.width * $1.frame.height }
        let coverageScore = usefulArea / viewportArea
        let minimumWidth = tiles.map(\.frame.width).min() ?? 0
        let minimumWidthScore = min(minimumWidth / Self.preferredTileWidth, 1)
        let tooSmallPenalty = pow(max((Self.minimumTileWidth - minimumWidth) / Self.minimumTileWidth, 0), 2)
        let heightUnderfill = max(availableSize.height - contentHeight, 0) / max(availableSize.height, 1)
        let columnBalance = CGFloat(columnCount) / CGFloat(max(tiles.count, 1))

        return coverageScore * 1_000
            + minimumWidthScore * 150
            + columnBalance * 20
            - tooSmallPenalty * 700
            - heightUnderfill * 40
            - CGFloat(rowCount) * 4
    }

    private func normalizedAspectRatio(_ aspectRatio: CGFloat) -> CGFloat {
        let safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9
        return max(0.75, min(safeAspectRatio, 2.2))
    }

    private struct CandidateLayout {
        let layout: Layout
        let score: CGFloat
    }
}

private extension Array {
    func chunked(size: Int) -> [[Element]] {
        guard size > 0 else { return [] }

        var chunks: [[Element]] = []
        var startIndex = self.startIndex
        while startIndex < endIndex {
            let chunkEndIndex = index(startIndex, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[startIndex..<chunkEndIndex]))
            startIndex = chunkEndIndex
        }
        return chunks
    }
}
