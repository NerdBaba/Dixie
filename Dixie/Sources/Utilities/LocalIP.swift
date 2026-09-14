import Foundation

enum NetworkUtil {
    /// RFC 1123 date, required on HTTP responses and SSDP headers.
    static func httpDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: Date())
    }

    static func localIPv4Address() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return address }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        var fallback: String?
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let interface = current.pointee
            guard let addr = interface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name != "lo0", (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
            hostname.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let ip = String(cString: base)
                if name == "en0" { address = ip }
                else if fallback == nil { fallback = ip }
            }
            if name == "en0", address != "127.0.0.1" { return address }
        }

        return address == "127.0.0.1" ? (fallback ?? address) : address
    }
}
