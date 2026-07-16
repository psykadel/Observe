import Foundation

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
enum CameraSessionActivation {
    static func shouldRebuildSession(currentlyActive: Bool, nextActive: Bool) -> Bool {
        !currentlyActive && nextActive
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

enum InitialCameraTilePresentation: Equatable {
    case launchPlaceholder
    case normal
}

enum InitialCameraTilePolicy {
    static func presentation(
        hasFreshImageThisSession: Bool,
        displayedStillDate: Date?,
        staleThreshold: TimeInterval,
        now: Date
    ) -> InitialCameraTilePresentation {
        guard !hasFreshImageThisSession else { return .normal }
        guard let displayedStillDate else { return .launchPlaceholder }

        let age = max(0, now.timeIntervalSince(displayedStillDate))
        return age <= staleThreshold ? .normal : .launchPlaceholder
    }
}

enum CameraDisplayClassifier {
    static func classify(
        isStreaming: Bool,
        isBatteryCamera: Bool,
        recoveryPhase: FeedRecoveryPhase,
        liveStartedAt: Date? = nil,
        displayedStillDate: Date?,
        staleThreshold: TimeInterval,
        batteryTrustedStillThreshold: TimeInterval? = nil,
        batteryCaptureWarmup: TimeInterval = CameraSchedulingDefaults.batteryCaptureWarmup,
        now: Date
    ) -> CameraDisplayClassification {
        if isBatteryCamera {
            let isBatteryStillVisuallyStale = isStillVisuallyStale(
                displayedStillDate: displayedStillDate,
                threshold: staleThreshold,
                now: now
            )
            switch recoveryPhase {
            case .batteryCapture:
                return CameraDisplayClassification(
                    status: CameraStatusSnapshot(
                        label: batteryCaptureLabel(
                            isStreaming: isStreaming,
                            liveStartedAt: liveStartedAt,
                            warmup: batteryCaptureWarmup,
                            now: now
                        ),
                        recencyTier: isStreaming ? .live : recencyTier(
                            displayedStillDate: displayedStillDate,
                            threshold: staleThreshold,
                            now: now
                        ),
                        recoveryPhase: .batteryCapture,
                        indicator: isStreaming ? .green : .yellow
                    ),
                    isStale: isStreaming ? false : isBatteryStillVisuallyStale
                )
            case .batteryWaiting:
                return CameraDisplayClassification(
                    status: CameraStatusSnapshot(
                        label: "Queued",
                        recencyTier: recencyTier(
                            displayedStillDate: displayedStillDate,
                            threshold: staleThreshold,
                            now: now
                        ),
                        recoveryPhase: recoveryPhase,
                        indicator: .yellow
                    ),
                    isStale: isBatteryStillVisuallyStale
                )
            case .idle:
                break
            }
        }

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

    private static func batteryCaptureLabel(
        isStreaming: Bool,
        liveStartedAt: Date?,
        warmup: TimeInterval,
        now: Date
    ) -> String {
        guard isStreaming, let liveStartedAt else {
            return "Live Capture"
        }

        let remaining = max(0, warmup - now.timeIntervalSince(liveStartedAt))
        return "Live Capture (\(Int(ceil(remaining)))s)"
    }

    private static func isStillVisuallyStale(
        displayedStillDate: Date?,
        threshold: TimeInterval,
        now: Date
    ) -> Bool {
        guard let displayedStillDate else { return true }
        let age = max(0, now.timeIntervalSince(displayedStillDate))
        return age > threshold
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
