import Foundation
import Network

@MainActor
final class DLNAServer: ObservableObject {
    @Published var isRunning = false
    @Published var port: UInt16 = 8080
    
    private var httpServer: DLNAHTTPServer?
    private var mediaLibrary: MediaLibrary?
    private var contentDirectory: ContentDirectoryService?
    private var ssdpDiscovery: SSDPDiscovery?
    private var ssdpNotifyTimer: Timer?
    
    func configure(mediaLibrary: MediaLibrary) {
        self.mediaLibrary = mediaLibrary
        self.contentDirectory = ContentDirectoryService()
        self.contentDirectory?.setMediaLibrary(mediaLibrary)
        
        self.ssdpDiscovery = SSDPDiscovery()
    }
    
    func start() throws {
        httpServer = DLNAHTTPServer(port: port)
        
        let contentDir = contentDirectory
        let library = mediaLibrary
        
        httpServer?.onContentDirectoryRequest = { action, objectId, startingIndex, requestedCount in
            guard let contentDir = contentDir else {
                return "error"
            }
            
            if action == "Browse" {
                return await contentDir.browse(objectId: objectId, startingIndex: startingIndex, requestedCount: requestedCount)
            } else if action == "Search" {
                return await contentDir.search(objectId: objectId, searchCriteria: "", startingIndex: startingIndex, requestedCount: requestedCount)
            }
            return "error"
        }
        
        httpServer?.onMediaRequest = { [library] url in
            guard let pathComponents = url.pathComponents.dropFirst().first else {
                return nil
            }
            
            if pathComponents == "content" {
                return nil
            }
            
            guard let itemId = UUID(uuidString: pathComponents) else {
                return nil
            }
            
            return nil
        }
        
        try httpServer?.start()
        isRunning = true
        
        startSSDPDiscovery()
        startSSDPNotify()
        
        let localIP = getLocalIP()
        print("DLNA Server started at http://\(localIP):\(port)")
        print("Device should appear on TV as: Dixie Media Server")
    }
    
    func stop() {
        httpServer?.stop()
        ssdpDiscovery?.stop()
        ssdpNotifyTimer?.invalidate()
        ssdpNotifyTimer = nil
        isRunning = false
    }
    
    private func startSSDPDiscovery() {
        ssdpDiscovery?.start()
        ssdpDiscovery?.onDeviceDiscovered = { device in
            print("Discovered: \(device.st) at \(device.location)")
        }
    }
    
    private func startSSDPNotify() {
        sendSSDPNotify()
        
        ssdpNotifyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendSSDPNotify()
            }
        }
    }
    
    private func sendSSDPNotify() {
        let localIP = getLocalIP()
        
        let notifyMessage = """
        NOTIFY * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        NT: upnp:rootdevice\r
        USN: uuid:dixie-12345678-1234-1234-1234-123456789abc::upnp:rootdevice\r
        NTS: ssdp:alive\r
        SERVER: Dixie/1.0 UPnP/1.1\r
        LOCATION: http://\(localIP):\(port)/description.xml\r
        CACHE-CONTROL: max-age=1800\r
        \r
        
        """
        
        let notifyMessage2 = """
        NOTIFY * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        NT: urn:schemas-upnp-org:device:MediaServer:1\r
        USN: uuid:dixie-12345678-1234-1234-1234-123456789abc::urn:schemas-upnp-org:device:MediaServer:1\r
        NTS: ssdp:alive\r
        SERVER: Dixie/1.0 UPnP/1.1\r
        LOCATION: http://\(localIP):\(port)/description.xml\r
        CACHE-CONTROL: max-age=1800\r
        \r
        
        """
        
        DispatchQueue.global(qos: .background).async {
            let host = NWEndpoint.Host("239.255.255.250")
            let port = NWEndpoint.Port(rawValue: 1900)!
            let endpoint = NWEndpoint.hostPort(host: host, port: port)
            
            let params = NWParameters.udp
            if let connection = try? NWConnection(to: endpoint, using: params) {
                connection.start(queue: .global(qos: .background))
                
                connection.send(content: notifyMessage.data(using: .utf8), completion: .contentProcessed { _ in })
                connection.send(content: notifyMessage2.data(using: .utf8), completion: .contentProcessed { _ in })
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    connection.cancel()
                }
            }
        }
    }
    
    private func getLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return address }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            let interface = ptr!.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        
        return address
    }
}

final class DLNAHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.dixie.http")
    private var connections: [NWConnection] = []
    
    var onContentDirectoryRequest: ((String, String, Int, Int) async -> String)?
    var onMediaRequest: (@Sendable (URL) -> (Data?, String)?)?
    
    init(port: UInt16 = 8080) {
        self.port = port
    }
    
    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            let port = self.port
            if case .ready = state {
                print("DLNA HTTP Server started on port \(port)")
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        listener?.start(queue: queue)
    }
    
    func stop() {
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receiveRequest(connection)
            }
        }
        connection.start(queue: queue)
    }
    
    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, _ in
            if let content = content {
                self?.handleHTTPRequest(content: content, connection: connection)
            }
        }
    }
    
    private func handleHTTPRequest(content: Data, connection: NWConnection) {
        guard let request = String(data: content, encoding: .utf8) else { return }
        
        let lines = request.components(separatedBy: "\r\n")
        
        guard let requestLine = lines.first else { return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        
        let method = parts[0]
        let path = parts[1]
        
        if path == "/description.xml" {
            sendDescriptionXML(connection: connection)
            return
        }
        
        if method == "GET" {
            if path.hasPrefix("/content/") || path.hasPrefix("/MediaServer/") {
                handleContentDirectoryRequest(path: path, lines: lines, connection: connection)
            } else if let url = URL(string: path), let result = onMediaRequest?(url) {
                let (data, contentType) = result
                sendResponse(data: data, contentType: contentType, connection: connection)
            } else {
                send404(connection: connection)
            }
        } else if method == "POST" {
            handleSOAPRequest(content: content, connection: connection)
        } else {
            send404(connection: connection)
        }
    }
    
    private func sendDescriptionXML(connection: NWConnection) {
        let localIP = getLocalIP()
        let port = self.port
        
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
            <specVersion>
                <major>1</major>
                <minor>0</minor>
            </specVersion>
            <device>
                <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
                <friendlyName>Dixie Media Server</friendlyName>
                <manufacturer>Dixie</manufacturer>
                <modelName>Dixie Media Server</modelName>
                <UDN>uuid:dixie-12345678-1234-1234-1234-123456789abc</UDN>
                <serviceList>
                    <service>
                        <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
                        <serviceId>urn:schemas-upnp-org:serviceId:ContentDirectory</serviceId>
                        <controlURL>/MediaServer/ContentDirectory/Control</controlURL>
                        <eventSubURL>/MediaServer/ContentDirectory/Event</eventSubURL>
                        <SCPDURL>/ContentDirectory/ContentDirectory.xml</SCPDURL>
                    </service>
                    <service>
                        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
                        <serviceId>urn:schemas-upnp-org:serviceId:ConnectionManager</serviceId>
                        <controlURL>/MediaServer/ConnectionManager/Control</controlURL>
                        <eventSubURL>/MediaServer/ConnectionManager/Event</eventSubURL>
                        <SCPDURL>/ConnectionManager/ConnectionManager.xml</SCPDURL>
                    </service>
                </serviceList>
            </device>
        </root>
        """
        
        sendResponse(data: xml.data(using: .utf8), contentType: "text/xml", connection: connection)
    }
    
    private func handleContentDirectoryRequest(path: String, lines: [String], connection: NWConnection) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/xml; charset="utf-8"\r
        \r
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
                    <Result></Result>
                    <NumberReturned>0</NumberReturned>
                    <TotalMatches>0</TotalMatches>
                    <UpdateID>1</UpdateID>
                </u:BrowseResponse>
            </s:Body>
        </s:Envelope>
        """
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    
    private func handleSOAPRequest(content: Data, connection: NWConnection) {
        guard let request = String(data: content, encoding: .utf8) else {
            send404(connection: connection)
            return
        }
        
        Task {
            let objectId = "0"
            let startingIndex = 0
            let requestedCount = 100
            var action = "Browse"
            
            if request.contains("Browse") {
                action = "Browse"
            }
            
            if let result = await onContentDirectoryRequest?(action, objectId, startingIndex, requestedCount) {
                let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/xml; charset=utf-8\r\n\r\n\(result)"
                connection.send(content: httpResponse.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else {
                send404(connection: connection)
            }
        }
    }
    
    private func sendResponse(data: Data?, contentType: String, connection: NWConnection) {
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(data?.count ?? 0)\r\n"
        response += "Accept-Ranges: bytes\r\n"
        response += "Server: Dixie/1.0\r\n\r\n"
        
        var responseData = response.data(using: .utf8) ?? Data()
        if let data = data { responseData.append(data) }
        
        connection.send(content: responseData, completion: .contentProcessed { _ in connection.cancel() })
    }
    
    private func send404(connection: NWConnection) {
        connection.send(content: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    
    private func getLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return address }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            let interface = ptr!.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        
        return address
    }
}