import Foundation
import HomeKit

enum CameraSchedulingDefaults {
    static let staleVisualHighlightThreshold: TimeInterval = 60
    static let batteryWakeTriggerThreshold: TimeInterval = 60
    static let batteryStaleThreshold: TimeInterval = 120
    static let snapshotRequestTimeout: TimeInterval = 2.75
    static let batteryCaptureWarmup: TimeInterval = 5
    static let batteryCaptureLeasePadding: TimeInterval = 3
    static let batteryWakeLeaseDuration: TimeInterval = 8
    static let liveCapacityExpansionRetryDelay: TimeInterval = 10
}

enum WallDensity: String, CaseIterable, Identifiable {
    case oneColumn
    case twoColumns
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneColumn: "1 Column"
        case .twoColumns: "2 Columns"
        case .auto: "Auto"
        }
    }

    var columnCount: Int {
        switch self {
        case .oneColumn: 1
        case .twoColumns, .auto: 2
        }
    }

    var preferredVisibleRows: Int {
        3
    }

    var visibleCameraCount: Int {
        return preferredVisibleRows * columnCount
    }

    func stepped(by delta: Int) -> WallDensity {
        let allCases = Self.allCases
        guard let currentIndex = allCases.firstIndex(of: self) else {
            return .twoColumns
        }

        let nextIndex = max(0, min(allCases.count - 1, currentIndex + delta))
        return allCases[nextIndex]
    }
}

enum SessionMode: String {
    case optimistic
    case constrained

    var summary: String {
        switch self {
        case .optimistic:
            "Observe is attempting live video for all visible cameras."
        case .constrained:
            "Observe is prioritizing live video for selected cameras and refreshing the rest as snapshots."
        }
    }
}

enum FeedDisplayState: Equatable {
    case idle
    case starting
    case live
    case snapshot
    case offline
    case failed(String)

    var shortLabel: String? {
        switch self {
        case .idle:
            "Loading"
        case .starting:
            "Live…"
        case .live:
            nil
        case .snapshot:
            "Snapshot"
        case .offline:
            "Offline"
        case .failed(let message):
            message
        }
    }
}

enum FeedRecencyTier: Int, Equatable {
    case live
    case recentSnapshot
    case staleSnapshot
    case empty
}

enum FeedRecoveryPhase: Equatable {
    case idle
    case batteryCapture
    case batteryWaiting
}

enum CameraStatusIndicator: Equatable {
    case neutral
    case green
    case yellow
    case red
}

struct HomeOption: Identifiable, Hashable {
    let id: String
    let name: String
    let isPrimary: Bool
}

struct CameraStatusSnapshot: Equatable {
    let label: String
    let recencyTier: FeedRecencyTier
    let recoveryPhase: FeedRecoveryPhase
    let indicator: CameraStatusIndicator
}

struct CameraDisplayClassification: Equatable {
    let status: CameraStatusSnapshot
    let isStale: Bool
}

enum CameraDisplayClassifier {
    static func classify(
        isStreaming: Bool,
        isBatteryCamera: Bool,
        recoveryPhase: FeedRecoveryPhase,
        displayedStillDate: Date?,
        staleThreshold: TimeInterval,
        batteryTrustedStillThreshold: TimeInterval? = nil,
        now: Date
    ) -> CameraDisplayClassification {
        if isStreaming {
            return CameraDisplayClassification(
                status: CameraStatusSnapshot(
                    label: "Live",
                    recencyTier: .live,
                    recoveryPhase: .idle,
                    indicator: .green
                ),
                isStale: false
            )
        }

        if isBatteryCamera {
            let hasTrustedBatteryStill = hasTrustedBatteryStill(
                displayedStillDate: displayedStillDate,
                threshold: batteryTrustedStillThreshold ?? staleThreshold,
                now: now
            )
            switch recoveryPhase {
            case .batteryCapture:
                return CameraDisplayClassification(
                    status: CameraStatusSnapshot(
                        label: "Capturing",
                        recencyTier: recencyTier(
                            displayedStillDate: displayedStillDate,
                            threshold: batteryTrustedStillThreshold ?? staleThreshold,
                            now: now
                        ),
                        recoveryPhase: .batteryCapture,
                        indicator: .yellow
                    ),
                    isStale: !hasTrustedBatteryStill
                )
            case .batteryWaiting:
                return CameraDisplayClassification(
                    status: CameraStatusSnapshot(
                        label: "Wait for Capture",
                        recencyTier: recencyTier(
                            displayedStillDate: displayedStillDate,
                            threshold: batteryTrustedStillThreshold ?? staleThreshold,
                            now: now
                        ),
                        recoveryPhase: .batteryWaiting,
                        indicator: .yellow
                    ),
                    isStale: !hasTrustedBatteryStill
                )
            case .idle:
                break
            }
        }

        guard let displayedStillDate else {
            return CameraDisplayClassification(
                status: CameraStatusSnapshot(
                    label: "Stale",
                    recencyTier: .empty,
                    recoveryPhase: .idle,
                    indicator: .red
                ),
                isStale: true
            )
        }

        let age = max(0, now.timeIntervalSince(displayedStillDate))
        if age <= staleThreshold {
            return CameraDisplayClassification(
                status: CameraStatusSnapshot(
                    label: recentLabel(age: age),
                    recencyTier: .recentSnapshot,
                    recoveryPhase: .idle,
                    indicator: .yellow
                ),
                isStale: false
            )
        }

        return CameraDisplayClassification(
            status: CameraStatusSnapshot(
                label: staleLabel(age: age),
                recencyTier: .staleSnapshot,
                recoveryPhase: .idle,
                indicator: .red
            ),
            isStale: true
        )
    }

    private static func recencyTier(
        displayedStillDate: Date?,
        threshold: TimeInterval,
        now: Date
    ) -> FeedRecencyTier {
        guard let displayedStillDate else { return .empty }
        let age = max(0, now.timeIntervalSince(displayedStillDate))
        return age <= threshold ? .recentSnapshot : .staleSnapshot
    }

    private static func hasTrustedBatteryStill(
        displayedStillDate: Date?,
        threshold: TimeInterval,
        now: Date
    ) -> Bool {
        guard let displayedStillDate else { return false }
        let age = max(0, now.timeIntervalSince(displayedStillDate))
        return age <= threshold
    }

    private static func recentLabel(age: TimeInterval) -> String {
        let seconds = max(0, Int(age))
        if seconds >= 60 {
            return "Recent (\(seconds / 60)m)"
        }
        return "Recent (\(seconds)s)"
    }

    private static func staleLabel(age: TimeInterval) -> String {
        let seconds = max(0, Int(age))
        if seconds >= 60 {
            return "Stale (\(seconds / 60)m)"
        }
        return "Stale (\(seconds)s)"
    }
}
