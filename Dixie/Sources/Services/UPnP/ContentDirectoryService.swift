import Foundation

final class ContentDirectoryService: @unchecked Sendable {
    private var mediaLibrary: MediaLibrary?
    private var port: UInt16 = 8080

    func setMediaLibrary(_ library: MediaLibrary) {
        self.mediaLibrary = library
    }

    func setPort(_ port: UInt16) {
        self.port = port
    }

    /// `objectId` may arrive as "id|BrowseFlag" from the HTTP layer.
    func browse(objectId: String, startingIndex: Int, requestedCount: Int) async -> String {
        guard let library = mediaLibrary else {
            return Self.soapFault(code: "801", description: "No media library")
        }
        let parts = objectId.components(separatedBy: "|")
        let containerId = parts.first ?? "0"
        let browseFlag = parts.count > 1 ? parts[1] : "BrowseDirectChildren"

        let items = await library.getAllItems()
        print("[ContentDirectory] Browse id=\(containerId) flag=\(browseFlag) items=\(items.count)")
        if browseFlag == "BrowseMetadata" {
            return metadataResponse(containerId: containerId, itemCount: items.count)
        }
        if containerId == "0" || containerId.isEmpty {
            let counts = Self.countByKind(items)
            let inner = containerXML(id: "music", parentID: "0", title: "Music", childCount: counts.audio)
                + containerXML(id: "video", parentID: "0", title: "Video", childCount: counts.video)
                + containerXML(id: "image", parentID: "0", title: "Pictures", childCount: counts.image)
            return browseEnvelope(result: Self.wrapDIDL(inner), numberReturned: 3, totalMatches: 3)
        }
        let page = Self.page(items: children(of: containerId, in: items),
                             startingIndex: startingIndex, requestedCount: requestedCount)
        return browseEnvelope(result: Self.wrapDIDL(page.items.map { itemXML($0, parentId: containerId, baseURL: httpBase()) }.joined()),
                              numberReturned: page.count, totalMatches: page.total)
    }

    func search(objectId: String, searchCriteria: String, startingIndex: Int, requestedCount: Int) async -> String {
        guard let library = mediaLibrary else {
            return Self.soapFault(code: "801", description: "No media library")
        }
        // Search always walks the whole library; results are items, never containers.
        let matched = Self.apply(criteria: searchCriteria, to: await library.getAllItems())
        let page = Self.page(items: matched, startingIndex: startingIndex, requestedCount: requestedCount)
        let baseURL = httpBase()
        return browseEnvelope(result: Self.wrapDIDL(page.items.map { itemXML($0, parentId: objectId, baseURL: baseURL) }.joined()),
                              numberReturned: page.count, totalMatches: page.total)
    }

    /// The visible children of a container: the three top-level folders at the
    /// root, otherwise the media items of the matching kind.
    private func children(of containerId: String, in items: [MediaItem]) -> [MediaItem] {
        switch containerId {
        case "0", "": return []
        case "music": return items.filter { $0.isAudio }
        case "video": return items.filter { $0.isVideo }
        case "image": return items.filter { $0.isImage }
        default: return items
        }
    }

    private static func wrapDIDL(_ inner: String) -> String {
        "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">\(inner)</DIDL-Lite>"
    }

    private struct Page {
        let items: [MediaItem]
        let count: Int
        let total: Int
    }

    private static func page(items: [MediaItem], startingIndex: Int, requestedCount: Int) -> Page {
        let total = items.count
        let count = requestedCount > 0 ? requestedCount : total
        let end = min(max(0, startingIndex) + count, total)
        let start = min(max(0, startingIndex), end)
        return Page(items: Array(items[start..<end]), count: end - start, total: total)
    }

    /// Minimal UPnP SearchCriteria support: class filters, title wildcards,
    /// and bare free text. Anything unrecognised matches everything.
    static func apply(criteria raw: String, to items: [MediaItem]) -> [MediaItem] {
        let criteria = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !criteria.isEmpty, criteria != "*" else { return items }

        var result = items
        let lower = criteria.lowercased()
        if lower.contains("object.item.audioitem") {
            result = result.filter { $0.isAudio }
        } else if lower.contains("object.item.videoitem") {
            result = result.filter { $0.isVideo }
        } else if lower.contains("object.item.imageitem") {
            result = result.filter { $0.isImage }
        }

        if let quoted = firstQuotedString(in: criteria) {
            let needle = quoted.lowercased()
            if lower.contains("dc:title") {
                result = result.filter { $0.title.lowercased().contains(needle) }
            } else if lower.contains("upnp:artist") || lower.contains("dc:creator") {
                result = result.filter { ($0.artist ?? "").lowercased().contains(needle) }
            } else if lower.contains("upnp:album") {
                result = result.filter { ($0.album ?? "").lowercased().contains(needle) }
            } else if !lower.contains("upnp:class") {
                result = result.filter { $0.title.lowercased().contains(needle) }
            }
        }
        return result
    }

    private static func firstQuotedString(in text: String) -> String? {
        guard let open = text.firstIndex(of: "\"") else { return nil }
        let rest = text[text.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }

    private func metadataResponse(containerId: String, itemCount: Int) -> String {
        let meta: String
        switch containerId {
        case "0", "":
            meta = containerXML(id: "0", parentID: "-1", title: "Root", childCount: 3)
        case "music":
            meta = containerXML(id: "music", parentID: "0", title: "Music", childCount: itemCount)
        case "image":
            meta = containerXML(id: "image", parentID: "0", title: "Pictures", childCount: itemCount)
        default:
            meta = containerXML(id: "video", parentID: "0", title: "Video", childCount: itemCount)
        }
        return browseEnvelope(result: Self.wrapDIDL(meta), numberReturned: 1, totalMatches: 1)
    }

    private func browseEnvelope(result: String, numberReturned: Int, totalMatches: Int) -> String {
        "<Result>\(result.xmlEscaped())</Result><NumberReturned>\(numberReturned)</NumberReturned><TotalMatches>\(totalMatches)</TotalMatches><UpdateID>1</UpdateID>"
    }

    private func containerXML(id: String, parentID: String, title: String, childCount: Int) -> String {
        "<container id=\"\(id)\" parentID=\"\(parentID)\" restricted=\"1\" childCount=\"\(childCount)\"><dc:title>\(title.xmlEscaped())</dc:title><upnp:class>object.container.storageFolder</upnp:class></container>"
    }

    private func itemXML(_ item: MediaItem, parentId: String, baseURL: String) -> String {
        let id = item.id.uuidString
        let title = item.title.xmlEscaped()
        let mimeType = item.mimeType
        let itemClass: String
        if item.isVideo { itemClass = "object.item.videoItem.movie" }
        else if item.isAudio { itemClass = "object.item.audioItem.musicTrack" }
        else if item.isImage { itemClass = "object.item.imageItem.photo" }
        else { itemClass = "object.item" }
        let flags = item.isAudio || item.isVideo
            ? "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=017000000000000000000000000000"
            : "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=00D000000000000000000000000000"
        let protocolInfo = "http-get:*:\(mimeType):\(flags)"

        // Internet items are advertised by their origin URL: the server does not
        // proxy them, and pointing the TV back at /content/<id> would 404.
        let resourceURL = item.url.isFileURL
            ? "\(baseURL)/content/\(id)"
            : item.url.absoluteString.xmlEscaped()

        let size: String
        if item.url.isFileURL {
            let vals = try? item.url.resourceValues(forKeys: [.fileSizeKey])
            size = vals?.fileSize.map { "\($0)" } ?? ""
        } else {
            size = ""
        }

        return "<item id=\"\(id)\" parentID=\"\(parentId.xmlEscaped())\" restricted=\"1\"><dc:title>\(title)</dc:title><upnp:class>\(itemClass)</upnp:class><desc id=\"cdudn\" nameSpace=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">SA_RINCON10_DMS_12345678_X_JS_SERVCER</desc><res protocolInfo=\"\(protocolInfo)\" size=\"\(size)\">\(resourceURL)</res></item>"
    }

    private static func countByKind(_ items: [MediaItem]) -> (audio: Int, video: Int, image: Int) {
        var audio = 0, video = 0, image = 0
        for item in items {
            if item.isAudio { audio += 1 }
            else if item.isVideo { video += 1 }
            else if item.isImage { image += 1 }
        }
        return (audio, video, image)
    }

    private func httpBase() -> String {
        "http://\(NetworkUtil.localIPv4Address()):\(port)"
    }

    static func soapFault(code: String, description: String) -> String {
        "<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>\(code)</errorCode><errorDescription>\(description.xmlEscaped())</errorDescription></UPnPError></detail>"
    }
}

extension String {
    /// Escapes text for use inside XML element content or attribute values.
    func xmlEscaped() -> String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
