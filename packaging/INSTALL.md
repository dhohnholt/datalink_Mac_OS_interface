# DataLink Scanner for macOS

1. Drag **DataLink Scanner** onto the **Applications** shortcut.
2. Open Applications and launch **DataLink Scanner**.
3. To keep it in the Dock, Control-click its Dock icon and choose
   **Options → Keep in Dock**.
4. Connect the DataLink 1200 by USB, enter a test name, choose the question
   count, and select **Connect and enter Data Collection**.
5. Scan the answer key first, then the student sheets.

The app opens its workspace in the default browser and keeps all scan data on
the Mac. Saved sessions are stored in:

`~/Library/Application Support/DataLink Scanner/captures`

This build is for Apple-silicon Macs. It is ad-hoc signed rather than Apple
notarized. If macOS blocks the first launch, Control-click the app, choose
**Open**, and confirm **Open** once.

If no USB serial port appears after connecting the scanner, install the
Silicon Labs CP210x VCP driver for that Mac and reconnect the scanner.

If another DataLink Scanner instance is already running, launching the app
opens that existing browser workspace instead of starting a duplicate server.
