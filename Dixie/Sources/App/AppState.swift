import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var isServerRunning = false
    @Published var selectedDevice: DiscoveredDevice?
    @Published var currentMediaItem: MediaItem?
    @Published var watchFolders: [URL] = []
    @Published var recentItems: [RecentItem] = []
    
    let mediaLibrary = MediaLibrary()
    let streamResolver = StreamResolver()
    let dlnaServer = DLNAServer()
    
    init() {
        dlnaServer.configure(mediaLibrary: mediaLibrary)
    }
    
    func addRecentItem(title: String, type: String, url: URL? = nil, mediaTitle: String? = nil) {
        let item = RecentItem(title: title, type: type, timestamp: Date())
        recentItems.insert(item, at: 0)
        if recentItems.count > 20 {
            recentItems = Array(recentItems.prefix(20))
        }
        
        if let url = url {
            let mediaItem = MediaItem(url: url, title: mediaTitle)
            Task {
                await mediaLibrary.addItem(mediaItem)
                print("[AppState] Added item to library: \(mediaItem.title)")
                let allItems = await mediaLibrary.getAllItems()
                print("[AppState] Library now has \(allItems.count) items")
            }
        }
    }
}

struct RecentItem: Identifiable {
    let id = UUID()
    let title: String
    let type: String
    let timestamp: Date
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

struct MediaItem: Identifiable, Hashable, Sendable {
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
    
    init(url: URL, title: String? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.artist = nil
        self.album = nil
        self.duration = nil
        self.artwork = nil
        self.mimeType = MediaLibrary.mimeType(for: url)
    }
}