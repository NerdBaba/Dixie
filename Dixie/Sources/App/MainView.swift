import SwiftUI

struct MainView: View {
    @State private var selectedTab: SidebarItem = .files
    @StateObject private var appState = AppState()
    
    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab)
        } detail: {
            switch selectedTab {
            case .files:
                FileBrowserView()
            case .library:
                LibraryView()
            case .devices:
                DevicesView()
            case .urls:
                URLInputView()
            case .settings:
                SettingsView()
            }
        }
        .environmentObject(appState)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case files = "Files"
    case library = "Library"
    case devices = "Devices"
    case urls = "URLs"
    case settings = "Settings"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .files: return "folder"
        case .library: return "music.note.list"
        case .devices: return "tv"
        case .urls: return "link"
        case .settings: return "gear"
        }
    }
}