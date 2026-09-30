# Phase 1 hardware check — what to run, what to report

The Flutter build's serial path is tested against a pseudo-terminal and against
Python's recorded behaviour, but **nothing here has touched a real DataLink
1200 yet**. This check is the one thing that can show a signed, sandboxed
Flutter build opening the CP210x node. Until you've run it, treat "serial works
in the sandbox" as *unproven for the Dart path*.

What is already known without the scanner (run on 2026-09-30, scanner not
attached):

- The release build is sandboxed (`HOME` is the container) and can list `/dev`.
- It opened `/dev/cu.Bluetooth-Incoming-Port` with our FFI code: **ok**.
- The same app re-signed without `device.serial` was refused: **`Operation not
  permitted, errno 1`**. So the entitlement is what grants the open, and our
  FFI path obeys it. That port is a stand-in for the scanner, not the scanner.

## Before you start

1. Quit the Python DataLink Scanner (Homebrew or Developer ID copy), and
   DataLink Connect if it is running anywhere. Two programs on one port lose
   each other's characters.
2. Plug in the DataLink 1200 and switch it on. Press Reset on the device until
   its display reads **Scan Mode Ready** (the host cannot set the mode; see
   `docs/PROTOCOL.md`).
3. Confirm the node exists:

   ```bash
   ls /dev/cu.usbserial*
   ```

## The run

The app is already built (ad-hoc signed, no certificate involved). It was built
with `flutter build macos --release` in `app/`; rebuild if you've changed
anything:

```bash
cd app && flutter build macos --release
```

Run it from a terminal so the report prints. It listens for 60 seconds after
the handshake, so have one sheet ready to feed:

```bash
cd app/build/macos/Build/Products/Release
DATALINK_HARDWARE_CHECK=1 DATALINK_HARDWARE_LISTEN=60 \
  "./DataLink Scanner.app/Contents/MacOS/DataLink Scanner"
```

As soon as it prints `Listening for 60 s`, feed **one sheet**. Student IDs are
masked in the report; only counts and shapes are printed.

(The same check is available in the app window: open `DataLink Scanner.app` and
use **Run check, then listen 60 s**, then **Copy report**.)

## Exclusivity check (optional, 10 seconds)

While the app is listening, in a **second** terminal:

```bash
python3 -c "import os; os.open('/dev/cu.usbserial-1200', os.O_RDONLY|os.O_NONBLOCK); print('opened: NOT excluded')"
```

`Resource busy` means the kernel honours our exclusive hold. `opened` means it
does not, and the lsof-based "someone else has the port" protection is weaker
than it was in the Python app. Either answer is useful.

## What to report back

1. The full report text.
2. The output of `ls /dev/cu.usbserial*`.
3. The exclusivity result, if you ran it.
4. Anything odd on the device's display.

## How to read the result

| You see | It means |
|---|---|
| `open: ok`, then `V -> ... ADV 1200OK`, `T2 -> 5.5`, `Q1 -> 4658`, `T4 -> S32155`, `Data Collection: active` | Serial works end to end from the sandboxed Dart build. This is the pass. |
| `macOS did not allow DataLink Scanner to open … errno 1` | The sandbox refused the CP210x node even with `device.serial`. **Stop: the plan changes** (fallback is a Swift plugin, which would face the same sandbox, so this would need a different answer). |
| `Another program already has the scanner open` | Something still holds the port. Quit it and rerun. |
| `open: ok` but `did not identify itself after 4 tries` | Sandbox let us in but the conversation failed. Compare `DTR`/`RTS`, re-press Reset, rerun; report the last answer it printed. |
| `usbserial ports: (none)` | The node is not visible. Check the cable and `ls /dev/cu.usbserial*` outside the app; if it is there outside but not inside, the sandbox is hiding it. |
| A `sheet 1: …` line after you feed a sheet | Records parse correctly on real hardware. |
