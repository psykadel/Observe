import CoreGraphics
import HomeKit
import SwiftUI
import XCTest
@testable import Observe

final class CameraDisplayTests: ObserveTestCase {
    func testDisplayClassifierMarksLiveAsGreenAndNotStale() {
        let classification = CameraDisplayClassifier.classify(
            isStreaming: true,
            isBatteryCamera: false,
            recoveryPhase: .idle,
            displayedStillDate: nil,
            staleThreshold: 60,
            now: now
        )

        XCTAssertEqual(classification.status.label, "Live")
        XCTAssertEqual(classification.status.indicator, .green)
        XCTAssertFalse(classification.isStale)
    }
    func testInitialCameraTileHidesMissingOrStaleCachedImageBeforeFreshImage() {
        XCTAssertEqual(
            InitialCameraTilePolicy.presentation(
                hasFreshImageThisSession: false,
                displayedStillDate: nil,
                staleThreshold: 60,
                now: now
            ),
            .launchPlaceholder
        )
        XCTAssertEqual(
            InitialCameraTilePolicy.presentation(
                hasFreshImageThisSession: false,
                displayedStillDate: now.addingTimeInterval(-61),
                staleThreshold: 60,
                now: now
            ),
            .launchPlaceholder
        )
    }
    func testInitialCameraTileImmediatelyShowsRecentCachedImage() {
        XCTAssertEqual(
            InitialCameraTilePolicy.presentation(
                hasFreshImageThisSession: false,
                displayedStillDate: now.addingTimeInterval(-60),
                staleThreshold: 60,
                now: now
            ),
            .normal
        )
    }
    func testInitialCameraTileReturnsToNormalOnlyAfterFreshImageReceipt() {
        XCTAssertEqual(
            InitialCameraTilePolicy.presentation(
                hasFreshImageThisSession: true,
                displayedStillDate: now.addingTimeInterval(-600),
                staleThreshold: 60,
                now: now
            ),
            .normal
        )
        XCTAssertEqual(
            InitialCameraTilePolicy.presentation(
                hasFreshImageThisSession: false,
                displayedStillDate: nil,
                staleThreshold: 60,
                now: now
            ),
            .launchPlaceholder
        )
    }
    func testCameraSessionImageFreshnessIgnoresCacheAndResetsPerSession() {
        var freshness = CameraSessionImageFreshness()

        freshness.apply(.cachedSnapshotPresented)
        XCTAssertFalse(freshness.hasFreshImage)

        freshness.apply(.freshSnapshotReceived)
        XCTAssertTrue(freshness.hasFreshImage)

        freshness.apply(.reset)
        XCTAssertFalse(freshness.hasFreshImage)

        freshness.apply(.liveStreamReceived)
        XCTAssertTrue(freshness.hasFreshImage)
    }
    func testDisplayClassifierKeepsBatteryCaptureLabelWhileLiveWithCountdown() {
        let classification = CameraDisplayClassifier.classify(
            isStreaming: true,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            liveStartedAt: now.addingTimeInterval(-1.4),
            displayedStillDate: now.addingTimeInterval(-90),
            staleThreshold: 60,
            batteryTrustedStillThreshold: 30,
            batteryCaptureWarmup: 5,
            now: now
        )

        XCTAssertEqual(classification.status.label, "Live Capture (4s)")
        XCTAssertEqual(classification.status.indicator, .green)
        XCTAssertEqual(classification.status.recencyTier, .live)
        XCTAssertFalse(classification.isStale)
    }
    func testDisplayClassifierMarksBatteryCaptureBeforeLiveAsYellow() {
        let classification = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            displayedStillDate: now.addingTimeInterval(-45),
            staleThreshold: 60,
            batteryTrustedStillThreshold: 30,
            batteryCaptureWarmup: 5,
            now: now
        )

        XCTAssertEqual(classification.status.label, "Live Capture")
        XCTAssertEqual(classification.status.indicator, .yellow)
        XCTAssertFalse(classification.isStale)
    }
    func testDisplayClassifierMarksBatteryCaptureAndWaitingWithoutDisplayedStillAsStale() {
        let capturing = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            displayedStillDate: nil,
            staleThreshold: 120,
            batteryTrustedStillThreshold: 60,
            now: now
        )
        let waiting = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryWaiting,
            displayedStillDate: nil,
            staleThreshold: 120,
            batteryTrustedStillThreshold: 60,
            now: now
        )

        XCTAssertEqual(capturing.status.label, "Live Capture")
        XCTAssertEqual(waiting.status.label, "Queued")
        XCTAssertEqual(capturing.status.indicator, .yellow)
        XCTAssertEqual(waiting.status.indicator, .yellow)
        XCTAssertTrue(capturing.isStale)
        XCTAssertTrue(waiting.isStale)
    }
    func testDisplayClassifierMarksBatteryCaptureAndWaitingWithTrustedStillAsNotStale() {
        let capturing = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            displayedStillDate: now.addingTimeInterval(-30),
            staleThreshold: 120,
            batteryTrustedStillThreshold: 60,
            now: now
        )
        let waiting = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryWaiting,
            displayedStillDate: now.addingTimeInterval(-30),
            staleThreshold: 120,
            batteryTrustedStillThreshold: 60,
            now: now
        )

        XCTAssertFalse(capturing.isStale)
        XCTAssertFalse(waiting.isStale)
    }
    func testBatteryCaptureDoesNotShowStaleBorderUntilVisualThresholdIsReached() {
        let classification = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            displayedStillDate: now.addingTimeInterval(-45),
            staleThreshold: 60,
            batteryTrustedStillThreshold: 30,
            now: now
        )

        XCTAssertEqual(classification.status.label, "Live Capture")
        XCTAssertEqual(classification.status.indicator, .yellow)
        XCTAssertFalse(classification.isStale)
    }
    func testBatteryCaptureShowsStaleBorderAfterVisualThresholdIsReached() {
        let classification = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .batteryCapture,
            displayedStillDate: now.addingTimeInterval(-61),
            staleThreshold: 60,
            batteryTrustedStillThreshold: 30,
            now: now
        )

        XCTAssertEqual(classification.status.label, "Live Capture")
        XCTAssertEqual(classification.status.indicator, .yellow)
        XCTAssertTrue(classification.isStale)
    }
    func testDisplayClassifierKeepsStatusAndBorderStaleStateTogether() {
        let missing = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: false,
            recoveryPhase: .idle,
            displayedStillDate: nil,
            staleThreshold: 60,
            now: now
        )
        let recent = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: false,
            recoveryPhase: .idle,
            displayedStillDate: now.addingTimeInterval(-30),
            staleThreshold: 60,
            now: now
        )
        let stale = CameraDisplayClassifier.classify(
            isStreaming: false,
            isBatteryCamera: true,
            recoveryPhase: .idle,
            displayedStillDate: now.addingTimeInterval(-90),
            staleThreshold: 60,
            now: now
        )

        XCTAssertEqual(missing.status.indicator, .red)
        XCTAssertTrue(missing.isStale)
        XCTAssertEqual(recent.status.indicator, .yellow)
        XCTAssertFalse(recent.isStale)
        XCTAssertEqual(stale.status.indicator, .red)
        XCTAssertTrue(stale.isStale)
    }
}
