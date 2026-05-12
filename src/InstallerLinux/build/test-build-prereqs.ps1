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
$bashPath = Find-CommandPath "bash" @()

$missing = @()
if (-not $dockerPath) {
    $missing += @{ Name = "Docker"; Help = "Install Docker Desktop or run this build on a machine with Docker." }
}

if (-not $bashPath) {
    $missing += @{ Name = "bash"; Help = "Install WSL or Git Bash." }
}

if ($missing.Count -gt 0) {
    Write-Host "HAOS AIO boot image build prerequisites are missing:"
    foreach ($item in $missing) {
        Write-Host "- $($item.Name): $($item.Help)"
    }
    exit 1
}

Write-Host "HAOS AIO boot image build prerequisites found."
& $dockerPath --version
bash --version | Select-Object -First 1

