# Native front end (phase 7, not yet wired up)

The model layer for a future SwiftUI application over the same protocol the
Python workspace already implements. It does not talk to the scanner yet and
there is no UI — the working application is the browser workspace in `../src`.

```bash
swift build
swift test
```

It lives in its own directory because the Swift package wants `Tests/` and the
Python suite wants `tests/`, and macOS filesystems are case-insensitive.
