# DataLink Connect 4.5 Installer Analysis

## Artifact

- File: `DataLinkConnect4.5.457.10Setup.exe`
- Size: approximately 23 MB (23,794,856 bytes)
- SHA-256: `7ee60d1d4e4bbb79c58e241f79a84ccce02160214339e640644437af623866fa`
- Format: 32-bit Windows PE executable; Nullsoft NSIS self-extracting installer
- NSIS bootstrap version: 2.46

The installer was inspected statically and was not executed.

## Findings

The installer was successfully extracted with 7-Zip 26.03. It contains 403
files (about 116 MB uncompressed), including a 30 MB `DataLink Connect.exe`,
runtime libraries, USB-driver installers, firmware tools, form templates, and
accidentally shipped Subversion metadata.

The main application is a 32-bit Xojo/REALbasic native Windows executable, not
a .NET assembly. Its reflection/type strings preserve detailed class and method
names even though ordinary native symbols are unavailable.

## Scanner implementation evidence

The main executable contains the following Apperson-specific methods:

- `AppersonScanner.InitializeScanner`
- `AppersonScanner.TestScannerConnectivity`
- `AppersonScanner.Transact`
- `AppersonScanner.Write`
- `AppersonScanner.Event_DataAvailable`
- `AppersonScanner.ProcessPacket`
- `AppersonScanner.SetCurrentScanningMode`
- `AppersonScanner.Key1200` and `Key1200Binary`
- `AppersonScanner.WriteQuestions`
- `AppersonScanner.GetScannerSettings`
- `AppersonScanner.GetSerialNumber`

The receive pipeline includes `RawFormData`, `ScannerForm`, and
`FormDefinitionManager`. `RawFormData` stores side-one and side-two memory
blocks. This demonstrates that Connect receives raw form/mark data rather than
only a four-byte score.

The executable also contains a built-in diagnostic preference:

- `Log scanner data (requires restart)`
- `Logs scanner data to a file`
- preference key `LogScannerData`
- class `ScannerLog` with `LogData`
- visible log labels including `TX`, `RX`, and `ScannerLog-`

This logger is the lowest-risk path to recovering the wire protocol: run the
official application on Windows, enable the preference (apparently under the
Other preferences panel), restart Connect, and collect the generated scanner
log after connecting and scanning a controlled sheet.

Form templates (`.apft`) are unencrypted XML. They map channel/row coordinates
to semantic fields and responses. The wire data is therefore likely a raw mark
matrix plus a header; Connect uses the selected template to turn that matrix
into student IDs and answers.

`DeploymentPrefs.xml` documents an additional integration route: a configured
CLI gradebook consumer is launched with a temporary `.APXT` scanning-session
file. This could provide a report-at-end interface even before the live serial
protocol is fully reimplemented.

## Recommended next analysis

1. Run DataLink Connect on Windows, enable **Log scanner data (requires
   restart)** in preferences, restart it, connect the scanner, and collect the
   generated `ScannerLog-*` file.
2. Record an idle connection, scanner initialization, mode change, key
   download, and one controlled sheet as separate traces.
3. Compare TX/RX bytes with the existing macOS captures and implement the
   minimum initialization plus receive parser in Python.
4. Inspect a saved `.APXT` file as a potentially easier report-at-end path.
5. If needed, continue native disassembly of the named Xojo methods to recover
   literal commands and packet framing.

Runtime capture should use a serial monitoring tool or a controlled proxy and
record both host-to-scanner and scanner-to-host bytes. Passive macOS capture
cannot reveal the missing host handshake.
