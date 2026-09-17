$since = (Get-Date).AddHours(-2)
$roots = @(
    $env:APPDATA,
    $env:LOCALAPPDATA,
    $env:PROGRAMDATA,
    $env:USERPROFILE
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

$results = @()
foreach ($root in $roots) {
    $results += Get-ChildItem $root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -ge $since -and (
                $_.Name -like "ScannerLog*" -or
                $_.Extension -eq ".apxt" -or
                $_.FullName -match "DataLink|Apperson"
            )
        }
}
$results | Sort-Object LastWriteTime -Descending -Unique |
    Select-Object FullName, Length, LastWriteTime |
    Format-Table -AutoSize
