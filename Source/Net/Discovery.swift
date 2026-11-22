import Foundation
import Network
import SystemConfiguration

/// The `_micbridge2._tcp` service (1.0; 0.9 used `_micbridge._tcp`, so the
/// two never see each other). The name advertises only a fingerprint of
/// the device key; it confers no trust, and every connection still completes
/// the encrypted handshake. `NearbyBrowser` finds the services.
enum BridgeDiscovery {
    static let serviceType = "_micbridge2._tcp"
    static func serviceName(for key: Data) -> String { DeviceKey.servicePrefix + DeviceKey.id(for: key) }
}

/// A desktop Mac often has both Ethernet and Wi-Fi on the same LAN. Measured
/// from a laptop on Wi-Fi: the desktop's wired address ~6 ms RTT, its Wi-Fi
/// address ~25 ms with 100-200 ms spikes. The listening Mac tells the dialing
/// Mac which of its addresses are wired.
enum LocalAddresses {
    static func wiredIPv4() -> [String] {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let wired = Set(interfaces.compactMap { item -> String? in
            guard let type = SCNetworkInterfaceGetInterfaceType(item), CFEqual(type, kSCNetworkInterfaceTypeEthernet) else { return nil }
            return SCNetworkInterfaceGetBSDName(item) as String?
        })
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            let flags = Int32(item.ifa_flags)
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  wired.contains(String(cString: item.ifa_name)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("169.254.") { result.append(text) }
        }
        return result
    }
}

/// The wired addresses this Mac sends in every hello, looked up off the main
/// thread. `SCNetworkInterfaceCopyAll` takes milliseconds on one Mac and far
/// longer on another; called inline, it stalled each handshake on the main
/// thread (twice per link since 0.7.1, when the dialer started sending its
/// addresses too). A handshake now only reads the last result, refreshed
/// whenever the network changes.
final class WiredAddresses {
    static let shared = WiredAddresses()
    private(set) var current: [String] = []
    private let lookup: () -> [String]
    private let queue = DispatchQueue(label: "MicBridge.wiredAddresses", qos: .utility)
    private var monitor: NWPathMonitor?

    init(lookup: @escaping () -> [String] = LocalAddresses.wiredIPv4) { self.lookup = lookup }

    /// Looks up now and again on every network change (main thread only).
    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in self?.refresh() }
        monitor = m
        m.start(queue: .main)
        refresh()
    }
    /// Returns at once; `current` changes on the main queue when the lookup
    /// is done. The queue is serial, so the latest refresh lands last.
    func refresh() {
        queue.async { [weak self, lookup] in
            let hosts = lookup()
            DispatchQueue.main.async { self?.current = hosts }
        }
    }
}
