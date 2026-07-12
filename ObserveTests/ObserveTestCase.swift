import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

class ObserveTestCase: XCTestCase {
    let planner = CameraRecoveryPlanner()
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func makeFeed(
        id: String,
        priorityIndex: Int,
        isFocused: Bool = false,
        isStreaming: Bool = false,
        liveStartedAt: Date? = nil,
        lastSnapshotAge: TimeInterval? = nil,
        staleThreshold: TimeInterval = CameraSchedulingDefaults.staleVisualHighlightThreshold,
        isBatteryWakeCamera: Bool = false,
        batteryWakeTriggerThreshold: TimeInterval = CameraSchedulingDefaults.batteryWakeTriggerThreshold,
        batteryWakeLeaseStartedAt: Date? = nil,
        batteryWakeRetryAfter: Date? = nil,
        startupSnapshotAttempted: Bool = false,
        startupLiveFallbackStartedAt: Date? = nil,
        startupCoverageResolution: StartupCoverageResolution = .pending
    ) -> FeedPlanningSnapshot {
        let resolvedStaleThreshold = isBatteryWakeCamera
            ? CameraSchedulingDefaults.batteryStaleThreshold
            : staleThreshold
        var startupState = StartupCameraState()
        if startupSnapshotAttempted {
            startupState.apply(.snapshotRequested(at: now), isBatteryCamera: isBatteryWakeCamera)
        }
        if let startupLiveFallbackStartedAt {
            startupState.apply(
                .liveRequested(at: startupLiveFallbackStartedAt),
                isBatteryCamera: isBatteryWakeCamera
            )
        }
        switch startupCoverageResolution {
        case .pending:
            break
        case .trusted:
            startupState.apply(.trustedImageObserved, isBatteryCamera: isBatteryWakeCamera)
        case .recovering:
            startupState.apply(.snapshotFailed, isBatteryCamera: isBatteryWakeCamera)
            startupState.apply(.liveFailed, isBatteryCamera: isBatteryWakeCamera)
        }

        return FeedPlanningSnapshot(
            id: id,
            priorityIndex: priorityIndex,
            isFocused: isFocused,
            isStreaming: isStreaming,
            liveStartedAt: liveStartedAt,
            lastSnapshotDate: lastSnapshotAge.map { now.addingTimeInterval(-$0) },
            staleThreshold: resolvedStaleThreshold,
            isBatteryWakeCamera: isBatteryWakeCamera,
            batteryWakeTriggerThreshold: batteryWakeTriggerThreshold,
            batteryWakeLeaseStartedAt: batteryWakeLeaseStartedAt,
            batteryWakeRetryAfter: batteryWakeRetryAfter,
            startupState: startupState
        )
    }

    func liveIDs(in plan: CameraRecoveryPlan) -> [String] {
        plan.decisionsByID.values
            .filter { $0.presentationMode == .live }
            .map(\.id)
            .sorted()
    }

    func makeAutoLayoutCameras(count: Int) -> [CameraWallAutoLayout.Camera] {
        (0..<count).map { index in
            CameraWallAutoLayout.Camera(id: "camera-\(index)", aspectRatio: index.isMultiple(of: 3) ? 4 / 3 : 16 / 9)
        }
    }

    func assertAutoTiles(
        _ tiles: [CameraWallAutoLayout.Tile],
        fitIn availableSize: CGSize,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for tile in tiles {
            XCTAssertGreaterThan(tile.frame.width, 0, message, file: file, line: line)
            XCTAssertGreaterThan(tile.frame.height, 0, message, file: file, line: line)
            XCTAssertGreaterThanOrEqual(tile.frame.minX, -0.01, message, file: file, line: line)
            XCTAssertGreaterThanOrEqual(tile.frame.minY, -0.01, message, file: file, line: line)
            XCTAssertLessThanOrEqual(tile.frame.maxX, availableSize.width + 0.01, message, file: file, line: line)
            XCTAssertLessThanOrEqual(tile.frame.maxY, availableSize.height + 0.01, message, file: file, line: line)
            XCTAssertEqual(tile.frame.width / tile.frame.height, tile.aspectRatio, accuracy: 0.001, message, file: file, line: line)
        }
    }

    func assertMacTiles(
        _ tiles: [CameraWallAutoLayout.Tile],
        fitIn contentSize: CGSize,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertAutoTiles(tiles, fitIn: contentSize, message: message, file: file, line: line)
        XCTAssertFalse(tiles.isEmpty, message, file: file, line: line)
        for tile in tiles {
            XCTAssertTrue(tile.frame.width.isFinite, message, file: file, line: line)
            XCTAssertTrue(tile.frame.height.isFinite, message, file: file, line: line)
        }
    }

    func roundedFrame(_ frame: CGRect) -> String {
        "\(Int(frame.minX.rounded()))-\(Int(frame.minY.rounded()))-\(Int(frame.width.rounded()))-\(Int(frame.height.rounded()))"
    }

    func maxRowSize(in tiles: [CameraWallAutoLayout.Tile]) -> Int {
        rowSizes(in: tiles).max() ?? 0
    }

    func rowSizes(in tiles: [CameraWallAutoLayout.Tile]) -> [Int] {
        let rows = Dictionary(grouping: tiles) { tile in
            Int(tile.frame.midY.rounded())
        }
        return rows
            .sorted { $0.key < $1.key }
            .map { $0.value.count }
    }
}
