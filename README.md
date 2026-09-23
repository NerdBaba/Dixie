# Dixie

Dixie is a native macOS UPnP/DLNA media server. It lets a Mac advertise a local media library to compatible TVs, speakers, consoles, and other DLNA clients on the same network.

> **Project status:** early-stage and experimental. Dixie is suitable for development and local testing, but it has not yet had a stable public release.

## What works

- Advertises Dixie as a UPnP/DLNA MediaServer over SSDP.
- Serves local audio and video files over HTTP with byte-range support.
- Implements ContentDirectory browse/search responses for DLNA clients.
- Discovers UPnP/DLNA devices on the local network.
- Accepts direct remote media URLs.
- Resolves YouTube URLs when [yt-dlp](https://github.com/yt-dlp/yt-dlp) is installed.
- Provides a native SwiftUI interface for files, library browsing, devices, URLs, and server status.

## Current limitations

- macOS 14 or later is required.
- Bandcamp and SoundCloud URL resolution are not implemented yet.
- The server is designed for trusted local networks only. It does not provide authentication or TLS.
- App Sandbox is disabled because Dixie needs multicast SSDP and inbound LAN connections.
- Some DLNA renderers vary in their protocol support, so device compatibility is still evolving.
- Large local files are currently read into memory before being served.

## Requirements

- macOS 14+
- Xcode with Swift 6 support
- Optional: `yt-dlp` for YouTube URL resolution

Install the optional YouTube helper with Homebrew:

```bash
brew install yt-dlp
```

## Build

Clone the repository and open the Xcode project:

```bash
git clone https://github.com/NerdBaba/Dixie.git
cd Dixie
open Dixie/Dixie.xcodeproj
```

Select the **Dixie** scheme and run the app.

You can also build the Swift package from the command line on macOS:

```bash
swift build --package-path Dixie
```

## Use

1. Launch Dixie.
2. Open **Settings** and add a media folder.
3. Open **Devices** and start the DLNA server.
4. Make sure the Mac and playback device are on the same local network.
5. On the TV, speaker, console, or DLNA client, look for **Dixie Media Server** and browse the shared media.

Dixie listens on TCP port **8080** and uses SSDP multicast on UDP port **1900**.

## Architecture

The project is intentionally dependency-light:

- **SwiftUI** — native macOS interface
- **Network / BSD sockets** — HTTP serving and SSDP multicast
- **ContentDirectoryService** — UPnP ContentDirectory browse/search handling
- **MediaLibrary** — local media indexing and MIME detection
- **StreamResolver** — direct URL handling and optional `yt-dlp` integration
- **DLNAServer** — HTTP, SOAP, SSDP announcements, and media delivery

Source code lives under `Dixie/Sources`.

## Security and privacy

Starting the server makes selected media available to DLNA clients that can reach your Mac on the local network. Dixie currently has no user authentication or transport encryption, so **do not expose port 8080 to the public internet**.

See [SECURITY.md](SECURITY.md) for reporting guidance and additional deployment notes.

## Contributing

Bug reports and focused pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes.

## License

A project license has not been selected yet. Until a `LICENSE` file is added, no open-source license is granted.

If this repository is going to be made public for third-party reuse, choose and add an explicit license first.
