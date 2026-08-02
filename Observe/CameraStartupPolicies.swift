import Foundation

enum PlannedPresentationMode: Equatable {
    case live
    case snapshot
}

enum StartupMetadataWorkMode: String, Equatable {
    case immediateParallel
    case mediaPrioritySerial

    static func resolve(connectionMode: CameraConnectionMode) -> StartupMetadataWorkMode {
        connectionMode == .homeNetwork ? .immediateParallel : .mediaPrioritySerial
    }
}

enum StartupMetadataOperationKind: String, Equatable {
    case availabilityNotification
    case availabilityRead
    case batteryNotification
    case batteryRead

    fileprivate var priority: Int {
        switch self {
        case .availabilityNotification: 0
        case .batteryNotification: 1
        case .availabilityRead: 2
        case .batteryRead: 3
        }
    }

    var isNotificationRegistration: Bool {
        switch self {
        case .availabilityNotification, .batteryNotification:
            true
        case .availabilityRead, .batteryRead:
            false
        }
    }
}

struct StartupMetadataOperationDescriptor: Equatable, Identifiable {
    let feedID: String
    let characteristicID: String
    let characteristicType: String
    let kind: StartupMetadataOperationKind

    var id: String {
        "\(feedID):\(characteristicID):\(kind.rawValue)"
    }

    var telemetryLabel: String {
        "\(feedID):\(kind.rawValue)"
    }
}

enum StartupMetadataAdmissionPolicy {
    static func shouldIssue(
        kind: StartupMetadataOperationKind,
        mode: StartupMetadataWorkMode,
        initialMediaAdmissionCompleted: Bool,
        allVisibleFeedsTrusted: Bool,
        criticalMediaWorkActive: Bool
    ) -> Bool {
        switch mode {
        case .immediateParallel:
            return true
        case .mediaPrioritySerial:
            guard initialMediaAdmissionCompleted else { return false }
            if kind.isNotificationRegistration {
                return true
            }
            return allVisibleFeedsTrusted && !criticalMediaWorkActive
        }
    }

    static func maxConcurrentOperations(
        mode: StartupMetadataWorkMode,
        initialMediaAdmissionCompleted: Bool
    ) -> Int {
        switch mode {
        case .immediateParallel:
            Int.max
        case .mediaPrioritySerial:
            initialMediaAdmissionCompleted ? 1 : 0
        }
    }

    static func ordered(
        _ operations: [StartupMetadataOperationDescriptor]
    ) -> [StartupMetadataOperationDescriptor] {
        operations.sorted { lhs, rhs in
            if lhs.kind.priority != rhs.kind.priority {
                return lhs.kind.priority < rhs.kind.priority
            }
            if lhs.feedID != rhs.feedID {
                return lhs.feedID < rhs.feedID
            }
            return lhs.characteristicID < rhs.characteristicID
        }
    }
}

enum StartupMetadataGateStatePolicy {
    static func resolve(
        mode: StartupMetadataWorkMode,
        initialMediaAdmissionCompleted: Bool,
        hasQueuedOperations: Bool,
        activeOperationKind: StartupMetadataOperationKind?,
        completedOperationCount: Int,
        allVisibleFeedsTrusted: Bool,
        criticalMediaWorkActive: Bool
    ) -> String {
        guard mode == .mediaPrioritySerial else { return "immediate" }

        if !hasQueuedOperations,
           activeOperationKind == nil,
           completedOperationCount > 0 {
            return "complete"
        }
        if !initialMediaAdmissionCompleted {
            return "waitingForInitialMediaAdmission"
        }
        if activeOperationKind?.isNotificationRegistration == false {
            return "readInFlight"
        }
        if !allVisibleFeedsTrusted {
            return "notificationsOnlyWaitingForAllTrusted"
        }
        if criticalMediaWorkActive {
            return "waitingForMediaIdle"
        }
        return "open"
    }
}

enum StartupLivePolicy: Equatable {
    case normal
    case homeNetwork(liveIDs: Set<String>)
}

enum LiveAdmissionOrderingPolicy {
    static func usesLiveOrder(connectionMode: CameraConnectionMode) -> Bool {
        connectionMode == .restricted
    }
}

enum StartupCoverageResolution: Equatable {
    case pending
    case trusted
    case recovering
}

enum StartupCameraPathState: Equatable {
    case notAttempted
    case inFlight(startedAt: Date)
    case succeeded
    case failed

    var wasAttempted: Bool {
        self != .notAttempted
    }

    var startedAt: Date? {
        guard case .inFlight(let startedAt) = self else { return nil }
        return startedAt
    }

    var label: String {
        switch self {
        case .notAttempted: "notAttempted"
        case .inFlight: "inFlight"
        case .succeeded: "succeeded"
        case .failed: "failed"
        }
    }
}

enum StartupCameraEvent: Equatable {
    case reset
    case snapshotRequested(at: Date)
    case snapshotSucceeded
    case snapshotFailed(entersRecovery: Bool)
    case liveRequested(at: Date)
    case liveStarted
    case liveFailed
    case trustedImageObserved
}

struct StartupCameraState: Equatable {
    private(set) var snapshotPath: StartupCameraPathState = .notAttempted
    private(set) var livePath: StartupCameraPathState = .notAttempted
    private(set) var resolution: StartupCoverageResolution = .pending
    private(set) var firstSnapshotRequestedAt: Date?

    var snapshotAttempted: Bool { snapshotPath.wasAttempted }
    var snapshotFailed: Bool { snapshotPath == .failed }
    var liveAttempted: Bool { livePath.wasAttempted }

    mutating func apply(_ event: StartupCameraEvent, isBatteryCamera: Bool) {
        switch event {
        case .reset:
            self = StartupCameraState()
        case .snapshotRequested(let startedAt):
            guard resolution != .trusted else { return }
            if firstSnapshotRequestedAt == nil {
                firstSnapshotRequestedAt = startedAt
            }
            snapshotPath = .inFlight(startedAt: startedAt)
        case .snapshotSucceeded:
            snapshotPath = .succeeded
            resolution = .trusted
        case .snapshotFailed(let entersRecovery):
            guard resolution != .trusted else { return }
            snapshotPath = .failed
            if entersRecovery, !isBatteryCamera {
                resolution = .recovering
            } else if isBatteryCamera {
                resolveFailureIfNeeded(isBatteryCamera: true)
            } else {
                resolveFailureIfNeeded(isBatteryCamera: false)
            }
        case .liveRequested(let startedAt):
            guard resolution != .trusted else { return }
            livePath = .inFlight(startedAt: startedAt)
        case .liveStarted:
            livePath = .succeeded
            resolution = .trusted
        case .liveFailed:
            guard resolution != .trusted else { return }
            livePath = .failed
            resolveFailureIfNeeded(isBatteryCamera: isBatteryCamera)
        case .trustedImageObserved:
            resolution = .trusted
        }
    }

    private mutating func resolveFailureIfNeeded(isBatteryCamera: Bool) {
        if isBatteryCamera {
            if livePath == .failed {
                resolution = .recovering
            }
        } else if snapshotPath == .failed, livePath == .failed {
            resolution = .recovering
        }
    }
}

enum CameraSessionGeneration {
    static func accepts(callbackGeneration: UInt64, activeGeneration: UInt64) -> Bool {
        callbackGeneration == activeGeneration
    }
}

enum SnapshotPriority: Int, Comparable, Equatable {
    case none = 0
    case refresh = 1
    case urgent = 2

    static func < (lhs: SnapshotPriority, rhs: SnapshotPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SnapshotPendingRequest: Equatable {
    let id: SnapshotRequestID
    let priority: SnapshotPriority
    let issuedAt: Date
}

enum SnapshotWorkState: Equatable {
    case idle
    case queued(priority: SnapshotPriority, eligibleAt: Date)
    case pending(SnapshotPendingRequest)

    var pendingRequest: SnapshotPendingRequest? {
        guard case .pending(let request) = self else { return nil }
        return request
    }

    var isOutstanding: Bool {
        pendingRequest != nil
    }

    var queuedEligibleAt: Date? {
        guard case .queued(_, let eligibleAt) = self else { return nil }
        return eligibleAt
    }

    @discardableResult
    mutating func enqueue(priority: SnapshotPriority, eligibleAt: Date) -> Bool {
        switch self {
        case .idle:
            self = .queued(priority: priority, eligibleAt: eligibleAt)
            return true
        case .queued(let existingPriority, let existingDate):
            guard priority > existingPriority else { return false }
            self = .queued(priority: priority, eligibleAt: min(existingDate, eligibleAt))
            return true
        case .pending:
            return false
        }
    }
}

enum SnapshotQueueAdmissionPolicy {
    static func shouldQueue(isBatteryCamera: Bool, priority: SnapshotPriority) -> Bool {
        !isBatteryCamera && priority != .none
    }
}

struct LivePlanTransition: Equatable {
    let stopIDs: Set<String>
    let startIDs: Set<String>
    let deferredStartIDs: Set<String>
}

enum LivePlanTransitionPolicy {
    static func makeTransition(
        activeTransportIDs: Set<String>,
        desiredLiveIDs: Set<String>
    ) -> LivePlanTransition {
        let stopIDs = activeTransportIDs.subtracting(desiredLiveIDs)
        let missingDesiredIDs = desiredLiveIDs.subtracting(activeTransportIDs)
        return LivePlanTransition(
            stopIDs: stopIDs,
            startIDs: stopIDs.isEmpty ? missingDesiredIDs : [],
            deferredStartIDs: stopIDs.isEmpty ? [] : missingDesiredIDs
        )
    }
}

enum CameraNetworkClass: String, Equatable {
    case wifi
    case cellular
    case other
    case unknown
}
