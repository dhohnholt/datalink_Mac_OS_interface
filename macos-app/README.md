# SwiftUI front end — parked experiment

An early, **unfinished** model layer for a native SwiftUI application. It is
kept on this branch only; `main` does not carry it.

## Why it is parked

The shipping application is the Python one on `main`. It now runs as a real
Cocoa app — its own window, full menu bar, no browser and no terminal — with
the working protocol implementation behind it. A parallel SwiftUI front end
would have to re-derive the protocol in Swift, and distributing a Swift binary
would force either Xcode onto every Mac that installs it or a notarized cask.
Neither was worth it.

## What is here

- `Models.swift` — `ScanRecord`, `ScanSession`, `ScannerState`, workspace
  sections
- `ScannerTransport.swift` — a transport *protocol* plus a demo implementation
- `ScannerWorkspaceModel.swift` — an observable workspace model

There is no UI and no `@main`, so this builds as a library, not an app.

## Important: this predates the protocol discovery

`DataLinkProtocol` here still says 9600 baud with `dataModeCommand = nil`. The
real scanner runs at **38400 8N1 with DTR off and RTS on**, and the command
sequence is known. Anyone reviving this should start from
`src/datalink_scanner/interface.py` on `main`, not from this file.

```bash
swift build
swift test
```
