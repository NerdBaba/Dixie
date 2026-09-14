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

    /// Best-effort human-readable file name for a link, e.g. the name the
    /// origin serves in `Content-Disposition` or the last path component of
    /// the URL it redirects to. Never downloads the body.
    func resolveFileName(for url: URL) async -> String {
        if url.isFileURL {
            return RemoteFileNameProbe.strippingExtension(url.lastPathComponent)
        }

        // A HEAD is enough for well-behaved origins, but plenty of CDNs reject
        // it with 403/405, so fall back to a 1-byte ranged GET.
        if let name = await RemoteFileNameProbe.probe(url, method: "HEAD") {
            return RemoteFileNameProbe.strippingExtension(name)
        }
        if let name = await RemoteFileNameProbe.probe(url, method: "GET") {
            return RemoteFileNameProbe.strippingExtension(name)
        }
        return RemoteFileNameProbe.strippingExtension(RemoteFileNameProbe.fallbackName(for: url))
    }
}

/// Fetches response headers for a URL and pulls a filename out of them.
///
/// The request is cancelled the moment headers arrive, so a 3 GB video costs
/// nothing. Any failure is a `nil` return, never a throw — the caller always
/// has the URL text to fall back on.
private final class RemoteFileNameProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse?, Never>?
    private var session: URLSession?

    static func probe(_ url: URL, method: String, timeout: TimeInterval = 6) async -> String? {
        let response = await RemoteFileNameProbe().send(url, method: method, timeout: timeout)
        guard let response else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            return nil
        }
        return fileName(from: response)
    }

    private func send(_ url: URL, method: String, timeout: TimeInterval) async -> URLResponse? {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpAdditionalHeaders = ["User-Agent": "Dixie/1.0 UPnP/1.1", "Accept": "*/*"]
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            lock.lock()
            self.session = session
            lock.unlock()

            var request = URLRequest(url: url)
            request.httpMethod = method
            if method == "GET" {
                request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            }
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        finish(with: response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(with: task.response)
    }

    private func finish(with response: URLResponse?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        guard let continuation else { return }
        session?.invalidateAndCancel()
        continuation.resume(returning: response)
    }

    // MARK: - Name extraction

    static func fileName(from response: URLResponse) -> String? {
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           let name = filename(fromDisposition: disposition) {
            return name
        }
        // Redirects are followed, so `response.url` is where the bytes really live.
        if let finalURL = response.url {
            let name = decoded(finalURL.lastPathComponent)
            if !name.isEmpty { return name }
        }
        return nil
    }

    static func filename(fromDisposition value: String) -> String? {
        var extended: String?
        var plain: String?
        for part in value.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("filename*=") {
                extended = String(trimmed.dropFirst("filename*=".count))
            } else if lower.hasPrefix("filename=") {
                plain = String(trimmed.dropFirst("filename=".count))
            }
        }

        // RFC 5987 form: filename*=UTF-8''percent%20encoded
        if let extended {
            let pieces = extended.components(separatedBy: "'")
            let encoded = pieces.count >= 3 ? pieces[2] : extended
            let name = basename(decoded(encoded))
            if !name.isEmpty { return name }
        }
        if var plain {
            plain = plain.trimmingCharacters(in: .whitespaces)
            if plain.count >= 2, plain.hasPrefix("\""), plain.hasSuffix("\"") {
                plain = String(plain.dropFirst().dropLast())
            }
            let name = basename(decoded(plain))
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// Links pasted out of chat clients are frequently not real URLs: the
    /// filename lands in the host position with no path at all, so
    /// `lastPathComponent` comes back empty. Check the host before giving up.
    static func fallbackName(for url: URL) -> String {
        let path = decoded(url.lastPathComponent)
        if !path.isEmpty, path != "/" { return path }
        let host = decoded(url.host ?? "")
        if !host.isEmpty { return host }
        return decoded(url.absoluteString)
    }

    /// Servers sometimes send a full path; keep only the file part.
    private static func basename(_ name: String) -> String {
        let cleaned = (name as NSString).lastPathComponent
        return cleaned == "." || cleaned == ".." ? "" : cleaned
    }

    /// Slugs are often encoded more than once (`%2520` -> `%20` -> space).
    static func decoded(_ value: String) -> String {
        var current = value
        for _ in 0..<3 {
            guard let next = current.removingPercentEncoding, next != current else { break }
            current = next
        }
        return current
    }

    static func strippingExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return name
        }
        let stripped = (name as NSString).deletingPathExtension
        return stripped.isEmpty ? name : stripped
    }
}