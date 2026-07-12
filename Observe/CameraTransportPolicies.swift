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
    case stopRequested(at: Date)
    case stopped(at: Date, disposition: CameraLiveFailureDisposition, callbackLatency: TimeInterval?)
}

enum CameraLiveTransportActivityPolicy {
    static func hasActiveTransport(
        streamStateIsActive: Bool,
        startIsPending: Bool,
        stopIsPending: Bool
    ) -> Bool {
        streamStateIsActive || startIsPending || stopIsPending
    }
}

enum CameraLiveFailureDisposition: Equatable {
    case requestedStop
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
        case .requestedStop, .ended:
            nil
        }
    }
}

enum CameraLiveFailureDispositionPolicy {
    static func classify(
        error: CameraTransportError?,
        stopWasRequested: Bool
    ) -> CameraLiveFailureDisposition {
        guard let error else { return stopWasRequested ? .requestedStop : .ended }

        if stopWasRequested,
           error.domain == HMErrorDomain,
           error.code == HMError.Code.operationCancelled.rawValue {
            return .requestedStop
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
