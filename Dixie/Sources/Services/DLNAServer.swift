import Foundation
import Network

@MainActor
final class DLNAServer: ObservableObject {
    nonisolated static let deviceUUID = "dixie-12345678-1234-1234-1234-123456789abc"

    @Published var isRunning = false
    @Published var port: UInt16 = 8080

    private var httpServer: DLNAHTTPServer?
    private var mediaLibrary: MediaLibrary?
    private var contentDirectory: ContentDirectoryService?
    private var ssdpResponder: SSDPDiscovery?
    private var ssdpNotify: SSDPNotifier?
    private var ssdpNotifyTimer: Timer?

    func configure(mediaLibrary: MediaLibrary) {
        self.mediaLibrary = mediaLibrary
        self.contentDirectory = ContentDirectoryService()
        self.contentDirectory?.setMediaLibrary(mediaLibrary)
    }

    func start() throws {
        let server = DLNAHTTPServer(port: port)
        let contentDir = contentDirectory ?? ContentDirectoryService()
        contentDir.setMediaLibrary(mediaLibrary ?? MediaLibrary())
        contentDir.setPort(port)
        contentDirectory = contentDir
        let library = mediaLibrary

        server.onContentDirectoryRequest = { action, objectId, searchCriteria, startingIndex, requestedCount in
            if action == "Browse" {
                return await contentDir.browse(objectId: objectId, startingIndex: startingIndex, requestedCount: requestedCount)
            } else if action == "Search" {
                return await contentDir.search(objectId: objectId, searchCriteria: searchCriteria, startingIndex: startingIndex, requestedCount: requestedCount)
            }
            return ContentDirectoryService.soapFault(code: "401", description: "Invalid Action")
        }

        server.onMediaRequest = { @Sendable [weak library] url in
            guard url.pathComponents.count >= 3,
                  url.pathComponents[1] == "content",
                  let id = UUID(uuidString: url.pathComponents[2]) else {
                return nil
            }
            guard let library else { return nil }
            return MediaResolver.resolve(id: id, library: library)
        }

        httpServer = server
        try server.start()
        isRunning = true

        let localIP = NetworkUtil.localIPv4Address()
        let location = "http://\(localIP):\(port)/description.xml"
        print("DLNA Server started at \(location)")
        print("Device should appear on TV as: Dixie Media Server")

        ssdpNotify = SSDPNotifier(port: port, uuid: Self.deviceUUID)
        ssdpNotify?.sendAlive()
        ssdpNotifyTimer?.invalidate()
        ssdpNotifyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ssdpNotify?.sendAlive() }
        }

        let responder = SSDPDiscovery()
        let replyPort = port
        let replyLocation = location
        responder.msearchHandler = { st in
            SSDPNotifier.replyPayload(port: replyPort, uuid: DLNAServer.deviceUUID, st: st, location: replyLocation)
        }
        // Do not surface our own advert as a discovered "TV".
        responder.ignoredUSNSubstring = Self.deviceUUID
        responder.start()
        ssdpResponder = responder
    }

    func stop() {
        if let notifier = ssdpNotify {
            notifier.sendByebye()
        }
        httpServer?.stop()
        httpServer = nil
        ssdpResponder?.stop()
        ssdpResponder = nil
        ssdpNotify = nil
        ssdpNotifyTimer?.invalidate()
        ssdpNotifyTimer = nil
        isRunning = false
    }
}

/// Synchronous bridge from the HTTP path to the async MediaLibrary.
///
/// Local files are read into memory and streamed with Range support. Remote
/// items are returned as a redirect: DLNA renderers fetch internet streams
/// themselves, and proxying would only add a bottleneck.
private enum MediaResolver: Sendable {
    static func resolve(id: UUID, library: MediaLibrary) -> DLNAHTTPServer.MediaResponse? {
        let box = SyncBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if let item = await library.item(id: id) {
                if item.url.isFileURL {
                    if let data = try? Data(contentsOf: item.url), !data.isEmpty {
                        box.set(.data(data, item.mimeType))
                    }
                } else {
                    box.set(.redirect(item.url.absoluteString))
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()
    }
}

private final class SyncBox: @unchecked Sendable {
    private var value: DLNAHTTPServer.MediaResponse?
    private let lock = NSLock()
    func set(_ newValue: DLNAHTTPServer.MediaResponse?) {
        lock.lock(); value = newValue; lock.unlock()
    }
    func get() -> DLNAHTTPServer.MediaResponse? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// Sends SSDP NOTIFY alive/byebye over a plain BSD UDP socket.
///
/// Deliberately does NOT bind :1900 or join the multicast group — that socket
/// belongs to SSDPDiscovery. A send-only socket on the primary LAN interface is
/// all NOTIFY needs, and it keeps the two roles independently restartable.
final class SSDPNotifier: @unchecked Sendable {
    private let port: UInt16
    private let uuid: String
    private var socketFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.dixie.ssdp-notify")

    init(port: UInt16, uuid: String) {
        self.port = port
        self.uuid = uuid
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { print("[SSDP] notifier socket() failed: \(errno)"); return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var loop: UInt8 = 1
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
        // Pin egress to the primary LAN address so NOTIFY does not leave via a VM bridge.
        var ifAddr = in_addr()
        if inet_pton(AF_INET, NetworkUtil.localIPv4Address(), &ifAddr) == 1 {
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifAddr, socklen_t(MemoryLayout<in_addr>.size))
        }
        socketFD = fd
    }

    deinit {
        if socketFD >= 0 { Darwin.close(socketFD) }
    }

    static func replyPayload(port: UInt16, uuid: String, st: String, location: String) -> String? {
        let trimmed = st.trimmingCharacters(in: .whitespacesAndNewlines)
        let supported = [
            "upnp:rootdevice",
            "urn:schemas-upnp-org:device:MediaServer:1",
            "urn:schemas-upnp-org:service:ContentDirectory:1",
            "urn:schemas-upnp-org:service:ConnectionManager:1",
            "ssdp:all",
        ]
        guard supported.contains(trimmed) || trimmed.hasPrefix("uuid:\(uuid)") else { return nil }
        let usn: String
        if trimmed == "ssdp:all" || trimmed.hasPrefix("uuid:") {
            usn = "uuid:\(uuid)::upnp:rootdevice"
        } else {
            usn = "uuid:\(uuid)::\(trimmed)"
        }
        return "HTTP/1.1 200 OK\r\n"
            + "CACHE-CONTROL: max-age=1800\r\n"
            + "DATE: \(NetworkUtil.httpDate())\r\n"
            + "EXT:\r\n"
            + "LOCATION: \(location)\r\n"
            + "SERVER: Dixie/1.0 UPnP/1.1\r\n"
            + "ST: \(trimmed == "ssdp:all" ? "upnp:rootdevice" : trimmed)\r\n"
            + "USN: \(usn)\r\n"
            + "\r\n"
    }

    func sendAlive() {
        let localIP = NetworkUtil.localIPv4Address()
        let location = "http://\(localIP):\(port)/description.xml"
        let targets = [
            "upnp:rootdevice",
            "uuid:\(uuid)",
            "urn:schemas-upnp-org:device:MediaServer:1",
            "urn:schemas-upnp-org:service:ContentDirectory:1",
            "urn:schemas-upnp-org:service:ConnectionManager:1",
        ]
        for nt in targets {
            let usn = nt.hasPrefix("uuid:") ? nt : "uuid:\(uuid)::\(nt)"
            let msg = "NOTIFY * HTTP/1.1\r\n"
                + "HOST: \(SSDPDiscovery.multicastHost):\(SSDPDiscovery.multicastPort)\r\n"
                + "CACHE-CONTROL: max-age=1800\r\n"
                + "LOCATION: \(location)\r\n"
                + "NT: \(nt)\r\n"
                + "NTS: ssdp:alive\r\n"
                + "SERVER: Dixie/1.0 UPnP/1.1\r\n"
                + "USN: \(usn)\r\n"
                + "\r\n"
            multicast(msg)
        }
        print("[SSDP] NOTIFY alive sent from \(localIP):\(port)")
    }

    func sendByebye() {
        for nt in ["upnp:rootdevice", "urn:schemas-upnp-org:device:MediaServer:1"] {
            let msg = "NOTIFY * HTTP/1.1\r\n"
                + "HOST: \(SSDPDiscovery.multicastHost):\(SSDPDiscovery.multicastPort)\r\n"
                + "NT: \(nt)\r\n"
                + "NTS: ssdp:byebye\r\n"
                + "USN: uuid:\(uuid)::\(nt)\r\n"
                + "\r\n"
            multicast(msg)
        }
    }

    private func multicast(_ text: String) {
        queue.async { [self] in
            guard socketFD >= 0, let data = text.data(using: .utf8) else { return }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = SSDPDiscovery.multicastPort.bigEndian
            inet_pton(AF_INET, SSDPDiscovery.multicastHost, &addr.sin_addr)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        let sent = sendto(socketFD, base, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        if sent < 0 { print("[SSDP] NOTIFY send error: \(errno)") }
                    }
                }
            }
        }
    }

}

final class DLNAHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.dixie.http")
    private var connections: [NWConnection] = []
    private let connectionsLock = NSLock()

    enum MediaResponse {
        case data(Data, String)
        case redirect(String)
    }

    private static let serverHeader = "Dixie/1.0 UPnP/1.1"

    /// Advertised in ConnectionManager.GetProtocolInfo and in its initial event.
    static let sourceProtocolInfo = "http-get:*:audio/mpeg:DLNA.ORG_PN=MP3;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        + ",http-get:*:audio/mp4:*"
        + ",http-get:*:audio/x-wav:*"
        + ",http-get:*:audio/flac:*"
        + ",http-get:*:video/mp4:*"
        + ",http-get:*:video/x-matroska:*"
        + ",http-get:*:video/x-msvideo:*"
        + ",http-get:*:video/quicktime:*"
        + ",http-get:*:image/jpeg:*"
        + ",http-get:*:image/png:*"

    /// (action, objectId, searchCriteria, startingIndex, requestedCount)
    var onContentDirectoryRequest: ((String, String, String, Int, Int) async -> String)?
    var onMediaRequest: (@Sendable (URL) -> MediaResponse?)?

    init(port: UInt16 = 8080) {
        self.port = port
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("DLNA HTTP Server started on port \(self.port)")
            case .failed(let error):
                print("[HTTP] Listener failed: \(error)")
            case .waiting(let error):
                print("[HTTP] Listener waiting: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connectionsLock.lock()
        let conns = connections
        connections.removeAll()
        connectionsLock.unlock()
        conns.forEach { $0.cancel() }
    }

    private func handleConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.append(connection)
        connectionsLock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveFullRequest(connection, accumulated: Data())
            case .failed, .cancelled:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func forget(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.removeAll { $0 === connection }
        connectionsLock.unlock()
    }

    /// Accumulate until end of headers, then honour Content-Length so split
    /// TCP segments (the norm for TV SOAP POSTs) are handled.
    private func receiveFullRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let content = content, !content.isEmpty { buffer.append(content) }
            if error != nil || isComplete {
                if !buffer.isEmpty { self.dispatch(buffer, connection: connection) }
                else { connection.cancel() }
                self.forget(connection)
                return
            }
            if self.isRequestComplete(buffer) {
                self.dispatch(buffer, connection: connection)
                self.forget(connection)
            } else {
                self.receiveFullRequest(connection, accumulated: buffer)
            }
        }
    }

    private func isRequestComplete(_ data: Data) -> Bool {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 131072 }
        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return true }
        var contentLength = 0
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).uppercased() == "CONTENT-LENGTH" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyBytes = data.count - headerEnd.upperBound
        return bodyBytes >= contentLength
    }

    private func dispatch(_ data: Data, connection: NWConnection) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            send400(connection: connection)
            return
        }
        let bodyData = data[headerEnd.upperBound...]
        let bodyText = String(data: bodyData, encoding: .utf8) ?? ""
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { send400(connection: connection); return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { send400(connection: connection); return }

        let method = parts[0].uppercased()
        let rawPath = parts[1]
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        let headers = parseHeaders(lines)

        print("[HTTP] \(method) \(path) from \(connection.endpoint.debugDescription)")

        if method == "GET" || method == "HEAD" {
            handleGET(path: path, headers: headers, headOnly: method == "HEAD", connection: connection)
        } else if method == "POST" || method == "M-POST" {
            handleSOAPRequest(headers: headers, body: bodyText, connection: connection)
        } else if method == "SUBSCRIBE" {
            handleSubscribe(headers: headers, path: path, connection: connection)
        } else if method == "UNSUBSCRIBE" {
            sendStatus(200, reason: "OK", connection: connection)
        } else {
            send405(connection: connection, allowed: "GET, HEAD, POST, SUBSCRIBE, UNSUBSCRIBE")
        }
    }

    private func parseHeaders(_ lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0]).trimmingCharacters(in: .whitespaces).uppercased()] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return headers
    }

    // MARK: - GET

    private func handleGET(path: String, headers: [String: String], headOnly: Bool, connection: NWConnection) {
        let decoded = path.removingPercentEncoding ?? path
        switch true {
        case decoded == "/description.xml" || decoded == "/dev/description.xml" || decoded == "/rootDesc.xml":
            sendXML(descriptionXML(), connection: connection, headOnly: headOnly)
        case decoded == "/" || decoded == "/index.html":
            sendHTML(presentationPage(), connection: connection, headOnly: headOnly)
        case decoded == "/ContentDirectory/ContentDirectory.xml" || decoded == "/ContentDirectory.xml":
            sendXML(contentDirectorySCPD(), connection: connection, headOnly: headOnly)
        case decoded == "/ConnectionManager/ConnectionManager.xml" || decoded == "/ConnectionManager.xml":
            sendXML(connectionManagerSCPD(), connection: connection, headOnly: headOnly)
        case decoded.hasPrefix("/content/"):
            serveMedia(path: decoded, headers: headers, headOnly: headOnly, connection: connection)
        default:
            send404(connection: connection)
        }
    }

    private func serveMedia(path: String, headers: [String: String], headOnly: Bool, connection: NWConnection) {
        let idString = String(path.dropFirst("/content/".count)).components(separatedBy: "?").first ?? ""
        guard UUID(uuidString: idString) != nil,
              let url = URL(string: "/content/\(idString)"),
              let result = onMediaRequest?(url) else {
            send404(connection: connection)
            return
        }

        // Remote sources are not proxied: send the TV straight to the origin.
        if case .redirect(let target) = result {
            print("[HTTP] 302 /content/\(idString) -> \(target)")
            sendRedirect(to: target, connection: connection)
            return
        }

        guard case .data(let data, let contentType) = result, !data.isEmpty else {
            send404(connection: connection)
            return
        }

        var start = 0
        var end = data.count - 1
        var partial = false
        if let range = headers["RANGE"], range.hasPrefix("bytes=") {
            let spec = String(range.dropFirst("bytes=".count))
            let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if bounds.count == 2 {
                if let s = Int(bounds[0]) { start = max(0, s) }
                if !bounds[1].isEmpty, let e = Int(bounds[1]) { end = min(data.count - 1, e) }
                if start <= end { partial = true } else { send416(dataLength: data.count, connection: connection); return }
            }
        }
        let slice = partial ? data[start...end] : data[0..<data.count]
        var response = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(slice.count)\r\n"
        response += "Accept-Ranges: bytes\r\n"
        if partial { response += "Content-Range: bytes \(start)-\(end)/\(data.count)\r\n" }
        response += "transferMode.dlna.org: Streaming\r\n"
        response += "Server: Dixie/1.0 UPnP/1.1\r\n"
        response += "Connection: close\r\n\r\n"
        var out = response.data(using: .utf8) ?? Data()
        if !headOnly { out.append(contentsOf: slice) }
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - SOAP

    private func handleSOAPRequest(headers: [String: String], body: String, connection: NWConnection) {
        let soapAction = (headers["SOAPACTION"] ?? "").replacingOccurrences(of: "\"", with: "")
        let handler = onContentDirectoryRequest
        Task {
            let service: String
            if soapAction.contains("ContentDirectory") || body.contains("ContentDirectory") {
                service = "ContentDirectory"
            } else if soapAction.contains("ConnectionManager") || body.contains("ConnectionManager") {
                service = "ConnectionManager"
            } else if body.contains(":Browse") || body.contains("Browse") {
                service = "ContentDirectory"
            } else {
                Self.sendSOAPFault(connection: connection, code: "401", description: "Invalid Action")
                return
            }

            if service == "ConnectionManager" {
                Self.handleConnectionManager(soapAction: soapAction, body: body, connection: connection)
                return
            }

            let action: String
            if soapAction.contains("#Browse") || Self.tagPresent(body, "Browse") { action = "Browse" }
            else if soapAction.contains("#Search") || Self.tagPresent(body, "Search") { action = "Search" }
            else if soapAction.contains("#GetSearchCapabilities") { Self.sendSOAPBody(connection: connection, actionResponse: "GetSearchCapabilities", innerXML: "<SearchCaps></SearchCaps>"); return }
            else if soapAction.contains("#GetSortCapabilities") { Self.sendSOAPBody(connection: connection, actionResponse: "GetSortCapabilities", innerXML: "<SortCaps>dc:title,dc:date</SortCaps>"); return }
            else if soapAction.contains("#GetSystemUpdateID") { Self.sendSOAPBody(connection: connection, actionResponse: "GetSystemUpdateID", innerXML: "<Id>1</Id>"); return }
            else { Self.sendSOAPFault(connection: connection, code: "401", description: "Invalid Action: \(soapAction)"); return }

            // Browse uses ObjectID; Search uses ContainerID + SearchCriteria.
            let objectId = Self.tagValue(body, names: ["ObjectID", "ObjectId", "objectId", "ContainerID"]) ?? "0"
            let browseFlag = Self.tagValue(body, names: ["BrowseFlag"]) ?? "BrowseDirectChildren"
            let searchCriteria = Self.tagValue(body, names: ["SearchCriteria"]) ?? ""
            let startingIndex = Int(Self.tagValue(body, names: ["StartingIndex"]) ?? "0") ?? 0
            let requestedCount = Int(Self.tagValue(body, names: ["RequestedCount"]) ?? "0") ?? 0

            print("[DLNA] SOAP \(action) objectId=\(objectId) flag=\(browseFlag) criteria=\(searchCriteria) start=\(startingIndex) count=\(requestedCount)")

            let effectiveId = action == "Browse" ? "\(objectId)|\(browseFlag)" : objectId
            if let result = await handler?(action, effectiveId, searchCriteria, startingIndex, requestedCount) {
                Self.sendSOAPBody(connection: connection, actionResponse: "\(action)Response", innerXML: result)
            } else {
                Self.sendSOAPFault(connection: connection, code: "501", description: "Action Failed")
            }
        }
    }

    private static func tagPresent(_ body: String, _ name: String) -> Bool {
        body.range(of: "<\(name)[ >]", options: [.regularExpression, .caseInsensitive]) != nil
            || body.range(of: "<u:\(name)[ >]", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func tagValue(_ body: String, names: [String]) -> String? {
        for name in names {
            if let open = body.range(of: "<\(name)>", options: .caseInsensitive) {
                let rest = body[open.upperBound...]
                if let close = rest.range(of: "</\(name)>", options: .caseInsensitive) {
                    return String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let open = body.range(of: "<u:\(name)>", options: .caseInsensitive) {
                let rest = body[open.upperBound...]
                if let close = rest.range(of: "</u:\(name)>", options: .caseInsensitive) {
                    return String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private static func handleConnectionManager(soapAction: String, body: String, connection: NWConnection) {
        if soapAction.contains("#GetProtocolInfo") || tagPresent(body, "GetProtocolInfo") {
            let inner = "<Source>\(sourceProtocolInfo.xmlEscaped())</Source><Sink></Sink>"
            sendSOAPBody(connection: connection, actionResponse: "GetProtocolInfoResponse", innerXML: inner)
        } else if soapAction.contains("#GetCurrentConnectionIDs") {
            sendSOAPBody(connection: connection, actionResponse: "GetCurrentConnectionIDsResponse", innerXML: "<ConnectionIDs>0</ConnectionIDs>")
        } else if soapAction.contains("#GetCurrentConnectionInfo") {
            sendSOAPBody(connection: connection, actionResponse: "GetCurrentConnectionInfoResponse", innerXML: "<RcsID>-1</RcsID><AVTransportID>-1</AVTransportID><ProtocolInfo>http-get:*:*:*</ProtocolInfo><PeerConnectionManager>/MediaServer/ConnectionManager/Control</PeerConnectionManager><PeerConnectionID>-1</PeerConnectionID><Direction>Output</Direction><Status>OK</Status>")
        } else {
            sendSOAPFault(connection: connection, code: "401", description: "Invalid Action")
        }
    }

    private static func sendSOAPBody(connection: NWConnection, actionResponse: String, innerXML: String, isFullEnvelope: Bool = false) {
        let body: String
        if actionResponse == "Fault" {
            body = """
            <?xml version="1.0" encoding="UTF-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                <s:Body>
                    <s:Fault>\(innerXML)</s:Fault>
                </s:Body>
            </s:Envelope>
            """
        } else {
            let ns = actionResponse.hasPrefix("GetProtocolInfo") || actionResponse.hasPrefix("GetCurrentConnection")
                ? "urn:schemas-upnp-org:service:ConnectionManager:1"
                : "urn:schemas-upnp-org:service:ContentDirectory:1"
            let wrapper: String
            if isFullEnvelope {
                wrapper = innerXML
            } else {
                wrapper = "<u:\(actionResponse) xmlns:u=\"\(ns)\">\(innerXML)</u:\(actionResponse)>"
            }
            body = """
            <?xml version="1.0" encoding="UTF-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                <s:Body>\(wrapper)</s:Body>
            </s:Envelope>
            """
        }
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/xml; charset=utf-8\r\n"
        header += "Content-Length: \(body.utf8.count)\r\n"
        header += "EXT:\r\n"
        header += "Server: Dixie/1.0 UPnP/1.1\r\n"
        header += "Connection: close\r\n\r\n"
        var out = header.data(using: .utf8) ?? Data()
        out.append(contentsOf: body.utf8)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func sendSOAPFault(connection: NWConnection, code: String, description: String) {
        sendSOAPBody(connection: connection, actionResponse: "Fault",
                     innerXML: "<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>\(code)</errorCode><errorDescription>\(description)</errorDescription></UPnPError></detail>")
    }

    // MARK: - GENA eventing

    /// UPnP control points subscribe to a service's eventSubURL *before* they
    /// will show its content. A 200 without `SID`/`TIMEOUT` is malformed, and
    /// TVs surface that as "device disconnected".
    private func handleSubscribe(headers: [String: String], path: String, connection: NWConnection) {
        if let sid = headers["SID"] {
            print("[DLNA] SUBSCRIBE renew \(sid) for \(path)")
            sendSubscribeOK(sid: sid, connection: connection)
            return
        }
        guard let callbackHeader = headers["CALLBACK"],
              let callback = Self.firstResourceURL(in: callbackHeader) else {
            print("[DLNA] SUBSCRIBE without CALLBACK for \(path)")
            sendStatus(412, reason: "Precondition Failed", connection: connection)
            return
        }
        let sid = "uuid:" + UUID().uuidString.lowercased()
        print("[DLNA] SUBSCRIBE \(path) callback=\(callback)")
        sendSubscribeOK(sid: sid, connection: connection)
        sendInitialEvent(sid: sid, callback: callback, path: path)
    }

    private func sendSubscribeOK(sid: String, connection: NWConnection) {
        var response = "HTTP/1.1 200 OK\r\n"
        response += "DATE: \(NetworkUtil.httpDate())\r\n"
        response += "SERVER: \(Self.serverHeader)\r\n"
        response += "SID: \(sid)\r\n"
        response += "TIMEOUT: Second-1800\r\n"
        response += "CONTENT-LENGTH: 0\r\n"
        response += "Connection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// GENA requires the first event immediately after subscribing; some
    /// control points will not proceed until they receive it.
    private func sendInitialEvent(sid: String, callback: URL, path: String) {
        guard let host = callback.host else { return }
        let port = callback.port ?? (callback.scheme == "https" ? 443 : 80)

        let properties: String
        if path.contains("ConnectionManager") {
            properties = "<e:property><SourceProtocolInfo>\(Self.sourceProtocolInfo.xmlEscaped())</SourceProtocolInfo></e:property>"
                + "<e:property><SinkProtocolInfo></SinkProtocolInfo></e:property>"
                + "<e:property><CurrentConnectionIDs>0</CurrentConnectionIDs></e:property>"
        } else {
            properties = "<e:property><SystemUpdateID>1</SystemUpdateID></e:property>"
        }
        let body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<e:propertyset xmlns:e=\"urn:schemas-upnp-org:event-1-0\">\(properties)</e:propertyset>"
        let notifyPath = callback.path.isEmpty ? "/" : callback.path

        let message = "NOTIFY \(notifyPath) HTTP/1.1\r\n"
            + "HOST: \(host):\(port)\r\n"
            + "CONTENT-TYPE: text/xml; charset=\"utf-8\"\r\n"
            + "CONTENT-LENGTH: \(body.utf8.count)\r\n"
            + "NT: upnp:event\r\n"
            + "NTS: upnp:propchange\r\n"
            + "SID: \(sid)\r\n"
            + "SEQ: 0\r\n"
            + "CONNECTION: close\r\n\r\n"
            + body

        // Sent over a raw NWConnection rather than URLSession so App Transport
        // Security can never block a plain-HTTP callback on the LAN.
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "com.dixie.event")
        connection.stateUpdateHandler = { (state: NWConnection.State) in
            guard case .ready = state else { return }
            connection.send(content: message.data(using: .utf8), completion: .contentProcessed { error in
                if let error {
                    print("[DLNA] initial event to \(host):\(port) failed: \(error)")
                } else {
                    print("[DLNA] initial event sent to \(host):\(port)\(notifyPath)")
                }
                connection.cancel()
            })
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 6) {
            connection.cancel()
        }
    }

    /// `CALLBACK: <http://host:port/path>` — possibly with several alternatives.
    private static func firstResourceURL(in header: String) -> URL? {
        guard let open = header.firstIndex(of: "<"),
              let close = header[open...].firstIndex(of: ">") else { return nil }
        return URL(string: String(header[header.index(after: open)..<close]))
    }

    // MARK: - XML descriptors

    private func descriptionXML() -> String {
        let localIP = NetworkUtil.localIPv4Address()
        let base = "http://\(localIP):\(port)"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
            <specVersion><major>1</major><minor>0</minor></specVersion>
            <URLBase>\(base)/</URLBase>
            <device>
                <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
                <friendlyName>Dixie Media Server</friendlyName>
                <manufacturer>Dixie</manufacturer>
                <manufacturerURL>https://example.com</manufacturerURL>
                <modelDescription>Dixie DLNA Media Server</modelDescription>
                <modelName>Dixie Media Server</modelName>
                <modelNumber>1.0</modelNumber>
                <modelURL>https://example.com</modelURL>
                <serialNumber>12345678</serialNumber>
                <UDN>uuid:\(DLNAServer.deviceUUID)</UDN>
                <dlna:X_DLNADOC>DMS-1.50</dlna:X_DLNADOC>
                <serviceList>
                    <service>
                        <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
                        <serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>
                        <controlURL>/MediaServer/ContentDirectory/Control</controlURL>
                        <eventSubURL>/MediaServer/ContentDirectory/Event</eventSubURL>
                        <SCPDURL>/ContentDirectory/ContentDirectory.xml</SCPDURL>
                    </service>
                    <service>
                        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
                        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
                        <controlURL>/MediaServer/ConnectionManager/Control</controlURL>
                        <eventSubURL>/MediaServer/ConnectionManager/Event</eventSubURL>
                        <SCPDURL>/ConnectionManager/ConnectionManager.xml</SCPDURL>
                    </service>
                </serviceList>
                <presentationURL>\(base)/</presentationURL>
            </device>
        </root>
        """
    }

    private func contentDirectorySCPD() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0">
            <specVersion><major>1</major><minor>0</minor></specVersion>
            <actionList>
                <action><name>Browse</name><argumentList><argument><name>ObjectID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable></argument><argument><name>BrowseFlag</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_BrowseFlag</relatedStateVariable></argument><argument><name>Filter</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Filter</relatedStateVariable></argument><argument><name>StartingIndex</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Index</relatedStateVariable></argument><argument><name>RequestedCount</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>SortCriteria</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SortCriteria</relatedStateVariable></argument><argument><name>Result</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable></argument><argument><name>NumberReturned</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>TotalMatches</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>UpdateID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UpdateID</relatedStateVariable></argument></argumentList></action>
                <action><name>Search</name><argumentList><argument><name>ContainerID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable></argument><argument><name>SearchCriteria</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SearchCriteria</relatedStateVariable></argument><argument><name>Filter</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Filter</relatedStateVariable></argument><argument><name>StartingIndex</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Index</relatedStateVariable></argument><argument><name>RequestedCount</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>SortCriteria</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SortCriteria</relatedStateVariable></argument><argument><name>Result</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable></argument><argument><name>NumberReturned</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>TotalMatches</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>UpdateID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UpdateID</relatedStateVariable></argument></argumentList></action>
                <action><name>GetSearchCapabilities</name><argumentList><argument><name>SearchCaps</name><direction>out</direction><relatedStateVariable>SearchCapabilities</relatedStateVariable></argument></argumentList></action>
                <action><name>GetSortCapabilities</name><argumentList><argument><name>SortCaps</name><direction>out</direction><relatedStateVariable>SortCapabilities</relatedStateVariable></argument></argumentList></action>
                <action><name>GetSystemUpdateID</name><argumentList><argument><name>Id</name><direction>out</direction><relatedStateVariable>SystemUpdateID</relatedStateVariable></argument></argumentList></action>
            </actionList>
            <serviceStateTable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_ObjectID</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_Result</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_SearchCriteria</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_BrowseFlag</name><dataType>string</dataType><allowedValueList><allowedValue>BrowseMetadata</allowedValue><allowedValue>BrowseDirectChildren</allowedValue></allowedValueList></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_Filter</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_SortCriteria</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_Index</name><dataType>ui4</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_Count</name><dataType>ui4</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_UpdateID</name><dataType>ui4</dataType></stateVariable>
                <stateVariable sendEvents="yes"><name>SystemUpdateID</name><dataType>ui4</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>SearchCapabilities</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>SortCapabilities</name><dataType>string</dataType></stateVariable>
            </serviceStateTable>
        </scpd>
        """
    }

    private func connectionManagerSCPD() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0">
            <specVersion><major>1</major><minor>0</minor></specVersion>
            <actionList>
                <action><name>GetProtocolInfo</name><argumentList><argument><name>Source</name><direction>out</direction><relatedStateVariable>SourceProtocolInfo</relatedStateVariable></argument><argument><name>Sink</name><direction>out</direction><relatedStateVariable>SinkProtocolInfo</relatedStateVariable></argument></argumentList></action>
                <action><name>GetCurrentConnectionIDs</name><argumentList><argument><name>ConnectionIDs</name><direction>out</direction><relatedStateVariable>CurrentConnectionIDs</relatedStateVariable></argument></argumentList></action>
                <action><name>GetCurrentConnectionInfo</name><argumentList><argument><name>ConnectionID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument><argument><name>RcsID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_RcsID</relatedStateVariable></argument><argument><name>AVTransportID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_AVTransportID</relatedStateVariable></argument><argument><name>ProtocolInfo</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ProtocolInfo</relatedStateVariable></argument><argument><name>PeerConnectionManager</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_PeerConnectionManager</relatedStateVariable></argument><argument><name>PeerConnectionID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument><argument><name>Direction</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Direction</relatedStateVariable></argument><argument><name>Status</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionStatus</relatedStateVariable></argument></argumentList></action>
            </actionList>
            <serviceStateTable>
                <stateVariable sendEvents="yes"><name>SourceProtocolInfo</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="yes"><name>SinkProtocolInfo</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="yes"><name>CurrentConnectionIDs</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionID</name><dataType>i4</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_RcsID</name><dataType>i4</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_AVTransportID</name><dataType>i4</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_ProtocolInfo</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_PeerConnectionManager</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_Direction</name><dataType>string</dataType></stateVariable>
                <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionStatus</name><dataType>string</dataType></stateVariable>
            </serviceStateTable>
        </scpd>
        """
    }

    // MARK: - Responses

    /// Some TVs open the presentation URL when you select the server; an XML
    /// body there shows up as a connection error, so serve a real page.
    private func presentationPage() -> String {
        let base = "http://\(NetworkUtil.localIPv4Address()):\(port)"
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Dixie Media Server</title>
            <style>
                body { font: 15px -apple-system, system-ui, sans-serif; margin: 3rem auto; max-width: 34rem; color: #1d1d1f; }
                code { background: #f5f5f7; padding: .15rem .35rem; border-radius: 4px; }
            </style>
        </head>
        <body>
            <h1>Dixie Media Server</h1>
            <p>Running and discoverable on this network.</p>
            <ul>
                <li>Device description: <a href="/description.xml"><code>/description.xml</code></a></li>
                <li>Content directory: <a href="/ContentDirectory/ContentDirectory.xml"><code>/ContentDirectory/ContentDirectory.xml</code></a></li>
                <li>Connection manager: <a href="/ConnectionManager/ConnectionManager.xml"><code>/ConnectionManager/ConnectionManager.xml</code></a></li>
            </ul>
            <p>Base URL: <code>\(base)</code></p>
        </body>
        </html>
        """
    }

    private func sendXML(_ xml: String, connection: NWConnection, headOnly: Bool) {
        sendBody(xml, contentType: "text/xml; charset=utf-8", headOnly: headOnly, connection: connection)
    }

    private func sendHTML(_ html: String, connection: NWConnection, headOnly: Bool) {
        sendBody(html, contentType: "text/html; charset=utf-8", headOnly: headOnly, connection: connection)
    }

    private func sendBody(_ text: String, contentType: String, headOnly: Bool, connection: NWConnection) {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(text.utf8.count)\r\n"
        header += "Server: Dixie/1.0 UPnP/1.1\r\n"
        header += "Connection: close\r\n\r\n"
        var out = header.data(using: .utf8) ?? Data()
        if !headOnly { out.append(contentsOf: text.utf8) }
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendRedirect(to target: String, connection: NWConnection) {
        let response = "HTTP/1.1 302 Found\r\n"
            + "Location: \(target)\r\n"
            + "Content-Length: 0\r\n"
            + "Server: Dixie/1.0 UPnP/1.1\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendResponse(data: Data?, contentType: String, connection: NWConnection) {
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(data?.count ?? 0)\r\n"
        response += "Accept-Ranges: bytes\r\n"
        response += "Server: Dixie/1.0\r\n"
        response += "Connection: close\r\n\r\n"
        var responseData = response.data(using: .utf8) ?? Data()
        if let data { responseData.append(data) }
        connection.send(content: responseData, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func send404(connection: NWConnection) {
        let body = "<html><body>Not Found</body></html>"
        let response = "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendStatus(_ code: Int, reason: String, connection: NWConnection) {
        var response = "HTTP/1.1 \(code) \(reason)\r\n"
        response += "DATE: \(NetworkUtil.httpDate())\r\n"
        response += "SERVER: \(Self.serverHeader)\r\n"
        response += "CONTENT-LENGTH: 0\r\n"
        response += "Connection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func send400(connection: NWConnection) {
        sendStatus(400, reason: "Bad Request", connection: connection)
    }

    private func send405(connection: NWConnection, allowed: String) {
        let response = "HTTP/1.1 405 Method Not Allowed\r\nAllow: \(allowed)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func send416(dataLength: Int, connection: NWConnection) {
        let response = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(dataLength)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}