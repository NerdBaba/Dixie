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
    private var ytDLPPath: String? = nil
    
    init() {
        let paths = ["/usr/local/bin/yt-dlp", "/opt/homebrew/bin/yt-dlp", "/usr/bin/yt-dlp"]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                ytDLPPath = path
                break
            }
        }
    }
    
    var isYTDLPInstalled: Bool {
        ytDLPPath != nil
    }
    
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
        guard let ytPath = ytDLPPath else {
            return .error("yt-dlp not installed. Install with: brew install yt-dlp")
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytPath)
        process.arguments = ["--get-url", "--format", "bestaudio/best", url.absoluteString]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty, URL(string: output) != nil else {
            return .error("Failed to extract YouTube URL")
        }
        
        return .youTube(streamURL: URL(string: output)!, title: url.lastPathComponent)
    }
    
    private func resolveBandcamp(url: URL) async throws -> StreamSource {
        return .error("Bandcamp: API not implemented yet")
    }
    
    private func resolveSoundCloud(url: URL) async throws -> StreamSource {
        return .error("SoundCloud: API not implemented yet")
    }
}