import Foundation
import AVFoundation

actor MediaLibrary {
    private var items: [MediaItem] = []
    private var watchFolders: [URL] = []
    
    static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let mapping: [String: String] = [
            "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac",
            "wav": "audio/wav", "flac": "audio/flac",
            "mp4": "video/mp4", "mov": "video/quicktime", "avi": "video/x-msvideo",
            "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png"
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
            
            let item = MediaItem(url: fileURL)
            if item.mimeType.hasPrefix("audio/") || item.mimeType.hasPrefix("video/") {
                results.append(item)
            }
        }
        items = results
        return results
    }
    
    func getAllItems() -> [MediaItem] { items }
    
    func search(query: String) -> [MediaItem] {
        let lowercased = query.lowercased()
        return items.filter { $0.title.lowercased().contains(lowercased) }
    }
}