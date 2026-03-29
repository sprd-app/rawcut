import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var isWiFi: Bool = false
    @Published private(set) var isCellular: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.rawcut.networkmonitor")

    init() {
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied
                self.isWiFi = path.usesInterfaceType(.wifi)
                self.isCellular = path.usesInterfaceType(.cellular)

                if !wasConnected && self.isConnected {
                    NotificationCenter.default.post(name: .networkDidReconnect, object: nil)
                    print("[Rawcut] Network reconnected (WiFi: \(self.isWiFi), Cellular: \(self.isCellular))")
                } else if wasConnected && !self.isConnected {
                    NotificationCenter.default.post(name: .networkDidDisconnect, object: nil)
                    print("[Rawcut] Network lost")
                }
            }
        }
        monitor.start(queue: queue)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let networkDidReconnect = Notification.Name("com.rawcut.networkDidReconnect")
    static let networkDidDisconnect = Notification.Name("com.rawcut.networkDidDisconnect")
}
