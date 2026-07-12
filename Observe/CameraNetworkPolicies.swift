import Foundation
import Network

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
}

final class CameraNetworkPathMonitor: CameraNetworkPathClassifying, @unchecked Sendable {
    static let shared = CameraNetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.psykadel.observe.network-path")
    private let lock = NSLock()
    private var storedClass: CameraNetworkClass = .unknown

    var currentClass: CameraNetworkClass {
        lock.withLock { storedClass }
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
            }
        }
        monitor.start(queue: queue)
    }
}
