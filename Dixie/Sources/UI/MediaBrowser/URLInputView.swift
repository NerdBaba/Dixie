import SwiftUI

struct URLInputView: View {
    @EnvironmentObject var appState: AppState
    @State private var urlText: String = ""
    @State private var isLoading = false
    @State private var statusMessage = ""
    @State private var refreshKey = UUID()
    
    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add URL")
                    .font(.headline)
                
                HStack(spacing: 8) {
                    StyledTextField(placeholder: "Enter or paste URL...", text: $urlText) {
                        addURL()
                    }
                    
                    Button("Add") {
                        addURL()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(urlText.isEmpty || isLoading)
                }
            }
            
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Processing...")
                }
            }
            
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundColor(statusMessage.hasPrefix("✓") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(statusMessage.hasPrefix("✓") ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                    .cornerRadius(6)
            }
            
            Spacer()
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Quick Add")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(spacing: 8) {
                    QuickAddButton(icon: "play.rectangle.fill", title: "YouTube", color: .red) {
                        urlText = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
                        refreshKey = UUID()
                    }
                    QuickAddButton(icon: "link", title: "Direct URL", color: .purple) {
                        urlText = "http://example.com/media.mp3"
                        refreshKey = UUID()
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
        .padding()
    }
    
    private func addURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        isLoading = true
        statusMessage = ""
        
        Task {
            do {
                guard let url = URL(string: trimmed) else {
                    await MainActor.run {
                        statusMessage = "Error: Invalid URL"
                        isLoading = false
                    }
                    return
                }
                
                let source = try await appState.streamResolver.resolve(url: url)

                // Opaque links (uuids, index.php, percent-encoded slugs) hide the
                // real file name, so ask the origin. This hits the network, so it
                // happens before we hop to the main actor.
                var resolvedName: String?
                if case .remote(let remoteURL) = source {
                    resolvedName = await appState.streamResolver.resolveFileName(for: remoteURL)
                }

                await MainActor.run {
                    switch source {
                    case .youTube(_, let title):
                        statusMessage = "✓ Added: YouTube - \(title)"
                        appState.addRecentItem(title: "YouTube: \(title)", type: "url", url: url, mediaTitle: title)
                        urlText = ""
                        refreshKey = UUID()
                    case .bandcamp(_, let title):
                        statusMessage = "✓ Added: Bandcamp - \(title)"
                        appState.addRecentItem(title: "Bandcamp: \(title)", type: "url", url: url, mediaTitle: title)
                        urlText = ""
                        refreshKey = UUID()
                    case .soundCloud(_, let title):
                        statusMessage = "✓ Added: SoundCloud - \(title)"
                        appState.addRecentItem(title: "SoundCloud: \(title)", type: "url", url: url, mediaTitle: title)
                        urlText = ""
                        refreshKey = UUID()
                    case .local(let fileURL):
                        statusMessage = "✓ Added: \(fileURL.lastPathComponent)"
                        appState.addRecentItem(title: fileURL.lastPathComponent, type: "local", url: fileURL)
                        urlText = ""
                        refreshKey = UUID()
                    case .remote(let remoteURL):
                        let name = resolvedName ?? remoteURL.lastPathComponent
                        statusMessage = "✓ Added: \(name)"
                        appState.addRecentItem(title: name, type: "url", url: remoteURL, mediaTitle: name)
                        urlText = ""
                        refreshKey = UUID()
                    case .error(let message):
                        statusMessage = "Error: \(message)"
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Error: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
}

struct QuickAddButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 24)
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(color.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}