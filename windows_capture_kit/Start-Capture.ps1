$ErrorActionPreference = "Continue"
$kitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$startedAt = Get-Date
$stamp = $startedAt.ToString("yyyyMMdd_HHmmss")
$captureRoot = Join-Path $kitRoot "DataLinkCapture_$stamp"
New-Item -ItemType Directory -Path $captureRoot -Force | Out-Null

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Copy-OpenFile([string]$Source, [string]$Destination) {
    # DataLink Connect sometimes keeps its log handle open after its window
    # closes. FileShare.ReadWrite/Delete lets us take a point-in-time copy.
    $sourceStream = $null
    $destinationStream = $null
    try {
        $sourceStream = [System.IO.FileStream]::new(
            $Source,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        $destinationStream = [System.IO.FileStream]::new(
            $Destination,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $sourceStream.CopyTo($destinationStream)
    } finally {
        if ($destinationStream) { $destinationStream.Dispose() }
        if ($sourceStream) { $sourceStream.Dispose() }
    }
}

Write-Section "DataLink Windows capture"
Write-Host "Capture started: $startedAt"
Write-Host "Output: $captureRoot"

Write-Section "Detected serial ports"
$ports = Get-CimInstance Win32_SerialPort -ErrorAction SilentlyContinue |
    Select-Object DeviceID, Name, Description, PNPDeviceID
if ($ports) {
    $ports | Format-Table -AutoSize
    $ports | ConvertTo-Json -Depth 4 | Set-Content (
        Join-Path $captureRoot "serial_ports.json"
    ) -Encoding UTF8
} else {
    Write-Warning "No Win32_SerialPort devices were reported."
    "[]" | Set-Content (Join-Path $captureRoot "serial_ports.json") -Encoding UTF8
}

Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FriendlyName -match "DataLink|Apperson|Advantage|CP210|Silicon Labs|COM\d+"
    } |
    Select-Object Status, Class, FriendlyName, InstanceId |
    ConvertTo-Json -Depth 4 |
    Set-Content (Join-Path $captureRoot "matching_pnp_devices.json") -Encoding UTF8

$searchRoots = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:LOCALAPPDATA
) | Where-Object { $_ -and (Test-Path $_) }

$dataLinkExe = $null
foreach ($root in $searchRoots) {
    $dataLinkExe = Get-ChildItem $root -Filter "DataLink Connect.exe" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dataLinkExe) { break }
}

Write-Section "Prepare DataLink Connect"
if ($dataLinkExe) {
    Write-Host "Found: $($dataLinkExe.FullName)"
    (Get-Item $dataLinkExe.FullName).VersionInfo |
        Format-List * |
        Out-File (Join-Path $captureRoot "datalink_version.txt") -Encoding UTF8
    Start-Process $dataLinkExe.FullName
} else {
    Write-Warning "DataLink Connect.exe was not found. Start it manually."
}

Write-Host ""
Write-Host "In DataLink Connect:" -ForegroundColor Yellow
Write-Host "  1. Preferences -> Other -> enable 'Log scanner data (requires restart)'."
Write-Host "  2. Exit and restart DataLink Connect."
Write-Host "  3. Wait idle 10 seconds."
Write-Host "  4. Scan a SYNTHETIC key, then one SYNTHETIC student sheet."
Write-Host "  5. Save the session and completely exit DataLink Connect."
Write-Host ""
Read-Host "After DataLink Connect has exited, press Enter to collect evidence"

Write-Section "Collecting recent evidence"
$endedAt = Get-Date
$candidateRoots = @(
    $env:APPDATA,
    $env:LOCALAPPDATA,
    $env:PROGRAMDATA,
    $env:USERPROFILE
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

$patterns = @(
    "ScannerLog*",
    "DebugTraceLog*.log",
    "*.apxt",
    "*.settings",
    "*DataLink*.xml",
    "*Preference*.xml"
)
$found = @()
foreach ($root in $candidateRoots) {
    foreach ($pattern in $patterns) {
        $found += Get-ChildItem $root -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $startedAt.AddMinutes(-5) }
    }
}
$found = $found | Sort-Object FullName -Unique

$manifest = @()
foreach ($file in $found) {
    try {
        $temporaryName = "pending_{0}_{1}" -f ([Guid]::NewGuid().ToString("N")), $file.Name
        $temporaryPath = Join-Path $captureRoot $temporaryName
        Copy-OpenFile $file.FullName $temporaryPath
        $hash = (Get-FileHash $temporaryPath -Algorithm SHA256 -ErrorAction Stop).Hash
        $safeName = "{0}_{1}" -f $hash.Substring(0, 12), $file.Name
        $collectedPath = Join-Path $captureRoot $safeName
        Move-Item $temporaryPath $collectedPath -Force
        $manifest += [PSCustomObject]@{
            OriginalPath = $file.FullName
            CollectedName = $safeName
            Length = $file.Length
            LastWriteTime = $file.LastWriteTime
            SHA256 = $hash
        }
        Write-Host "Collected: $($file.FullName)"
    } catch {
        Write-Warning "Could not collect $($file.FullName): $($_.Exception.Message)"
        if ($temporaryPath -and (Test-Path $temporaryPath)) {
            Remove-Item $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$manifest | Export-Csv (Join-Path $captureRoot "manifest.csv") -NoTypeInformation
@{
    CaptureStarted = $startedAt.ToString("o")
    CaptureEnded = $endedAt.ToString("o")
    ComputerName = $env:COMPUTERNAME
    WindowsVersion = [Environment]::OSVersion.VersionString
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    FilesCollected = @($manifest).Count
} | ConvertTo-Json | Set-Content (Join-Path $captureRoot "capture_info.json") -Encoding UTF8

$zipPath = "$captureRoot.zip"
Compress-Archive -Path (Join-Path $captureRoot "*") -DestinationPath $zipPath -Force

Write-Section "Finished"
Write-Host "Collected $(@($manifest).Count) evidence files."
Write-Host "ZIP file: $zipPath" -ForegroundColor Green
if (@($manifest).Count -eq 0) {
    Write-Warning "No recent scanner log or APXT was found. Keep the capture folder; the diagnostics still help locate the issue."
}
Write-Host "Use synthetic data only; inspect the ZIP before sharing it."
Read-Host "Press Enter to close"
