import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""
    @State private var searchResults: [MediaItem] = []
    @State private var isSearching = false
    @State private var refreshKey = UUID()
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                StyledTextField(placeholder: "Search library...", text: $searchText) {
                    performSearch()
                }
                
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        searchResults = []
                        refreshKey = UUID()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            
            Divider()
            
            if isSearching {
                VStack { Spacer(); ProgressView("Searching..."); Spacer() }
            } else if !searchText.isEmpty && !searchResults.isEmpty {
                List(searchResults) { item in
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
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        
        Task {
            let results = await appState.mediaLibrary.search(query: searchText)
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        }
    }
}