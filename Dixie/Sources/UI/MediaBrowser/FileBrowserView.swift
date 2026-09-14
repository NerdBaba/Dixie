import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedFolder: URL?
    @State private var isScanning = false
    @State private var scannedItems: [MediaItem] = []
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("Source", selection: $selectedTab) {
                Text("Folder").tag(0)
                Text("Files").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            
            Divider()
            
            if selectedTab == 0 {
                folderView
            } else {
                filesView
            }
        }
    }
    
    private var folderView: some View {
        VStack(spacing: 20) {
            if let folder = selectedFolder {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.blue)
                    Text(folder.lastPathComponent)
                        .font(.headline)
                    Spacer()
                    Button(action: scanFolder) {
                        if isScanning {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Label("Scan", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(isScanning)
                }
                .padding()
                
                if !scannedItems.isEmpty {
                    List(scannedItems) { item in
                        HStack {
                            Image(systemName: item.isAudio ? "music.note" : "film")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading) {
                                Text(item.title)
                                    .lineLimit(1)
                                Text(item.mimeType)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } else if isScanning {
                    Spacer()
                    ProgressView("Scanning...")
                    Spacer()
                } else {
                    Spacer()
                    Text("Press Scan to index media")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                Spacer()
                VStack(spacing: 15) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No folder selected")
                        .font(.headline)
                    Button("Select Media Folder") {
                        selectFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        }
    }
    
    private var filesView: some View {
        VStack(spacing: 20) {
            if !scannedItems.isEmpty {
                List(scannedItems) { item in
                    HStack {
                        Image(systemName: item.isAudio ? "music.note" : "film")
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading) {
                            Text(item.title)
                                .lineLimit(1)
                            Text(item.mimeType)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: { removeItem(item) }) {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Spacer()
                VStack(spacing: 15) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No files added")
                        .font(.headline)
                    Button("Add Media Files") {
                        selectFiles()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        }
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing media files"
        
        if panel.runModal() == .OK, let url = panel.url {
            selectedFolder = url
            appState.watchFolders.append(url)
            scanFolder()
        }
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Select media files"
        panel.allowedContentTypes = [.audio, .movie, .video]
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                let item = MediaItem(url: url)
                scannedItems.append(item)
                Task {
                    await appState.mediaLibrary.addItem(item)
                }
            }
        }
    }
    
    private func removeItem(_ item: MediaItem) {
        Task {
            await appState.mediaLibrary.removeItem(item)
        }
    }
    
    private func scanFolder() {
        guard let folder = selectedFolder else { return }
        
        isScanning = true
        scannedItems = []
        
        Task {
            let items = try? await appState.mediaLibrary.scanFolder(folder)
            await MainActor.run {
                scannedItems = items ?? []
                isScanning = false
            }
        }
    }
}