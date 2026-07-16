import Foundation
import HomeKit

struct CameraTransportError: Equatable {
    let domain: String
    let code: Int
    let message: String

    init?(_ error: (any Error)?) {
        guard let error else { return nil }
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        message = nsError.localizedDescription
    }
}

enum SnapshotRequestResult {
    case success(Date)
    case failure(CameraTransportError?)
}

enum CameraLiveTransportEvent: Equatable {
    case startRequested(at: Date, restarted: Bool)
    case started(at: Date, callbackLatency: TimeInterval?)
    case stopRequested(at: Date, reason: CameraLiveStopReason)
    case stopped(at: Date, disposition: CameraLiveFailureDisposition, callbackLatency: TimeInterval?)
}

enum CameraLiveStopReason: Equatable {
    case planned
    case startupTimeout
}

enum CameraLiveTransportState: Equatable {
    case idle
    case starting(requestedAt: Date)
    case streaming(startedAt: Date)
    case stopping(requestedAt: Date, reason: CameraLiveStopReason)

    var phase: LiveTransportPhase {
        switch self {
        case .idle: .idle
        case .starting: .starting
        case .streaming: .streaming
        case .stopping: .stopping
        }
    }

    var startRequestedAt: Date? {
        guard case .starting(let requestedAt) = self else { return nil }
        return requestedAt
    }

    var startedAt: Date? {
        guard case .streaming(let startedAt) = self else { return nil }
        return startedAt
    }

    var stopRequestedAt: Date? {
        guard case .stopping(let requestedAt, _) = self else { return nil }
        return requestedAt
    }

    var stopReason: CameraLiveStopReason? {
        guard case .stopping(_, let reason) = self else { return nil }
        return reason
    }

    mutating func requestStart(at date: Date) -> Bool {
        guard case .idle = self else { return false }
        self = .starting(requestedAt: date)
        return true
    }

    mutating func confirmStarted(at date: Date) -> Bool {
        guard case .starting = self else { return false }
        self = .streaming(startedAt: date)
        return true
    }

    mutating func requestStop(at date: Date, reason: CameraLiveStopReason) -> Bool {
        switch self {
        case .starting, .streaming:
            self = .stopping(requestedAt: date, reason: reason)
            return true
        case .idle, .stopping:
            return false
        }
    }

    mutating func confirmStopped() -> CameraLiveStopReason? {
        let reason = stopReason
        self = .idle
        return reason
    }
}

enum CameraLiveFailureDisposition: Equatable {
    case requestedStop
    case startupTimedOut
    case softContention(CameraTransportError)
    case hardCapacity(CameraTransportError)
    case infrastructureUnavailable(CameraTransportError)
    case retryableTransport(CameraTransportError)
    case cameraFailure(CameraTransportError)
    case ended

    var error: CameraTransportError? {
        switch self {
        case .softContention(let error),
             .hardCapacity(let error),
             .infrastructureUnavailable(let error),
             .retryableTransport(let error),
             .cameraFailure(let error):
            error
        case .requestedStop, .startupTimedOut, .ended:
            nil
        }
    }
}

enum CameraLiveFailureDispositionPolicy {
    static func classify(
        error: CameraTransportError?,
        stopReason: CameraLiveStopReason?
    ) -> CameraLiveFailureDisposition {
        guard let error else {
            return expectedStopDisposition(for: stopReason) ?? .ended
        }

        if stopReason != nil,
           error.domain == HMErrorDomain,
           error.code == HMError.Code.operationCancelled.rawValue {
            return expectedStopDisposition(for: stopReason) ?? .ended
        }

        guard error.domain == HMErrorDomain,
              let code = HMError.Code(rawValue: error.code) else {
            return .cameraFailure(error)
        }

        switch code {
        case .accessoryIsBusy, .operationInProgress:
            return .softContention(error)
        case .maximumObjectLimitReached:
            return .hardCapacity(error)
        case .networkUnavailable, .noHomeHub, .noCompatibleHomeHub:
            return .infrastructureUnavailable(error)
        case .operationTimedOut,
             .communicationFailure,
             .accessoryCommunicationFailure,
             .timedOutWaitingForAccessory:
            return .retryableTransport(error)
        default:
            return .cameraFailure(error)
        }
    }

    static func classify(
        error: CameraTransportError?,
        stopWasRequested: Bool
    ) -> CameraLiveFailureDisposition {
        classify(error: error, stopReason: stopWasRequested ? .planned : nil)
    }

    private static func expectedStopDisposition(
        for reason: CameraLiveStopReason?
    ) -> CameraLiveFailureDisposition? {
        switch reason {
        case .planned: .requestedStop
        case .startupTimeout: .startupTimedOut
        case nil: nil
        }
    }
}

enum CameraStreamStopErrorPolicy {
    static func shouldReport(domain: String, code: Int, stopWasRequested: Bool) -> Bool {
        let error = CameraTransportError(
            NSError(domain: domain, code: code)
        )
        return CameraLiveFailureDispositionPolicy.classify(
            error: error,
            stopWasRequested: stopWasRequested
        ).error != nil
    }
}

typealias SnapshotRequestID = Int64

enum CameraSessionImageEvent: Equatable {
    case reset
    case cachedSnapshotPresented
    case freshSnapshotReceived
    case liveStreamReceived
}

struct CameraSessionImageFreshness: Equatable {
    private(set) var hasFreshImage = false

    mutating func apply(_ event: CameraSessionImageEvent) {
        switch event {
        case .reset:
            hasFreshImage = false
        case .cachedSnapshotPresented:
            break
        case .freshSnapshotReceived, .liveStreamReceived:
            hasFreshImage = true
        }
    }
}
