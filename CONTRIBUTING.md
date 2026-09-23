# Contributing to Dixie

Thanks for helping improve Dixie.

## Before you start

Dixie is an early-stage macOS UPnP/DLNA project. Please keep changes focused and explain compatibility assumptions, especially when behavior differs across TVs, speakers, or other renderers.

For larger feature changes, open an issue first so the behavior and scope can be discussed before implementation.

## Development setup

Requirements:

- macOS 14 or later
- Xcode with Swift 6 support
- Optional: `yt-dlp` for YouTube URL testing

Open the project:

```bash
open Dixie/Dixie.xcodeproj
```

Or verify the Swift package builds:

```bash
swift build --package-path Dixie
```

## Pull requests

Please:

1. Keep each pull request focused on one change.
2. Describe the user-visible behavior before and after the change.
3. Mention the macOS version and DLNA device/client used for manual testing when relevant.
4. Avoid committing build products, user-specific Xcode state, credentials, local paths, or media files.
5. Update the README when requirements, supported behavior, ports, or limitations change.

## Code style

- Follow existing Swift naming and formatting.
- Prefer small types and explicit responsibilities.
- Keep network operations off the main actor unless UI state must be updated.
- Treat input from network devices and remote URLs as untrusted.
- Avoid adding third-party dependencies unless they materially simplify a hard interoperability problem.

## Reporting bugs

Please include:

- macOS version
- Dixie commit or version
- Playback device/client model and software version
- Steps to reproduce
- Expected and actual behavior
- Relevant logs with private URLs, file names, IP addresses, and other personal data removed

For security issues, follow [SECURITY.md](SECURITY.md) instead of filing a public bug.
