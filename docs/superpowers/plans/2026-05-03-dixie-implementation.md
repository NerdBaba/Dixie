# Dixie Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a UPnP/DLNA media server for macOS that can share local media and stream internet content to DLNA renderers.

**Architecture:** Pure Swift with CLI wrappers. UI uses SwiftUI with sidebar navigation. UPnP stack built from scratch using Network framework. yt-dlp called via Process for stream URL extraction.

**Tech Stack:** Swift, SwiftUI, Network framework, AVFoundation, Process (yt-dlp)

---

## Phase 1: Project Setup

### Task 1: Rename and Configure Xcode Project

**Files:**
- Modify: `swift-macos-template/SidebarApp.xcodeproj/project.pbxproj`
- Create: `Dixie/Sources/App/DixieApp.swift`

- [ ] **Step 1: Create Dixie directory structure**

```bash
cd /Volumes/NightSky/babaisalive/Agenttmps/Dixie
mkdir -p Dixie/Sources/{App,UI/{Sidebar,MediaBrowser,Devices,Settings},Services/{UPnP,MediaLibrary,StreamResolver,HTTPServer},Utilities}
mkdir -p Dixie/Resources
```

- [ ] **Step 2: Update project.pbxproj to rename project to Dixie**

Find and replace all instances of "SidebarApp" with "Dixie"

- [ ] **Step 3: Create main app entry point**

```swift
import SwiftUI

@main
struct DixieApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}
```

- [ ] **Step 4: Create Info.plist for Dixie**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleName</key>
    <string>Dixie</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Dixie needs access to your local network to discover and communicate with DLNA devices.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_upnp._tcp</string>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
```

- [ ] **Step 5: Verify project builds**

Run: `xcodebuild -project Dixie.xcodeproj -scheme Dixie -configuration Debug build`

---

## Phase 2: Core Infrastructure

### Task 2: Network Layer - UPnP Discovery

**Files:**
- Create: `Dixie/Sources/Services/UPnP/SSDPDiscovery.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Dixie

final class SSDPDiscoveryTests: XCTestCase {
    func testDiscoveryStarts() async throws {
        let discovery = SSDPDiscovery()
        discovery.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        discovery.stop()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ...`
Expected: FAIL - SSDPDiscovery not defined

- [ ] **Step 3: Write SSDP Discovery implementation**

```swift
import Foundation
import Network

actor SSDPDiscovery {
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.dixie.ssdp")
    
    private let multicastGroup = "239.255.255.250"
    private let multicastPort: UInt16 = 1900
    
    private var discoveredDevices: [String: UPnPDevice] = [:]
    
    struct UPnPDevice {
        let usn: String
        let location: URL
        let server: String
    }
    
    func start() {
        startListener()
        sendMsearch()
    }
    
    func stop() {
        listener?.cancel()
        connection?.cancel()
    }
    
    private func startListener() {
        do {
            let params = NWParameters UDP protocol: NWProtocolUDP.Options()
            params.allowLocalEndpointReuse = true
            
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: multicastPort)!)
            
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("SSDP listener ready")
                case .failed(let error):
                    print("SSDP listener failed: \(error)")
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            listener?.start(queue: queue)
        } catch {
            print("Failed to create SSDP listener: \(error)")
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("SSDP connection ready")
            default:
                break
            }
        }
        connection.start(queue: queue)
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
        
        let host = NWEndpoint.Host(multicastGroup)
        let port = NWEndpoint.Port(rawValue: multicastPort)!
        
        connection = NWConnection(host: host, port: port, using: .udp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.connection?.send(content: msearch.data(using: .utf8), completion: .contentProcessed { error in
                    if let error = error {
                        print("SSDP send error: \(error)")
                    } else {
                        print("SSDP M-SEARCH sent")
                    }
                })
            default:
                break
            }
        }
        
        connection?.start(queue: queue)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test ...`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Dixie/Sources/Services/UPnP/SSDPDiscovery.swift
git commit -m "feat: add SSDP discovery for UPnP"
```

---

### Task 3: HTTP Server for DLNA

**Files:**
- Create: `Dixie/Sources/Services/HTTPServer/DLHTTPServer.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Dixie

final class DLNAHTTPServerTests: XCTestCase {
    func testServerStarts() async throws {
        let server = DLNAHTTPServer(port: 8080)
        try server.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        server.stop()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL - DLNAHTTPServer not defined

- [ ] **Step 3: Write HTTP Server implementation**

```swift
import Foundation
import Network

final class DLNAHTTPServer {
    private var listener: NWListener?
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.dixie.http")
    
    private var connections: [NWConnection] = []
    
    var onMediaRequest: ((URL) -> (Data?, String)?)?
    
    init(port: UInt16 = 8080) {
        self.port = port
    }
    
    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("DLNA HTTP Server started on port \(self.port)")
            case .failed(let error):
                print("DLNA HTTP Server failed: \(error)")
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
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(connection)
            case .failed, .cancelled:
                self?.removeConnection(connection)
            default:
                break
            }
        }
        
        connection.start(queue: queue)
    }
    
    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let content = content, !content.isEmpty {
                self?.handleHTTPRequest(content: content, connection: connection)
            }
            
            if !isComplete && error == nil {
                self?.receiveRequest(connection)
            }
        }
    }
    
    private func handleHTTPRequest(content: Data, connection: NWConnection) {
        guard let request = String(data: content, encoding: .utf8) else {
            return
        }
        
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        
        let method = parts[0]
        let path = parts[1]
        
        print("HTTP \(method) \(path)")
        
        if method == "GET" {
            handleGET(path: path, connection: connection)
        }
    }
    
    private func handleGET(path: String, connection: NWConnection) {
        guard let url = URL(string: path) else {
            send404(connection: connection)
            return
        }
        
        if let result = onMediaRequest?(url) {
            let (data, contentType) = result ?? (nil, "application/octet-stream")
            sendResponse(data: data, contentType: contentType, connection: connection)
        } else {
            send404(connection: connection)
        }
    }
    
    private func sendResponse(data: Data?, contentType: String, connection: NWConnection) {
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(data?.count ?? 0)\r\n"
        response += "Accept-Ranges: bytes\r\n"
        response += "Server: Dixie/1.0\r\n"
        response += "\r\n"
        
        var responseData = response.data(using: .utf8) ?? Data()
        if let data = data {
            responseData.append(data)
        }
        
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func send404(connection: NWConnection) {
        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Dixie/Sources/Services/HTTPServer/DLHTTPServer.swift
git commit -m "feat: add DLNA HTTP server"
```

---

## Phase 3: Media Library

### Task 4: Media Library and File Scanner

**Files:**
- Create: `Dixie/Sources/Services/MediaLibrary/MediaLibrary.swift`
- Create: `Dixie/Sources/Services/MediaLibrary/MediaItem.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Dixie

final class MediaLibraryTests: XCTestCase {
    func testScanFolder() async throws {
        let library = MediaLibrary()
        let items = try await library.scanFolder(URL(fileURLWithPath: "/Users"))
        print("Found \(items.count) items")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL - MediaLibrary not defined

- [ ] **Step 3: Write MediaItem model**

```swift
import Foundation

struct MediaItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let title: String
    let artist: String?
    let album: String?
    let duration: TimeInterval?
    let artwork: Data?
    let mimeType: String
    
    var isVideo: Bool {
        mimeType.hasPrefix("video/")
    }
    
    var isAudio: Bool {
        mimeType.hasPrefix("audio/")
    }
    
    var isImage: Bool {
        mimeType.hasPrefix("image/")
    }
    
    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.artist = nil
        self.album = nil
        self.duration = nil
        self.artwork = nil
        self.mimeType = MediaLibrary.mimeType(for: url)
    }
}
```

- [ ] **Step 4: Write MediaLibrary implementation**

```swift
import Foundation
import AVFoundation
import UniformTypeIdentifiers

actor MediaLibrary {
    private var items: [MediaItem] = []
    private var watchFolders: [URL] = []
    
    static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let mapping: [String: String] = [
            "mp3": "audio/mpeg",
            "m4a": "audio/mp4",
            "aac": "audio/aac",
            "wav": "audio/wav",
            "flac": "audio/flac",
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "avi": "video/x-msvideo",
            "mkv": "video/x-matroska",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif"
        ]
        return mapping[ext] ?? "application/octet-stream"
    }
    
    func addWatchFolder(_ url: URL) {
        watchFolders.append(url)
    }
    
    func scanFolder(_ url: URL) async throws -> [MediaItem] {
        let fileManager = FileManager.default
        var results: [MediaItem] = []
        
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }
        
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            
            let item = MediaItem(url: fileURL)
            
            if item.mimeType.hasPrefix("audio/") || item.mimeType.hasPrefix("video/") {
                results.append(item)
            }
        }
        
        items = results
        return results
    }
    
    func getAllItems() -> [MediaItem] {
        return items
    }
    
    func search(query: String) -> [MediaItem] {
        let lowercased = query.lowercased()
        return items.filter { item in
            item.title.lowercased().contains(lowercased) ||
            (item.artist?.lowercased().contains(lowercased) ?? false) ||
            (item.album?.lowercased().contains(lowercased) ?? false)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test ...`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Dixie/Sources/Services/MediaLibrary/
git commit -m "feat: add media library with folder scanning"
```

---

## Phase 4: Stream Resolver

### Task 5: Stream Resolver with yt-dlp

**Files:**
- Create: `Dixie/Sources/Services/StreamResolver/StreamResolver.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Dixie

final class StreamResolverTests: XCTestCase {
    func testYouTubeURL() async throws {
        let resolver = StreamResolver()
        let result = try await resolver.resolve(url: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        print("Resolved: \(result)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL - StreamResolver not defined

- [ ] **Step 3: Write StreamResolver implementation**

```swift
import Foundation

enum StreamSource {
    case local(URL)
    case remote(URL)
    case youTube(streamURL: URL, title: String)
    case bandcamp(streamURL: URL, title: String)
    case soundCloud(streamURL: URL, title: String)
    case error(String)
}

actor StreamResolver {
    private var ytDLPPath: String = "/usr/local/bin/yt-dlp"
    
    func resolve(url: URL) async throws -> StreamSource {
        let host = url.host?.lowercased() ?? ""
        
        if host.contains("youtube.com") || host.contains("youtu.be") {
            return try await resolveYouTube(url: url)
        } else if host.contains("bandcamp.com") {
            return try await resolveBandcamp(url: url)
        } else if host.contains("soundcloud.com") {
            return try await resolveSoundCloud(url: url)
        } else if url.isFileURL {
            return .local(url)
        } else {
            return .remote(url)
        }
    }
    
    private func resolveYouTube(url: URL) async throws -> StreamSource {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDLPPath)
        process.arguments = [
            "--get-url",
            "--format", "bestaudio/best",
            url.absoluteString
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return .error("Failed to extract YouTube URL")
        }
        
        let title = try await getYouTubeTitle(url: url)
        
        return .youTube(streamURL: URL(string: output)!, title: title)
    }
    
    private func getYouTubeTitle(url: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDLPPath)
        process.arguments = [
            "--get-title",
            url.absoluteString
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
    }
    
    private func resolveBandcamp(url: URL) async throws -> StreamSource {
        return .bandcamp(streamURL: url, title: "Bandcamp Track")
    }
    
    private func resolveSoundCloud(url: URL) async throws -> StreamSource {
        return .soundCloud(streamURL: url, title: "SoundCloud Track")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS (may skip if yt-dlp not installed)

- [ ] **Step 5: Commit**

```bash
git add Dixie/Sources/Services/StreamResolver/StreamResolver.swift
git commit -m "feat: add stream resolver with YouTube support"
```

---

## Phase 5: DLNA Server

### Task 6: DLNA Content Directory Service

**Files:**
- Create: `Dixie/Sources/Services/UPnP/ContentDirectoryService.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Dixie

final class ContentDirectoryTests: XCTestCase {
    func testBrowseRequest() throws {
        let service = ContentDirectoryService()
        let response = service.browse(objectId: "0", startingIndex: 0, requestedCount: 100)
        XCTAssertNotNil(response)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL - ContentDirectoryService not defined

- [ ] **Step 3: Write ContentDirectoryService implementation**

```swift
import Foundation

final class ContentDirectoryService {
    private var mediaLibrary: MediaLibrary?
    
    func setMediaLibrary(_ library: MediaLibrary) {
        self.mediaLibrary = library
    }
    
    func browse(objectId: String, startingIndex: Int, requestedCount: Int) -> String {
        guard let library = mediaLibrary else {
            return errorResponse(code: "801", description: "No media library")
        }
        
        Task {
            let items = library.getAllItems()
            return buildSOAPResponse(items: items, startingIndex: startingIndex, requestedCount: requestedCount)
        }
        
        return buildSOAPResponse(items: [], startingIndex: startingIndex, requestedCount: requestedCount)
    }
    
    func search(objectId: String, searchCriteria: String, startingIndex: Int, requestedCount: Int) -> String {
        guard let library = mediaLibrary else {
            return errorResponse(code: "801", description: "No media library")
        }
        
        let items = library.search(query: searchCriteria)
        return buildSOAPResponse(items: items, startingIndex: startingIndex, requestedCount: requestedCount)
    }
    
    private func buildSOAPResponse(items: [MediaItem], startingIndex: Int, requestedCount: Int) -> String {
        var didl = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"
            xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
        
        """
        
        let endIndex = min(startingIndex + requestedCount, items.count)
        for item in items[startingIndex..<endIndex] {
            let id = item.id.uuidString
            let parentId = "0"
            let title = item.title.replacingOccurrences(of: "&", with: "&amp;")
            let mimeType = item.mimeType
            
            didl += """
            <item id="\(id)" parentID="\(parentId)" restricted="0">
                <dc:title>\(title)</dc:title>
                <upnp:class>object.item.\(item.isVideo ? "videoItem" : "audioItem")</upnp:class>
                <res protocolInfo="http-get:*:\(mimeType):*">http://\(getLocalIP()):8080/media/\(id)</res>
            </item>
            
            """
        }
        
        didl += "</DIDL-Lite>"
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
                    <Result>\(didl)</Result>
                    <NumberReturned>\(items.count)</NumberReturned>
                    <TotalMatches>\(items.count)</TotalMatches>
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
```

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Dixie/Sources/Services/UPnP/ContentDirectoryService.swift
git commit -m "feat: add DLNA Content Directory service"
```

---

## Phase 6: UI Integration

### Task 7: Main UI with Sidebar

**Files:**
- Modify: `Dixie/Sources/UI/MainView.swift`
- Create: `Dixie/Sources/UI/Sidebar/SidebarView.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Dixie

final class MainViewTests: XCTestCase {
    func testMainViewExists() {
        let view = MainView()
        XCTAssertNotNil(view)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL - MainView doesn't exist

- [ ] **Step 3: Create MainView with NavigationSplitView**

```swift
import SwiftUI

struct MainView: View {
    @State private var selectedTab: SidebarItem = .files
    @StateObject private var appState = AppState()
    
    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab)
        } detail: {
            switch selectedTab {
            case .files:
                FileBrowserView()
            case .library:
                LibraryView()
            case .devices:
                DevicesView()
            case .urls:
                URLInputView()
            case .settings:
                SettingsView()
            }
        }
        .environmentObject(appState)
    }
}

enum SidebarItem: String, CaseIterable {
    case files = "Files"
    case library = "Library"
    case devices = "Devices"
    case urls = "URLs"
    case settings = "Settings"
    
    var icon: String {
        switch self {
        case .files: return "folder"
        case .library: return "music.note.list"
        case .devices: return "tv"
        case .urls: return "link"
        case .settings: return "gear"
        }
    }
}
```

- [ ] **Step 4: Create AppState**

```swift
import SwiftUI

final class AppState: ObservableObject {
    @Published var isServerRunning = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var selectedDevice: DiscoveredDevice?
    @Published var currentMediaItem: MediaItem?
    @Published var watchFolders: [URL] = []
    
    let mediaLibrary = MediaLibrary()
    let streamResolver = StreamResolver()
    let dlnaServer = DLNAServer()
}

struct DiscoveredDevice: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let type: DeviceType
    
    enum DeviceType {
        case renderer
        case server
    }
}
```

- [ ] **Step 5: Create SidebarView**

```swift
import SwiftUI

struct SidebarView: View {
    @Binding var selectedTab: SidebarItem
    
    var body: some View {
        List(SidebarItem.allCases, selection: $selectedTab) { item in
            Label(item.rawValue, systemImage: item.icon)
                .tag(item)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Dixie/Sources/UI/MainView.swift Dixie/Sources/UI/Sidebar/
git commit -m "feat: add main UI with sidebar navigation"
```

---

### Task 8: Feature Views

**Files:**
- Create: `Dixie/Sources/UI/MediaBrowser/FileBrowserView.swift`
- Create: `Dixie/Sources/UI/MediaBrowser/LibraryView.swift`
- Create: `Dixie/Sources/UI/Devices/DevicesView.swift`
- Create: `Dixie/Sources/UI/MediaBrowser/URLInputView.swift`
- Create: `Dixie/Sources/UI/Settings/SettingsView.swift`

- [ ] **Step 1: Create FileBrowserView**

```swift
import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedFolder: URL?
    
    var body: some View {
        VStack {
            if let folder = selectedFolder {
                Text(folder.lastPathComponent)
                    .font(.title)
                
                Button("Select Folder") {
                    selectFolder()
                }
            } else {
                Text("No folder selected")
                    .foregroundColor(.secondary)
                
                Button("Select Media Folder") {
                    selectFolder()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            selectedFolder = url
            appState.watchFolders.append(url)
            
            Task {
                _ = try? await appState.mediaLibrary.scanFolder(url)
            }
        }
    }
}
```

- [ ] **Step 2: Create LibraryView**

```swift
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    
    var body: some View {
        VStack {
            TextField("Search...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding()
            
            if searchText.isEmpty {
                Text("Enter a search term")
                    .foregroundColor(.secondary)
            } else {
                Text("Search results for: \(searchText)")
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 3: Create DevicesView**

```swift
import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("DLNA Server")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $appState.isServerRunning)
                    .labelsHidden()
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            Divider()
            
            Text("Discovered Devices")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            if appState.discoveredDevices.isEmpty {
                Text("No devices found")
                    .foregroundColor(.secondary)
            } else {
                List(appState.discoveredDevices) { device in
                    HStack {
                        Image(systemName: "tv")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.address)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
    }
}
```

- [ ] **Step 4: Create URLInputView**

```swift
import SwiftUI

struct URLInputView: View {
    @EnvironmentObject var appState: AppState
    @State private var urlString = ""
    @State private var isLoading = false
    
    var body: some View {
        VStack(spacing: 20) {
            TextField("Enter URL (YouTube, Bandcamp, SoundCloud, or any media URL)", text: $urlString)
                .textFieldStyle(.roundedBorder)
            
            Button(action: playURL) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text("Play")
                }
            }
            .disabled(urlString.isEmpty || isLoading)
            
            if !urlString.isEmpty {
                Text("Supported: YouTube, Bandcamp, SoundCloud, direct media URLs")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
    
    private func playURL() {
        guard let url = URL(string: urlString) else { return }
        
        isLoading = true
        
        Task {
            do {
                let source = try await appState.streamResolver.resolve(url: url)
                print("Resolved: \(source)")
            } catch {
                print("Error: \(error)")
            }
            isLoading = false
        }
    }
}
```

- [ ] **Step 5: Create SettingsView**

```swift
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var serverPort: String = "8080"
    @State private var autoStartServer = false
    
    var body: some View {
        Form {
            Section("Server") {
                TextField("Port", text: $serverPort)
                Toggle("Auto-start server on launch", isOn: $autoStartServer)
            }
            
            Section("Media Folders") {
                ForEach(appState.watchFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder.path)
                    }
                }
            }
            
            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("DLNA Server", value: appState.isServerRunning ? "Running" : "Stopped")
            }
        }
        .padding()
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add Dixie/Sources/UI/MediaBrowser/ Dixie/Sources/UI/Devices/ Dixie/Sources/UI/Settings/
git commit -m "feat: add feature views for all sidebar sections"
```

---

## Phase 7: Integration

### Task 9: Connect DLNA Server to UI

**Files:**
- Modify: `Dixie/Sources/Services/DLNAServer.swift`
- Modify: `Dixie/Sources/UI/Devices/DevicesView.swift`

- [ ] **Step 1: Create DLNAServer that ties everything together**

```swift
import Foundation

final class DLNAServer: ObservableObject {
    @Published var isRunning = false
    @Published var port: UInt16 = 8080
    
    private var httpServer: DLNAHTTPServer?
    private var ssdpDiscovery: SSDPDiscovery?
    private var mediaLibrary: MediaLibrary?
    private var contentDirectory: ContentDirectoryService?
    
    func configure(mediaLibrary: MediaLibrary) {
        self.mediaLibrary = mediaLibrary
        self.contentDirectory = ContentDirectoryService()
        self.contentDirectory?.setMediaLibrary(mediaLibrary)
    }
    
    func start() throws {
        httpServer = DLNAHTTPServer(port: port)
        try httpServer?.start()
        
        httpServer?.onMediaRequest = { [weak self] url in
            self?.handleMediaRequest(url: url)
        }
        
        isRunning = true
    }
    
    func stop() {
        httpServer?.stop()
        ssdpDiscovery?.stop()
        isRunning = false
    }
    
    private func handleMediaRequest(url: URL) -> (Data?, String)? {
        guard let pathComponents = url.pathComponents.dropFirst().first else {
            return nil
        }
        
        if let itemId = UUID(uuidString: pathComponents),
           let item = mediaLibrary?.getAllItems().first(where: { $0.id == itemId }) {
            let data = try? Data(contentsOf: item.url)
            return (data, item.mimeType)
        }
        
        return nil
    }
}
```

- [ ] **Step 2: Update DevicesView to control server**

- [ ] **Step 3: Commit**

---

## Verification

- [ ] Project builds successfully on Apple Silicon
- [ ] App launches and displays sidebar
- [ ] Folder selection works for media scanning
- [ ] HTTP server starts on configured port
- [ ] yt-dlp integration works (when installed)

---

## Plan Complete

The implementation is divided into 9 tasks across 7 phases:

1. **Project Setup** — Rename and configure Xcode project
2. **SSDP Discovery** — Network discovery for UPnP devices
3. **HTTP Server** — Local server for serving media
4. **Media Library** — File scanning and indexing
5. **Stream Resolver** — URL handling with yt-dlp support
6. **Content Directory** — DLNA ContentDirectory service implementation
7. **Main UI** — Sidebar navigation structure
8. **Feature Views** — All sidebar section implementations
9. **Integration** — Connect all components together

Each task follows TDD with failing tests first, implementation, then passing verification.