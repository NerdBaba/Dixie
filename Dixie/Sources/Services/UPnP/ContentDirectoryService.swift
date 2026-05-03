import Foundation

final class ContentDirectoryService: @unchecked Sendable {
    private var mediaLibrary: MediaLibrary?
    
    func setMediaLibrary(_ library: MediaLibrary) {
        self.mediaLibrary = library
    }
    
    func browse(objectId: String, startingIndex: Int, requestedCount: Int) async -> String {
        guard let library = mediaLibrary else {
            return errorResponse(code: "801", description: "No media library")
        }
        
        let items = await library.getAllItems()
        return buildSOAPResponse(items: items, objectId: objectId, startingIndex: startingIndex, requestedCount: requestedCount)
    }
    
    func search(objectId: String, searchCriteria: String, startingIndex: Int, requestedCount: Int) async -> String {
        guard let library = mediaLibrary else {
            return errorResponse(code: "801", description: "No media library")
        }
        
        let items = await library.search(query: searchCriteria)
        return buildSOAPResponse(items: items, objectId: objectId, startingIndex: startingIndex, requestedCount: requestedCount)
    }
    
    private func buildSOAPResponse(items: [MediaItem], objectId: String, startingIndex: Int, requestedCount: Int) -> String {
        let totalMatches = items.count
        let actualRequestedCount = requestedCount > 0 ? requestedCount : totalMatches
        let endIndex = min(startingIndex + actualRequestedCount, totalMatches)
        let returnedCount = max(0, endIndex - startingIndex)
        
        var didl = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"
            xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
        
        """
        
        if objectId == "0" || objectId.isEmpty {
            didl += """
            <container id="music" parentID="0" restricted="0">
                <dc:title>Music</dc:title>
                <upnp:class>object.container.storageFolder</upnp:class>
            </container>
            <container id="video" parentID="0" restricted="0">
                <dc:title>Video</dc:title>
                <upnp:class>object.container.storageFolder</upnp:class>
            </container>
            
            """
        } else {
            for i in startingIndex..<endIndex {
                let item = items[i]
                let id = item.id.uuidString
                let parentId = objectId
                let title = escapeXML(item.title)
                let mimeType = item.mimeType
                let itemClass = item.isVideo ? "videoItem" : (item.isAudio ? "audioItem" : "imageItem")
                
                let protocolInfo = "http-get:*:\(mimeType):*"
                let resourceURL = "http://\(getLocalIP()):8080/content/\(id)"
                
                didl += """
                <item id="\(id)" parentID="\(parentId)" restricted="0">
                    <dc:title>\(title)</dc:title>
                    <upnp:class>object.item.\(itemClass)</upnp:class>
                    <res protocolInfo="\(protocolInfo)">\(resourceURL)</res>
                </item>
                
                """
            }
        }
        
        didl += "</DIDL-Lite>"
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
                    <Result>\(didl)</Result>
                    <NumberReturned>\(returnedCount)</NumberReturned>
                    <TotalMatches>\(totalMatches)</TotalMatches>
                    <UpdateID>1</UpdateID>
                </u:BrowseResponse>
            </s:Body>
        </s:Envelope>
        """
    }
    
    private func errorResponse(code: String, description: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <s:Fault>
                    <faultcode>s:Client</faultcode>
                    <faultstring>UPnPError</faultstring>
                    <detail>
                        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
                            <errorCode>\(code)</errorCode>
                            <errorDescription>\(description)</errorDescription>
                        </UPnPError>
                    </detail>
                </s:Fault>
            </s:Body>
        </s:Envelope>
        """
    }
    
    private func escapeXML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
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