import AppKit
import Foundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var testResult: String = ""
    @State private var isTesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Server")
                        .font(.headline)

                    LabeledContent("HTTP port", value: String(appState.dlnaServer.port))

                    Text("Start and stop the DLNA server from Devices. Dixie is intended for trusted local networks only.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Media Library")
                        .font(.headline)

                    if appState.watchFolders.isEmpty {
                        HStack {
                            Image(systemName: "folder.badge.questionmark")
                                .foregroundColor(.secondary)
                            Text("No folders added")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ForEach(appState.watchFolders, id: \.self) { folder in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.blue)
                                Text(folder.path)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }

                    Button(action: addFolder) {
                        Label("Add Media Folder", systemImage: "folder.badge.plus")
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Server Status")
                        .font(.headline)

                    HStack {
                        Circle()
                            .fill(appState.isServerRunning ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(appState.isServerRunning ? "Running" : "Stopped")

                        Spacer()

                        if appState.isServerRunning {
                            Text("http://\(getLocalIP()):\(appState.dlnaServer.port)")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }

                    if appState.isServerRunning {
                        Button(action: testServer) {
                            HStack {
                                if isTesting {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "network")
                                }
                                Text("Test Connection")
                            }
                        }
                        .disabled(isTesting)

                        if !testResult.isEmpty {
                            Text(testResult)
                                .font(.caption)
                                .foregroundColor(testResult.contains("OK") ? .green : .red)
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("About")
                        .font(.headline)

                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Platform", value: "macOS 14+")
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            .padding()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            appState.watchFolders.append(url)

            Task {
                _ = try? await appState.mediaLibrary.scanFolder(url)
            }
        }
    }

    private func testServer() {
        isTesting = true
        testResult = ""

        Task {
            do {
                let url = URL(string: "http://127.0.0.1:\(appState.dlnaServer.port)")!
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse {
                    await MainActor.run {
                        testResult = "OK - Server responded (HTTP \(httpResponse.statusCode))"
                        isTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    testResult = "Failed: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }

    private func getLocalIP() -> String {
        NetworkUtil.localIPv4Address()
    }
}
