import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchQuery: String = ""
    @State private var searchResults: [MediaItem] = []
    @State private var isSearching = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search library...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        performSearch()
                    }
                
                if !searchQuery.isEmpty {
                    Button(action: {
                        searchQuery = ""
                        searchResults = []
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            if isSearching {
                VStack { Spacer(); ProgressView(); Spacer() }
            } else if !searchQuery.isEmpty && !searchResults.isEmpty {
                List(searchResults) { item in
                    LibraryItemRow(item: item)
                }
            } else if !appState.recentItems.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Recently Added")
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                        
                        Divider()
                        
                        ForEach(appState.recentItems) { item in
                            HStack {
                                Image(systemName: item.type == "url" ? "link" : "music.note")
                                    .foregroundColor(.secondary)
                                    .frame(width: 30)
                                Text(item.title)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("Search your library")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Add media folders in Settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }
    
    private func performSearch() {
        guard !searchQuery.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        
        Task {
            let results = await appState.mediaLibrary.search(query: searchQuery)
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        }
    }
}

struct LibraryItemRow: View {
    let item: MediaItem
    
    var body: some View {
        HStack {
            Image(systemName: item.isAudio ? "music.note" : "film")
                .foregroundColor(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading) {
                Text(item.title)
                    .lineLimit(1)
                Text(item.mimeType)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}