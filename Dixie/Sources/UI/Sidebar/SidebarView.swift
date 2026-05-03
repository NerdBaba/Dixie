import SwiftUI

struct SidebarView: View {
    @Binding var selectedTab: SidebarItem
    
    var body: some View {
        List(SidebarItem.allCases, selection: $selectedTab) { item in
            Label(item.rawValue, systemImage: item.icon)
                .tag(item)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }
}