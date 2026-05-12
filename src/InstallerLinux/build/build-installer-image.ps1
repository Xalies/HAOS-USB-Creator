param(
    [string]$OutDir = "./artifacts/installer-linux"
)

$ErrorActionPreference = "Stop"

function Find-CommandPath([string]$Command, [string[]]$FallbackPaths) {
    $commandInfo = Get-Command $Command -ErrorAction SilentlyContinue
    if ($commandInfo) {
        return $commandInfo.Source
    }

    foreach ($path in $FallbackPaths) {
        if (Test-Path $path) {
            $directory = Split-Path -Parent $path
            if ($env:Path -notlike "*$directory*") {
                $env:Path = "$directory;$env:Path"
            }
            return $path
        }
    }

    return $null
}

$dockerPath = Find-CommandPath "docker" @(
    "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
)

if (-not $dockerPath) {
    throw "Docker is required to build the HAOS AIO Installer USB image, but docker was not found on PATH."
}

if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    throw "bash is required to run the USB image builder script. Install WSL or Git Bash."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $scriptDir "build-installer-image.sh"

function Convert-ToBashPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        $drive = $matches[1].ToLowerInvariant()
        $rest = $matches[2] -replace '\\', '/'
        $wslPath = "/mnt/$drive/$rest"

        $uname = (& bash -lc "uname -r" 2>$null).Trim()
        if ($uname -match "microsoft|WSL") {
            return $wslPath
        }

        & bash -lc "[ -e '$wslPath' ]" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return $wslPath
        }

        return "/$drive/$rest"
    }

    return $full -replace '\\', '/'
}

$bashScript = Convert-ToBashPath $scriptPath
$bashOutDir = Convert-ToBashPath $OutDir

& bash -lc "'$bashScript' '$bashOutDir'"
if ($LASTEXITCODE -ne 0) {
    throw "HAOS AIO Installer USB image build failed."
}

