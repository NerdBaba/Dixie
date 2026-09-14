import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var discovery: SSDPDiscovery?
    
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
        discovery?.stop()
        isScanning = true
        appState.discoveredDevices = []

        print("[UI] Starting device scan...")

        let scanner = SSDPDiscovery()
        scanner.onDeviceDiscovered = { [weak appState] device in
            print("[UI] Device found: \(device.st) server=\(device.server)")
            let type: DiscoveredDevice.DeviceType =
                device.st.localizedCaseInsensitiveContains("MediaRenderer")
                || device.st.localizedCaseInsensitiveContains("AVTransport")
                || device.st.localizedCaseInsensitiveContains("RenderingControl")
                ? .renderer : .server
            let entry = DiscoveredDevice(
                name: friendlyName(for: device),
                address: device.location.absoluteString,
                type: type
            )
            Task { @MainActor in
                guard let appState else { return }
                if !appState.discoveredDevices.contains(where: { $0.address == entry.address && $0.name == entry.name }) {
                    appState.discoveredDevices.append(entry)
                }
            }
        }
        discovery = scanner
        scanner.start()

        Task { @MainActor in
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                scanner.resendMsearch()
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let devices = scanner.getDevices()
            print("[UI] Scan complete, found \(devices.count) devices")
            if devices.isEmpty {
                print("[UI] No devices found. Make sure your TV is on and DLNA/UPnP is enabled, and Mac + TV share the same Wi-Fi.")
            }
            isScanning = false
        }
    }

    private func friendlyName(for device: SSDPDiscovery.DiscoveredUPnPDevice) -> String {
        if !device.server.isEmpty { return device.server }
        if !device.st.isEmpty { return device.st }
        return device.location.host ?? "Unknown Device"
    }

    private func getLocalIP() -> String {
        NetworkUtil.localIPv4Address()
    }
}