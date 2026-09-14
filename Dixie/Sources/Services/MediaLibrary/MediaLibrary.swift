import Foundation
import AVFoundation

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
            "ogg": "audio/ogg",
            "opus": "audio/opus",
            "webm": "audio/webm",
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "avi": "video/x-msvideo",
            "mkv": "video/x-matroska",
            "wmv": "video/x-ms-wmv",
            "flv": "video/x-flv",
            "3gp": "video/3gpp",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "webp": "image/webp",
            "bmp": "image/bmp"
        ]
        return mapping[ext] ?? "application/octet-stream"
    }
    
    func addWatchFolder(_ url: URL) {
        watchFolders.append(url)
    }
    
    func scanFolder(_ url: URL) async throws -> [MediaItem] {
        let fileManager = FileManager.default
        var results: [MediaItem] = []
        
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return results }
        
        var urls: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            urls.append(fileURL)
        }
        
        for fileURL in urls {
            let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys)
            guard resourceValues?.isRegularFile == true else { continue }
            
            let ext = fileURL.pathExtension.lowercased()
            let item = MediaItem(url: fileURL)
            print("[MediaLibrary] File: \(fileURL.lastPathComponent) ext=\(ext) mime=\(item.mimeType)")
            if item.mimeType.hasPrefix("audio/") || item.mimeType.hasPrefix("video/") {
                print("[MediaLibrary] Adding: \(fileURL.lastPathComponent)")
                results.append(item)
            } else {
                print("[MediaLibrary] Skipping: \(fileURL.lastPathComponent) type=\(item.mimeType)")
            }
        }
        items = results
        return results
    }
    
    func getAllItems() -> [MediaItem] { items }

    func item(id: UUID) -> MediaItem? {
        items.first { $0.id == id }
    }
    
    func search(query: String) -> [MediaItem] {
        let lowercased = query.lowercased()
        return items.filter { $0.title.lowercased().contains(lowercased) }
    }
    
    func addItem(_ item: MediaItem) {
        if !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
    }
    
    func removeItem(_ item: MediaItem) {
        items.removeAll { $0.id == item.id }
    }
}