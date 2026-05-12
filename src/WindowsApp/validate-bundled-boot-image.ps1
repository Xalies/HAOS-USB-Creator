param(
    [string]$BootImageDir = "$PSScriptRoot/src/HAOSInstaller.App/Assets/BootImage"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $BootImageDir -PathType Container)) {
    throw "Bundled boot image directory was not found: $BootImageDir"
}

$image = Get-ChildItem -LiteralPath $BootImageDir -File |
    Where-Object { $_.Name -like "haos-installer*.img" -or $_.Name -like "haos-installer*.usb" } |
    Sort-Object @{ Expression = { if ($_.Extension -eq ".img") { 0 } else { 1 } } }, LastWriteTimeUtc -Descending |
    Select-Object -First 1

if ($null -eq $image) {
    throw "Bundled HAOS Installer boot image was not found in: $BootImageDir"
}

$checksumPath = "$($image.FullName).sha256"
$manifestPath = "$($image.FullName).manifest.json"

if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
    throw "Bundled boot image checksum is missing: $checksumPath"
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Bundled boot image manifest is missing: $manifestPath"
}

$checksumText = Get-Content -LiteralPath $checksumPath -Raw
$expectedHash = ($checksumText -split "\s+" | Where-Object { $_ })[0]

if ($expectedHash -notmatch "^[a-fA-F0-9]{64}$") {
    throw "Bundled boot image checksum file does not start with a SHA-256 hash: $checksumPath"
}

$actualHash = (Get-FileHash -LiteralPath $image.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
    throw "Bundled boot image checksum mismatch. Expected $expectedHash but got $actualHash."
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1) {
    throw "Bundled boot image manifest has unsupported schemaVersion: $($manifest.schemaVersion)"
}

if ($manifest.artifactType -ne "haos_installer_boot") {
    throw "Bundled boot image manifest has unexpected artifactType: $($manifest.artifactType)"
}

if ($manifest.filename -and $manifest.filename -ne $image.Name) {
    throw "Bundled boot image manifest filename '$($manifest.filename)' does not match '$($image.Name)'."
}

Write-Host "Bundled HAOS Installer boot image validated: $($image.FullName)"
