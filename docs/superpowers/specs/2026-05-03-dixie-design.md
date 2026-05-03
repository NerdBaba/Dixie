# Dixie - UPnP/DLNA Media Server for macOS

## Project Overview

**Project Name:** Dixie
**Platform:** macOS (Apple Silicon)
**Type:** Personal media server and streaming application

Dixie is a macOS application that serves as a UPnP/DLNA media server, allowing users to:
- Share local media files with DLNA-compatible devices (TVs, speakers, consoles)
- Stream media to DLNA renderers on the local network
- Play internet content from YouTube, Bandcamp, SoundCloud, and direct URLs

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        SwiftUI App                           │
├─────────────────────────────────────────────────────────────┤
│  UI Layer          │  Services Layer      │  Network Layer │
│  ─────────         │  ──────────────       │  ───────────── │
│  - Media Browser   │  - DLNA Server        │  - Network     │
│  - Player Controls │  - UPnP Discovery     │    Discovery   │
│  - Device Picker   │  - Stream Resolver     │  - HTTP Server │
│  - Settings        │  - Media Library       │    (local)     │
│                    │  - yt-dlp Wrapper      │                │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

### UPnPStack
- SSDP discovery for finding renderers on local network
- Device management and state tracking
- SOAP-based control (AVTransport, ConnectionManager)

### ContentDirectory
- Implements DLNA ContentDirectory service
- Browse, search, and item metadata operations
- Serves media to renderers via HTTP

### MediaLibrary
- Scans and indexes local media files
- Extracts metadata (ID3, MP4, etc.) using AVFoundation
- Maintains searchable database

### StreamResolver
- Handles multiple URL types:
  - Local file URLs (file://)
  - Direct HTTP/HTTPS URLs
  - YouTube URLs → yt-dlp extraction
  - Bandcamp URLs → API-based stream URL extraction
  - SoundCloud URLs → API-based stream URL extraction

### LocalHTTPServer
- Lightweight HTTP server for serving media to renderers
- Handles range requests for seeking
- Proxies streaming content when needed

### Player (Built-in)
- AVPlayer-based playback for local control mode
- Play/pause/seek/volume controls
- Queue management

## UI Structure

### Sidebar Navigation
- **Files** — Folder browser for local media
- **Library** — Indexed collection with artwork, search, sort
- **Devices** — Discovered UPnP renderers + server status
- **URLs** — Direct URL input + internet service shortcuts
- **Settings** — Shared folders, port config, startup options

### Content Area
- Grid/List view of media items
- Device selector for playback target
- Quick URL input field

## Data Flow

### DLNA Server Mode
1. App scans configured folders → builds media library
2. SSDP advertises presence to local network
3. TV/Renderer discovers app as MediaServer
4. Renderer browses content via HTTP
5. App serves file or proxies stream based on URL type

### Playback Control Mode
1. SSDP discovers renderers on network
2. User selects target device from sidebar
3. User picks local file or enters URL
4. App extracts stream URL (yt-dlp for YouTube, API for others)
5. App sends AVTransport URI to renderer
6. Renderer streams directly from source

## Error Handling

- **Network offline** — Show banner, disable device discovery
- **Renderer unreachable** — Show offline status, retry on interval
- **yt-dlp failure** — Show error toast, suggest retry
- **Unsupported format** — Log and skip, show placeholder
- **File access denied** — Prompt for folder access permission

## Dependencies

- **yt-dlp** — CLI tool for extracting YouTube/stream URLs
- **AVFoundation** — Media metadata extraction and playback
- **Network** (Foundation) — UPnP/SSDP discovery
- **SwiftNIO** (optional) — HTTP server for production

## Non-Goals (Initial Version)

- Screen mirroring
- Live camera/microphone casting
- Stream recording
- Media library sync across devices
- Multiple simultaneous renderer connections

## Success Criteria

1. App appears as DLNA MediaServer on local network
2. Users can browse and play local media on TVs/speakers
3. Users can stream YouTube/Bandcamp/SoundCloud to renderers
4. Built-in player works for local control mode
5. Folder selection for media directories
6. Searchable library view