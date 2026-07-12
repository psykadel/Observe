import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class CameraWallTests: ObserveTestCase {
    func testWallDensityOrdersAutoBeforeColumnOptions() {
        XCTAssertEqual(WallDensity.allCases, [.auto, .oneColumn, .twoColumns])
        XCTAssertEqual(WallDensity.allCases.map(\.title), ["Auto", "1 Column", "2 Columns"])
        XCTAssertEqual(WallDensity.auto.stepped(by: 1), .oneColumn)
        XCTAssertEqual(WallDensity.oneColumn.stepped(by: 1), .twoColumns)
        XCTAssertEqual(WallDensity.twoColumns.stepped(by: -1), .oneColumn)
    }
    func testWallDensityOptionsStayEditableOnIPhoneButAutoOnlyOnMac() {
        XCTAssertEqual(WallDensity.selectableCases(for: .iPhone), [.auto, .oneColumn, .twoColumns])
        XCTAssertEqual(WallDensity.selectableCases(for: .mac), [.auto])
        XCTAssertTrue(SettingsPresentation.showsWallDensitySection(for: .iPhone))
        XCTAssertFalse(SettingsPresentation.showsWallDensitySection(for: .mac))
        XCTAssertTrue(CameraWallInteraction.allowsDensityAdjustment(for: .iPhone))
        XCTAssertFalse(CameraWallInteraction.allowsDensityAdjustment(for: .mac))
        XCTAssertEqual(SettingsPresentation.doneButtonPlacement(for: .iPhone), .leading)
        XCTAssertEqual(SettingsPresentation.doneButtonPlacement(for: .mac), .trailing)
    }
    func testMainWindowLaunchesMaximizedOnlyOnMac() {
        XCTAssertFalse(MainWindowPresentation.shouldMaximizeOnLaunch(for: .iPhone))
        XCTAssertTrue(MainWindowPresentation.shouldMaximizeOnLaunch(for: .mac))
        XCTAssertNil(MainWindowPresentation.minimumSize(for: .iPhone))
        XCTAssertEqual(MainWindowPresentation.minimumSize(for: .mac), CGSize(width: 120, height: 48))
    }
    func testCameraNameVisibilityControlsWallNameDisplay() {
        XCTAssertTrue(CameraNameVisibility.show.showsName(isOneColumnLayout: false))
        XCTAssertTrue(CameraNameVisibility.show.showsName(isOneColumnLayout: true))
        XCTAssertFalse(CameraNameVisibility.oneColumnOnly.showsName(isOneColumnLayout: false))
        XCTAssertTrue(CameraNameVisibility.oneColumnOnly.showsName(isOneColumnLayout: true))
        XCTAssertFalse(CameraNameVisibility.hide.showsName(isOneColumnLayout: false))
        XCTAssertFalse(CameraNameVisibility.hide.showsName(isOneColumnLayout: true))
        XCTAssertEqual(CameraNameVisibility.allCases.map(\.title), ["Show", "1 Column Only", "Hide"])
    }
    @MainActor
    func testAutoWallDensityPreferenceRoundTrip() {
        let suiteName = "ObserveTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected test user defaults suite")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)

        let preferences = ObservePreferences(userDefaults: defaults)
        preferences.wallDensity = .auto

        let reloaded = ObservePreferences(userDefaults: defaults)
        XCTAssertEqual(reloaded.wallDensity, .auto)

        defaults.set("focus", forKey: "observe.wallDensity")
        XCTAssertEqual(ObservePreferences(userDefaults: defaults).wallDensity, .oneColumn)

        defaults.set("overview", forKey: "observe.wallDensity")
        XCTAssertEqual(ObservePreferences(userDefaults: defaults).wallDensity, .twoColumns)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testCameraWallDismissesFullScreenSelectionWhenAppLeavesForeground() {
        XCTAssertFalse(CameraWallPresentation.shouldClearSelection(scenePhase: .active, hasSelectedFeed: true))
        XCTAssertFalse(CameraWallPresentation.shouldClearSelection(scenePhase: .inactive, hasSelectedFeed: true))
        XCTAssertTrue(CameraWallPresentation.shouldClearSelection(scenePhase: .background, hasSelectedFeed: true))
        XCTAssertFalse(CameraWallPresentation.shouldClearSelection(scenePhase: .background, hasSelectedFeed: false))
    }
    func testAutoWallLayoutFitsOneThroughTenCamerasInPortraitWithoutCropping() {
        let layout = CameraWallAutoLayout(availableSize: CGSize(width: 390, height: 820), spacing: 8)

        for count in 1...10 {
            let cameras = makeAutoLayoutCameras(count: count)
            let tiles = layout.tiles(for: cameras)

            XCTAssertEqual(tiles.map(\.id), cameras.map(\.id), "count \(count)")
            assertAutoTiles(tiles, fitIn: CGSize(width: 390, height: 820), message: "count \(count)")
        }
    }
    func testAutoWallLayoutCentersOnePortraitCameraAtFullWidth() {
        let tiles = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: [
            CameraWallAutoLayout.Camera(id: "front", aspectRatio: 16 / 9)
        ])

        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0].frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(tiles[0].frame.width, 390, accuracy: 0.001)
        XCTAssertEqual(tiles[0].frame.height, 219.375, accuracy: 0.001)
        XCTAssertEqual(tiles[0].frame.midY, 410, accuracy: 0.001)
    }
    func testAutoWallLayoutStacksTwoPortraitCamerasWithBalancedVerticalSpacing() {
        let tiles = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: [
            CameraWallAutoLayout.Camera(id: "front", aspectRatio: 16 / 9),
            CameraWallAutoLayout.Camera(id: "back", aspectRatio: 16 / 9)
        ])

        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(tiles[0].frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(tiles[1].frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(tiles[0].frame.width, 390, accuracy: 0.001)
        XCTAssertEqual(tiles[1].frame.width, 390, accuracy: 0.001)

        let topGap = tiles[0].frame.minY
        let middleGap = tiles[1].frame.minY - tiles[0].frame.maxY
        let bottomGap = 820 - tiles[1].frame.maxY
        XCTAssertEqual(topGap, bottomGap, accuracy: 0.001)
        XCTAssertEqual(topGap, middleGap, accuracy: 0.001)
    }
    func testAutoWallLayoutFitsLandscapeAndDiffersFromPortrait() {
        let cameras = makeAutoLayoutCameras(count: 7)
        let portrait = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: cameras)
        let landscape = CameraWallAutoLayout(
            availableSize: CGSize(width: 820, height: 390),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertEqual(landscape.map(\.id), cameras.map(\.id))
        assertAutoTiles(landscape, fitIn: CGSize(width: 820, height: 390), message: "landscape")
        XCTAssertNotEqual(portrait.map { roundedFrame($0.frame) }, landscape.map { roundedFrame($0.frame) })
    }
    func testAutoWallLayoutLimitsPortraitRowsToTwoColumns() {
        let cameras = makeAutoLayoutCameras(count: 10)
        let portrait = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertLessThanOrEqual(maxRowSize(in: portrait), 2)
    }
    func testAutoWallLayoutGivesSixPortraitCamerasTwoPriorityRows() {
        let cameras = makeAutoLayoutCameras(count: 6)
        let portrait = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertEqual(rowSizes(in: portrait), [1, 1, 2, 2])
    }
    func testAutoWallLayoutAllowsMoreThanTwoColumnsInLandscape() {
        let cameras = makeAutoLayoutCameras(count: 10)
        let landscape = CameraWallAutoLayout(
            availableSize: CGSize(width: 820, height: 390),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertGreaterThan(maxRowSize(in: landscape), 2)
    }
    func testAutoWallLayoutCapsAtTenAndKeepsPriorityOrder() {
        let cameras = makeAutoLayoutCameras(count: 12)
        let tiles = CameraWallAutoLayout(
            availableSize: CGSize(width: 390, height: 820),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertEqual(tiles.map(\.id), cameras.prefix(10).map(\.id))
    }
    func testAutoWallLayoutHandlesMixedAndInvalidAspectRatios() {
        let cameras = [
            CameraWallAutoLayout.Camera(id: "wide", aspectRatio: 2.4),
            CameraWallAutoLayout.Camera(id: "tall", aspectRatio: 0.5),
            CameraWallAutoLayout.Camera(id: "invalid", aspectRatio: 0),
            CameraWallAutoLayout.Camera(id: "nan", aspectRatio: .nan),
            CameraWallAutoLayout.Camera(id: "normal", aspectRatio: 16 / 9)
        ]

        let tiles = CameraWallAutoLayout(
            availableSize: CGSize(width: 430, height: 700),
            spacing: 8
        ).tiles(for: cameras)

        XCTAssertEqual(tiles.map(\.id), cameras.map(\.id))
        assertAutoTiles(tiles, fitIn: CGSize(width: 430, height: 700), message: "mixed ratios")
        XCTAssertEqual(tiles[0].aspectRatio, 2.2, accuracy: 0.001)
        XCTAssertEqual(tiles[1].aspectRatio, 0.75, accuracy: 0.001)
        XCTAssertEqual(tiles[2].aspectRatio, 16 / 9, accuracy: 0.001)
        XCTAssertEqual(tiles[3].aspectRatio, 16 / 9, accuracy: 0.001)
    }
    func testMacAutoWallLayoutChoosesColumnsFromWindowShape() {
        let cameras = makeAutoLayoutCameras(count: 10)
        let square = CameraWallMacAutoLayout(
            availableSize: CGSize(width: 900, height: 900),
            spacing: 8
        ).layout(for: cameras)
        let wide = CameraWallMacAutoLayout(
            availableSize: CGSize(width: 1440, height: 900),
            spacing: 8
        ).layout(for: cameras)
        let narrow = CameraWallMacAutoLayout(
            availableSize: CGSize(width: 500, height: 900),
            spacing: 8
        ).layout(for: cameras)

        XCTAssertEqual(maxRowSize(in: square.tiles), 3)
        XCTAssertEqual(maxRowSize(in: wide.tiles), 4)
        XCTAssertEqual(maxRowSize(in: narrow.tiles), 2)
        XCTAssertEqual(square.contentSize, CGSize(width: 900, height: 900))
        XCTAssertEqual(wide.contentSize, CGSize(width: 1440, height: 900))
        XCTAssertEqual(narrow.contentSize, CGSize(width: 500, height: 900))
        assertMacTiles(square.tiles, fitIn: CGSize(width: 900, height: 900), message: "square")
        assertMacTiles(wide.tiles, fitIn: CGSize(width: 1440, height: 900), message: "wide")
        assertMacTiles(narrow.tiles, fitIn: CGSize(width: 500, height: 900), message: "narrow")
    }
    func testMacAutoWallLayoutFitsEveryTileInSmallWindows() {
        let cameras = makeAutoLayoutCameras(count: 4)
        let availableSize = CGSize(width: 320, height: 360)
        let layout = CameraWallMacAutoLayout(
            availableSize: availableSize,
            spacing: 8
        ).layout(for: cameras)

        XCTAssertEqual(layout.tiles.map(\.id), cameras.map(\.id))
        XCTAssertEqual(layout.contentSize, availableSize)
        assertMacTiles(layout.tiles, fitIn: availableSize, message: "small window")
    }
    func testMacAutoWallLayoutFitsEveryTileInTinyResizableWindows() {
        let cameras = makeAutoLayoutCameras(count: 4)
        let sizes = [
            CGSize(width: 160, height: 48),
            CGSize(width: 220, height: 90),
            CGSize(width: 96, height: 320)
        ]

        for size in sizes {
            let layout = CameraWallMacAutoLayout(availableSize: size, spacing: 8).layout(for: cameras)

            XCTAssertEqual(layout.tiles.map(\.id), cameras.map(\.id), "\(size)")
            XCTAssertEqual(layout.contentSize, size, "\(size)")
            assertMacTiles(layout.tiles, fitIn: size, message: "\(size)")
        }
    }
    func testMacAutoWallLayoutFitsEveryTileInAwkwardResizableWindows() {
        let cameras = makeAutoLayoutCameras(count: 10)
        let sizes = [
            CGSize(width: 1212, height: 839),
            CGSize(width: 1180, height: 680),
            CGSize(width: 760, height: 560),
            CGSize(width: 520, height: 720)
        ]

        for size in sizes {
            let layout = CameraWallMacAutoLayout(availableSize: size, spacing: 8).layout(for: cameras)

            XCTAssertEqual(layout.tiles.map(\.id), cameras.map(\.id), "\(size)")
            XCTAssertEqual(layout.contentSize, size, "\(size)")
            assertMacTiles(layout.tiles, fitIn: size, message: "\(size)")
        }
    }
    func testMacAutoWallLayoutIncludesMoreThanThePhoneAutoLimit() {
        let cameras = makeAutoLayoutCameras(count: CameraWallAutoLayout.maxCameraCount + 2)
        let availableSize = CGSize(width: 1440, height: 900)
        let layout = CameraWallMacAutoLayout(availableSize: availableSize, spacing: 8).layout(for: cameras)

        XCTAssertEqual(layout.tiles.map(\.id), cameras.map(\.id))
        XCTAssertEqual(layout.contentSize, availableSize)
        assertMacTiles(layout.tiles, fitIn: availableSize, message: "more than phone limit")
    }
}
