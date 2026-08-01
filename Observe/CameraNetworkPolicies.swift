import Foundation
import Network

enum CameraConnectionMode: String, Equatable {
    case homeNetwork
    case restricted
}

enum CameraConnectionModeReason: String, Equatable {
    case homeNetworkMatched
    case homeNetworkNotConfigured
    case notOnWiFi
    case ssidUnavailable
    case homeNetworkMismatch
}

struct CameraConnectionModeResolution: Equatable {
    let mode: CameraConnectionMode
    let reason: CameraConnectionModeReason
}

enum CurrentWiFiSSIDLookupSource: Equatable {
    case coreWLAN
    case networkExtension
}

enum CurrentWiFiSSIDLookupPolicy {
    static func sources(
        isMacCatalyst: Bool,
        networkClass: CameraNetworkClass
    ) -> [CurrentWiFiSSIDLookupSource] {
        if isMacCatalyst {
            return [.networkExtension, .coreWLAN]
        }
        guard networkClass == .wifi else { return [] }
        return [.networkExtension]
    }
}

enum CameraConnectionModePolicy {
    static func resolve(
        networkClass: CameraNetworkClass,
        currentSSID: String?,
        configuredHomeSSID: String
    ) -> CameraConnectionModeResolution {
        guard !configuredHomeSSID.isEmpty else {
            return CameraConnectionModeResolution(
                mode: .restricted,
                reason: .homeNetworkNotConfigured
            )
        }
        if let currentSSID {
            guard currentSSID == configuredHomeSSID else {
                return CameraConnectionModeResolution(mode: .restricted, reason: .homeNetworkMismatch)
            }
            return CameraConnectionModeResolution(mode: .homeNetwork, reason: .homeNetworkMatched)
        }
        guard networkClass == .wifi else {
            return CameraConnectionModeResolution(mode: .restricted, reason: .notOnWiFi)
        }
        return CameraConnectionModeResolution(mode: .restricted, reason: .ssidUnavailable)
    }
}

enum CameraNetworkClassPolicy {
    static func classify(
        isSatisfied: Bool,
        usesWiFi: Bool,
        usesCellular: Bool
    ) -> CameraNetworkClass {
        guard isSatisfied else { return .unknown }
        if usesWiFi { return .wifi }
        if usesCellular { return .cellular }
        return .other
    }
}

protocol CameraNetworkPathClassifying: Sendable {
    var currentClass: CameraNetworkClass { get }
    var revision: UInt64 { get }
}

final class CameraNetworkPathMonitor: CameraNetworkPathClassifying, @unchecked Sendable {
    static let shared = CameraNetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.psykadel.observe.network-path")
    private let lock = NSLock()
    private var storedClass: CameraNetworkClass = .unknown
    private var storedRevision: UInt64 = 0

    var currentClass: CameraNetworkClass {
        lock.withLock { storedClass }
    }

    var revision: UInt64 {
        lock.withLock { storedRevision }
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let networkClass = CameraNetworkClassPolicy.classify(
                isSatisfied: path.status == .satisfied,
                usesWiFi: path.usesInterfaceType(.wifi),
                usesCellular: path.usesInterfaceType(.cellular)
            )
            self.lock.withLock {
                self.storedClass = networkClass
                self.storedRevision &+= 1
            }
        }
        monitor.start(queue: queue)
    }
}
