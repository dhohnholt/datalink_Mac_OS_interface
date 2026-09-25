# DataLink Scanner for macOS

1. Drag **DataLink Scanner** onto the **Applications** shortcut.
2. Open Applications and launch **DataLink Scanner**.
3. To keep it in the Dock, Control-click its Dock icon and choose
   **Options → Keep in Dock**.
4. Connect the DataLink 1200 by USB, enter a test name, choose the question
   count, and select **Connect and start session**.
5. Scan the answer key first, then the student sheets.
6. Select **End session** when the class is done. The scanner stays connected
   for the next one.

The app opens its own window with a normal menu bar, and keeps all scan data on
the Mac. Saved sessions are stored in:

`~/Library/Application Support/DataLink Scanner/captures`

This build is for Apple-silicon Macs and is signed with an Apple Developer ID.
If macOS still blocks the first launch, the build was not notarized —
Control-click the app, choose **Open**, and confirm **Open** once.

If no USB serial port appears after connecting the scanner, install the
Silicon Labs CP210x VCP driver for that Mac and reconnect the scanner.

Installing with Homebrew instead avoids the Gatekeeper prompt entirely and
updates with `brew upgrade`:

    brew install dhohnholt/datalink/datalink-scanner
    datalink-scanner install-app
