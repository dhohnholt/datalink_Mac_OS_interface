# Windows DataLink Protocol Capture Kit

This kit collects the diagnostic log produced by DataLink Connect itself. That
is preferable to a second serial sniffer because Windows normally permits only
one program at a time to own the scanner's COM port.

## What to bring

Copy this entire `windows_capture_kit` folder and
`DataLinkConnect4.5.457.10Setup.exe` to a USB drive.

## On the Windows PC

1. Extract the entire ZIP to a normal folder such as Downloads. Do not run the
   files from inside the ZIP preview.
2. Do not right-click the `.ps1` file and choose **Run with PowerShell**; that
   temporary window can close before an error can be read. Double-click
   `Run-Capture.cmd` instead. It keeps PowerShell open.
3. If DataLink Connect still needs to be installed, open PowerShell in the
   extracted bundle folder by clicking the File Explorer address bar, typing
   `powershell`, and pressing Enter.
4. Install DataLink Connect with:

   ```powershell
   Start-Process .\DataLinkConnect4.5.457.10Setup.exe -Wait
   ```

5. Connect the DataLink 1200 by USB and let Windows finish installing its
   driver.
6. Start the capture kit by double-clicking `Run-Capture.cmd`. Alternatively,
   run this command from an already-open PowerShell window:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\windows_capture_kit\Start-Capture.ps1
   ```

The PowerShell window must remain open while you work in DataLink Connect.

## Capture procedure

1. Install DataLink Connect normally if the installer command has not already
   done so.
2. Connect the DataLink 1200 by USB and let Windows finish installing its
   driver.
3. The script displays detected COM ports and opens DataLink Connect if it can
   locate it.
4. In DataLink Connect, open **Preferences**, select **Other**, enable
   **Log scanner data (requires restart)**, then completely exit and restart
   DataLink Connect.
5. Follow this controlled sequence, taking care not to use real student data:
   - Wait connected and idle for about 10 seconds.
   - Scan an answer key containing only synthetic/test marks.
   - Scan one synthetic student sheet with a fake ID such as `111111`.
   - Save the DataLink session when prompted.
   - Completely exit DataLink Connect so its log file is flushed.
6. Return to PowerShell and press Enter. The script copies recent logs,
   sessions, `.settings` files, debug traces, and diagnostic metadata into a
   timestamped folder and creates a ZIP next to this script.
7. Bring the generated `DataLinkCapture_*.zip` back to the Mac for analysis.

## Optional diagnostic commands

Show the scanner's Windows COM port:

```powershell
Get-CimInstance Win32_SerialPort |
  Select-Object DeviceID, Name, Description, PNPDeviceID |
  Format-Table -AutoSize
```

If the collection script reports that it found no files, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows_capture_kit\List-RecentDataLinkFiles.ps1
```

Do not open the scanner COM port with a separate serial terminal while
DataLink Connect is running. Only one application can normally own the port.

## Privacy

Use synthetic sheets only. Scanner logs and APXT files may contain IDs and all
marked answers. Review the ZIP before sharing it with anyone.

## Safety

The script does not write to the scanner, alter DataLink files, install
drivers, or require administrator privileges. DataLink Connect performs the
scanner communication. This script only inventories the PC and copies recently
modified evidence files.

## Known behavior

DataLink Connect 4.5 may create a `ScannerLog` containing only its session
header even when **Log scanner data** is enabled. The capture kit also collects
`DebugTraceLog-*.log`, because those traces proved more useful in the first
Windows capture and revealed the scanner's connectivity exchange.

The collector uses a read-sharing copy for logs that DataLink Connect still
has open. This avoids the `Get-FileHash ... being used by another process`
failure seen in the first run.
