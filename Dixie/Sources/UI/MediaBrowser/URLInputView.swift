import SwiftUI

struct URLInputView: View {
    @EnvironmentObject var appState: AppState
    @State private var urlText: String = ""
    @State private var isLoading = false
    @State private var statusMessage = ""
    @State private var isFocused = false
    
    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add URL")
                    .font(.headline)
                
                HStack(spacing: 8) {
                    TextField("Enter or paste URL...", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .frame(height: 36)
                    
                    Button("Add") {
                        addURL()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(width: 70)
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
                    QuickAddRow(icon: "play.rectangle.fill", title: "YouTube", color: .red) {
                        urlText = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
                    }
                    QuickAddRow(icon: "music.note", title: "Bandcamp", color: .blue) {
                        urlText = "https://bandcamp.com/"
                    }
                    QuickAddRow(icon: "waveform", title: "SoundCloud", color: .orange) {
                        urlText = "https://soundcloud.com/"
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
                await MainActor.run {
                    switch source {
                    case .youTube(let streamURL, let title):
                        statusMessage = "✓ Added: YouTube - \(title)"
                        appState.addRecentItem(title: "YouTube: \(title)", type: "url")
                        urlText = ""
                    case .bandcamp(_, let title):
                        statusMessage = "✓ Added: Bandcamp - \(title)"
                        appState.addRecentItem(title: "Bandcamp: \(title)", type: "url")
                        urlText = ""
                    case .soundCloud(_, let title):
                        statusMessage = "✓ Added: SoundCloud - \(title)"
                        appState.addRecentItem(title: "SoundCloud: \(title)", type: "url")
                        urlText = ""
                    case .local(let fileURL):
                        statusMessage = "✓ Added: \(fileURL.lastPathComponent)"
                        appState.addRecentItem(title: fileURL.lastPathComponent, type: "local")
                        urlText = ""
                    case .remote(let remoteURL):
                        statusMessage = "✓ Added: \(remoteURL.lastPathComponent)"
                        appState.addRecentItem(title: remoteURL.lastPathComponent, type: "url")
                        urlText = ""
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

struct QuickAddRow: View {
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