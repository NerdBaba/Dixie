import Foundation
import Network

final class SSDPDiscovery: @unchecked Sendable {
    private var listener: NWConnection?
    private var multicastConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.dixie.ssdp")
    
    private let multicastGroup = "239.255.255.250"
    private let multicastPort: UInt16 = 1900
    
    private var discoveredDevices: [String: DiscoveredUPnPDevice] = [:]
    private let devicesLock = NSLock()
    
    struct DiscoveredUPnPDevice: Identifiable {
        let id = UUID()
        let usn: String
        let location: URL
        let server: String
        let st: String
    }
    
    var onDeviceDiscovered: ((DiscoveredUPnPDevice) -> Void)?
    
    func start() {
        print("[SSDP] Starting discovery...")
        startListener()
    }
    
    func stop() {
        print("[SSDP] Stopping...")
        listener?.cancel()
        multicastConnection?.cancel()
    }
    
    private func startListener() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        
        listener = NWConnection(host: NWEndpoint.Host("0.0.0.0"), port: NWEndpoint.Port(rawValue: multicastPort)!, using: params)
        
        listener?.stateUpdateHandler = { [weak self] state in
            print("[SSDP] Listener state: \(state)")
            if case .ready = state {
                print("[SSDP] Listener ready, starting receive...")
                self?.startReceiving()
                self?.sendMsearch()
            } else if case .failed(let error) = state {
                print("[SSDP] Listener failed: \(error)")
            }
        }
        
        listener?.start(queue: queue)
        
        setupMulticast()
    }
    
    private func setupMulticast() {
        print("[SSDP] Setting up multicast connection...")
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(multicastGroup), port: NWEndpoint.Port(rawValue: multicastPort)!)
        
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        
        multicastConnection = NWConnection(to: endpoint, using: params)
        
        multicastConnection?.stateUpdateHandler = { [weak self] state in
            print("[SSDP] Multicast state: \(state)")
            if case .ready = state {
                print("[SSDP] Multicast ready, sending M-SEARCH...")
                self?.sendMsearch()
            } else if case .failed(let error) = state {
                print("[SSDP] Multicast failed: \(error)")
            }
        }
        
        multicastConnection?.start(queue: queue)
    }
    
    private func startReceiving() {
        listener?.receiveMessage { [weak self] content, _, _, error in
            if let content = content {
                print("[SSDP] Received \(content.count) bytes")
                self?.handleSSDPResponse(content)
            }
            if error == nil {
                self?.startReceiving()
            } else if let error = error {
                print("[SSDP] Receive error: \(error)")
            }
        }
    }
    
    private func sendMsearch() {
        let msearch = """
        M-SEARCH * HTTP/1.1\r
        HOST: \(multicastGroup):\(multicastPort)\r
        MAN: "ssdp:discover"\r
        MX: 3\r
        ST: ssdp:all\r
        \r
        
        """
        
        print("[SSDP] Sending M-SEARCH to \(multicastGroup):\(multicastPort)")
        
        multicastConnection?.send(content: msearch.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error {
                print("[SSDP] M-SEARCH send error: \(error)")
            } else {
                print("[SSDP] M-SEARCH sent successfully")
            }
        })
    }
    
    private func handleSSDPResponse(_ data: Data) {
        guard let response = String(data: data, encoding: .utf8) else { return }
        
        print("[SSDP] Processing response: \(response.prefix(200))")
        
        let lines = response.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        
        for line in lines {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).uppercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        
        guard let locationStr = headers["LOCATION"], let location = URL(string: locationStr) else {
            print("[SSDP] No LOCATION in response")
            return
        }
        
        let usn = headers["USN"] ?? UUID().uuidString
        let server = headers["SERVER"] ?? ""
        let st = headers["ST"] ?? headers["NT"] ?? "unknown"
        
        let device = DiscoveredUPnPDevice(usn: usn, location: location, server: server, st: st)
        
        devicesLock.lock()
        discoveredDevices[usn] = device
        devicesLock.unlock()
        
        print("[SSDP] Discovered device: \(st) at \(location)")
        onDeviceDiscovered?(device)
    }
    
    func getDevices() -> [DiscoveredUPnPDevice] {
        devicesLock.lock()
        let devices = Array(discoveredDevices.values)
        devicesLock.unlock()
        print("[SSDP] Returning \(devices.count) devices")
        return devices
    }
}