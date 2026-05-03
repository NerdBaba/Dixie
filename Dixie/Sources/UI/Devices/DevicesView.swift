import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DLNA Server")
                            .font(.headline)
                        Text(appState.isServerRunning ? "Serving media on your network" : "Not running")
                            .font(.caption)
                            .foregroundColor(appState.isServerRunning ? .green : .secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: toggleServer) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(appState.isServerRunning ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(appState.isServerRunning ? "ON" : "OFF")
                                .font(.callout)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(appState.isServerRunning ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                        .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                }
                
                if appState.isServerRunning {
                    HStack {
                        Image(systemName: "globe")
                            .foregroundColor(.blue)
                        Text("http://\(getLocalIP()):8080")
                            .font(.system(.callout, design: .monospaced))
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            .padding()
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Network Devices")
                        .font(.headline)
                    Spacer()
                    Button(action: scanForDevices) {
                        HStack(spacing: 4) {
                            if isScanning {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Scan")
                        }
                    }
                    .disabled(isScanning)
                }
                
                if appState.discoveredDevices.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tv")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text(isScanning ? "Scanning for devices..." : "No DLNA devices found")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    ForEach(appState.discoveredDevices) { device in
                        HStack {
                            Image(systemName: "tv")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.address)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding()
            
            Spacer()
        }
    }
    
    private func toggleServer() {
        if appState.isServerRunning {
            appState.dlnaServer.stop()
            appState.isServerRunning = false
        } else {
            do {
                appState.dlnaServer.configure(mediaLibrary: appState.mediaLibrary)
                try appState.dlnaServer.start()
                appState.isServerRunning = true
            } catch {
                print("Failed to start server: \(error)")
                appState.isServerRunning = false
            }
        }
    }
    
    private func scanForDevices() {
        isScanning = true
        appState.discoveredDevices = []
        
        print("[UI] Starting device scan...")
        
        let discovery = SSDPDiscovery()
        
        discovery.onDeviceDiscovered = { device in
            print("[UI] Device found: \(device.st)")
            DispatchQueue.main.async {
                self.appState.discoveredDevices.append(DiscoveredDevice(
                    name: device.st.isEmpty ? "Unknown Device" : device.st,
                    address: device.location.absoluteString,
                    type: .renderer
                ))
            }
        }
        
        discovery.start()
        
        Task { @MainActor in
            print("[UI] Waiting for devices...")
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            let devices = discovery.getDevices()
            print("[UI] Scan complete, found \(devices.count) devices")
            if devices.isEmpty {
                print("[UI] No devices found. Make sure your TV is on and DLNA/UPnP is enabled.")
            }
            isScanning = false
        }
    }
    
    private func getLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return address }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            let interface = ptr!.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        
        return address
    }
}