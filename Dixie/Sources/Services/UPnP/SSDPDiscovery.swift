import Foundation

/// BSD-socket SSDP engine.
///
/// Replaces the previous Network.framework NWConnectionGroup implementation,
/// which could wedge silently (no more M-SEARCH replies, no NOTIFY) and take
/// HTTP serving down with it.
///
/// Design: one UDP socket bound to 0.0.0.0:1900 with SO_REUSEADDR+SO_REUSEPORT,
/// joined to 239.255.255.250 on INADDR_ANY plus every UP IPv4 interface,
/// pumped by a single DispatchSourceRead. Sends use the same socket. All work
/// stays on a private serial queue; callbacks never block.
final class SSDPDiscovery: @unchecked Sendable {
    static let multicastHost = "239.255.255.250"
    static let multicastPort: UInt16 = 1900

    struct DiscoveredUPnPDevice: Identifiable, Sendable {
        let id = UUID()
        let usn: String
        let location: URL
        let server: String
        let st: String
    }

    /// Called on an arbitrary queue for every unique discovery response.
    var onDeviceDiscovered: (@Sendable (DiscoveredUPnPDevice) -> Void)?

    /// Respond to M-SEARCH so TVs/control points can find this Mac.
    var msearchHandler: (@Sendable (String) -> String?)?

    /// Responses whose USN contains this substring are ignored (own server echo).
    var ignoredUSNSubstring: String?

    /// Last time any packet was received. The DLNA watchdog logs if this goes stale.
    var lastReceive: Date?

    private let queue = DispatchQueue(label: "com.dixie.ssdp")
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    private var discoveredDevices: [String: DiscoveredUPnPDevice] = [:]
    private let devicesLock = NSLock()
    private let localIPs = Set(SSDPDiscovery.localIPv4Addresses())

    func start() {
        queue.async { [weak self] in self?.open() }
    }

    func stop() {
        queue.async { [weak self] in self?.closeLocked() }
    }

    func resendMsearch() {
        queue.async { [weak self] in self?.sendMsearchBurst() }
    }

    // MARK: - Socket lifecycle

    private func open() {
        guard readSource == nil else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { print("[SSDP] socket() failed: \(errno)"); return }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.multicastPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound: Bool = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }

        var rcvbuf: Int32 = 256 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        var loop: UInt8 = 1
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        if bound {
            // INADDR_ANY joins the group on the default interface; per-interface
            // joins extend coverage to the rest (ENOBUFS/EADDRINUSE here just
            // means the interface was already covered by the ANY join).
            _ = joinGroup(on: fd, interface: in_addr(s_addr: INADDR_ANY))
            for iface in Self.localIPv4Addresses() {
                var ifAddr = in_addr()
                if inet_pton(AF_INET, iface, &ifAddr) == 1 {
                    _ = joinGroup(on: fd, interface: ifAddr)
                }
            }
            print("[SSDP] Listening on :1900, joined 239.255.255.250")
        } else {
            print("[SSDP] bind(:1900) failed (\(errno)); send-only mode, discovery of TVs still works")
        }

        socketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(fd) }
        readSource = source
        source.resume()
        sendMsearchBurst()
    }

    @discardableResult
    private func joinGroup(on fd: Int32, interface: in_addr) -> Bool {
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = inet_addr(Self.multicastHost)
        mreq.imr_interface = interface
        return setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0
    }

    private func closeLocked() {
        readSource?.cancel()
        readSource = nil
        socketFD = -1
        print("[SSDP] Stopped")
    }

    // MARK: - Receive

    private func drain() {
        let fd = socketFD
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let capacity = buffer.count
        while true {
            var src = sockaddr_storage()
            var srcLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count: Int = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &src) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, base, capacity, MSG_DONTWAIT, $0, &srcLen)
                    }
                }
            }
            if count <= 0 { break }
            lastReceive = Date()
            var srcIP = ""
            var srcPort: UInt16 = 0
            if src.ss_family == sa_family_t(AF_INET) {
                withUnsafePointer(to: &src) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        var tmp = sin.pointee.sin_addr
                        var dst = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        inet_ntop(AF_INET, &tmp, &dst, socklen_t(INET_ADDRSTRLEN))
                        srcIP = String(cString: dst)
                        srcPort = UInt16(bigEndian: sin.pointee.sin_port)
                    }
                }
            }
            handlePacket(Data(buffer[..<count]), fromIP: srcIP, fromPort: srcPort)
        }
    }

    private func handlePacket(_ data: Data, fromIP: String, fromPort: UInt16) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        if text.hasPrefix("M-SEARCH") {
            answerMSearch(text, fromIP: fromIP, fromPort: fromPort)
        } else {
            handleSSDPResponse(text)
        }
    }

    // MARK: - Send

    private func sendMsearchBurst() {
        let targets = [
            "ssdp:all",
            "urn:schemas-upnp-org:device:MediaRenderer:1",
            "urn:schemas-upnp-org:service:AVTransport:1",
        ]
        for round in 0..<3 {
            for (index, st) in targets.enumerated() {
                let delay = Double(round) * 0.6 + Double(index) * 0.2
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.sendSingleMsearch(st: st)
                }
            }
        }
    }

    private func sendSingleMsearch(st: String) {
        let text = "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: \(Self.multicastHost):\(Self.multicastPort)\r\n"
            + "MAN: \"ns=01; ns=01\"\r\n"
            + "MX: 3\r\n"
            + "ST: \(st)\r\n"
            + "USER-AGENT: Dixie/1.0 UPnP/1.1\r\n"
            + "\r\n"
        sendText(text, host: Self.multicastHost, port: Self.multicastPort)
    }

    private func sendText(_ text: String, host: String, port: UInt16) {
        let fd = socketFD
        guard fd >= 0, let data = text.data(using: .utf8) else { return }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, base, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func answerMSearch(_ text: String, fromIP: String, fromPort: UInt16) {
        // Our own M-SEARCH egresses from :1900, so it echoes back to us.
        guard !(fromPort == Self.multicastPort && localIPs.contains(fromIP)) else { return }
        let st = header(in: text, named: "ST") ?? ""
        guard let handler = msearchHandler,
              let response = handler(st),
              !response.isEmpty,
              !fromIP.isEmpty, fromPort != 0 else { return }
        print("[SSDP] M-SEARCH for ST=\(st) from \(fromIP):\(fromPort)")
        let delay = Double.random(in: 0...0.8)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.sendText(response, host: fromIP, port: fromPort)
        }
    }

    // MARK: - Discovery parsing

    private func header(in text: String, named name: String) -> String? {
        let want = name.uppercased()
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            guard key == want else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func handleSSDPResponse(_ response: String) {
        let upper = response.uppercased()
        guard upper.hasPrefix("HTTP/1.1 200") || upper.contains("NTS: SSDP:ALIVE") || upper.hasPrefix("NOTIFY") else { return }

        var headers: [String: String] = [:]
        for line in response.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).uppercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if headers[key] == nil { headers[key] = value }
        }

        guard let locationStr = headers["LOCATION"],
              let location = URL(string: locationStr),
              location.host != nil else { return }

        let usn = headers["USN"] ?? "\(locationStr)#\(headers["ST"] ?? headers["NT"] ?? "unknown")"
        if let ignored = ignoredUSNSubstring, usn.contains(ignored) { return }
        let server = headers["SERVER"] ?? ""
        let st = headers["ST"] ?? headers["NT"] ?? "unknown"

        devicesLock.lock()
        let isNew = discoveredDevices[usn] == nil
        let device = DiscoveredUPnPDevice(usn: usn, location: location, server: server, st: st)
        discoveredDevices[usn] = device
        devicesLock.unlock()

        if isNew {
            print("[SSDP] Discovered device: \(st) at \(location)")
            onDeviceDiscovered?(device)
        }
    }

    func getDevices() -> [DiscoveredUPnPDevice] {
        devicesLock.lock()
        let devices = Array(discoveredDevices.values)
        devicesLock.unlock()
        print("[SSDP] Returning \(devices.count) devices")
        return devices
    }

    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
            let ip = String(cString: hostname)
            if !ip.isEmpty { result.append(ip) }
        }
        return result
    }
}
