import Foundation
import HomeKit

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

struct HomeOption: Identifiable, Hashable {
    let id: String
    let name: String
    let isPrimary: Bool
}

struct CameraStatusSnapshot {
    let label: String
    let isLive: Bool
    let isFreshSnapshot: Bool
}
