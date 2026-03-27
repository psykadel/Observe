import Foundation
import HomeKit

enum CameraSchedulingDefaults {
    static let staleSnapshotThreshold: TimeInterval = 10
    static let staleVisualHighlightThreshold: TimeInterval = 60
    static let snapshotSuccessInterval: TimeInterval = 2
    static let snapshotRequestTimeout: TimeInterval = 2.75
    static let liveRecoveryLeaseDuration: TimeInterval = 3
    static let liveRecoveryRetryCooldown: TimeInterval = 5
}

enum WallDensity: String, CaseIterable, Identifiable {
    case oneColumn
    case twoColumns

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneColumn: "1 Column"
        case .twoColumns: "2 Columns"
        }
    }

    var columnCount: Int {
        switch self {
        case .oneColumn: 1
        case .twoColumns: 2
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
    case snapshotRecovery
    case liveRecovery
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

struct CameraStatusSnapshot {
    let label: String
    let recencyTier: FeedRecencyTier
    let recoveryPhase: FeedRecoveryPhase
    let indicator: CameraStatusIndicator
}
