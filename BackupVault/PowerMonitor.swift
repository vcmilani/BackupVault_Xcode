import Foundation
import Network
import IOKit.ps

@MainActor
final class PowerMonitor: ObservableObject {

    enum PowerSource { case ac, battery, unknown }

    @Published var powerSource: PowerSource = .unknown
    @Published var batteryPercent: Int = 100
    @Published var isOnLocalNetwork: Bool = false
    @Published var networkInterface: String = ""

    private let pathMonitor = NWPathMonitor()
    private var powerTimer: Timer?

    init() {
        startNetworkMonitor()
        startPowerMonitor()
    }

    deinit {
        pathMonitor.cancel()
        powerTimer?.invalidate()
    }

    // MARK: - Network

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isOnLocalNetwork = path.status == .satisfied
                if path.usesInterfaceType(.wifi)        { self.networkInterface = "Wi-Fi" }
                else if path.usesInterfaceType(.wiredEthernet) { self.networkInterface = "Ethernet" }
                else if path.usesInterfaceType(.cellular)      { self.networkInterface = "Cellular" }
                else if path.status == .satisfied              { self.networkInterface = "Other" }
                else { self.networkInterface = "" }
            }
        }
        pathMonitor.start(queue: .global(qos: .background))
    }

    // MARK: - Power

    private func startPowerMonitor() {
        updatePower()
        // Polls every 30s — IOKit notifications are complex; this is good enough.
        powerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePower() }
        }
    }

    private func updatePower() {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            powerSource = .unknown
            return
        }

        for source in sources {
            guard let dict = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }

            let state = dict[kIOPSPowerSourceStateKey] as? String ?? ""
            let pct   = dict[kIOPSCurrentCapacityKey]  as? Int ?? 100
            let max   = dict[kIOPSMaxCapacityKey]      as? Int ?? 100

            powerSource    = (state == kIOPSACPowerValue) ? .ac : .battery
            batteryPercent = max > 0 ? (pct * 100 / max) : 100
            return
        }
        powerSource = .unknown
    }
}
