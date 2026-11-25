param(
    [string]$InstallDir = "C:\AG_Profiles",
    [string[]]$Profiles = @("acc1", "acc2", "acc3"),
    [switch]$NoDesktopShortcuts,
    [switch]$NoAdmin
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$srcSwitch = Join-Path $scriptRoot "Switch-AG.ps1"
if (-not (Test-Path -LiteralPath $srcSwitch)) {
    throw "Switch-AG.ps1 not found at $srcSwitch"
}

$agExe = Join-Path $env:LOCALAPPDATA "Programs\antigravity\Antigravity.exe"
if (-not (Test-Path -LiteralPath $agExe)) {
    Write-Warning "Antigravity.exe not found at $agExe. Install Antigravity before launching profiles."
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$dstSwitch = Join-Path $InstallDir "Switch-AG.ps1"
if ([System.IO.Path]::GetFullPath($srcSwitch) -ne [System.IO.Path]::GetFullPath($dstSwitch)) {
    Copy-Item -LiteralPath $srcSwitch -Destination $dstSwitch -Force
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$ws = if (-not $NoDesktopShortcuts) { New-Object -ComObject WScript.Shell } else { $null }
$desktopDir = [Environment]::GetFolderPath("Desktop")

$Profiles = @($Profiles | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($Profiles.Count -eq 0) {
    throw "At least one profile name must be specified."
}

foreach ($p in $Profiles) {
    if ($p -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Invalid profile name '$p'. Allowed pattern: ^[A-Za-z0-9_-]+$"
    }

    $profileDir = Join-Path $InstallDir $p
    $userDataDir = Join-Path $profileDir "userdata"
    New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null

    $display = ($p.Substring(0, 1).ToUpperInvariant() + $p.Substring(1))
    $batName = "AG_$display.bat"
    $batPath = Join-Path $InstallDir $batName

    if ($NoAdmin) {
        $batBody = @"
@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "$dstSwitch" -Profile "$p"
if errorlevel 1 pause
"@
    } else {
        $batBody = @"
@echo off
chcp 65001 >nul
fltmc >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "$dstSwitch" -Profile "$p"
if errorlevel 1 pause
"@
    }
    $batBody = $batBody -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($batPath, $batBody, $utf8NoBom)

    if (-not $NoDesktopShortcuts) {
        $lnkPath = Join-Path $desktopDir "AG_$display.lnk"
        $sc = $ws.CreateShortcut($lnkPath)
        $sc.TargetPath = "$env:SystemRoot\System32\cmd.exe"
        $sc.Arguments = "/c `"$batPath`""
        $sc.WorkingDirectory = $InstallDir
        if (Test-Path -LiteralPath $agExe) {
            $sc.IconLocation = "$agExe,0"
        }
        $sc.WindowStyle = 1
        $sc.Description = "Antigravity (Profile $p)"
        $sc.Save()

        if (-not $NoAdmin) {
            $bytes = [System.IO.File]::ReadAllBytes($lnkPath)
            $bytes[0x15] = $bytes[0x15] -bor 0x20 # MS-SHLLINK RunAsUser (0x00002000)
            [System.IO.File]::WriteAllBytes($lnkPath, $bytes)
        }
    }
}

Write-Host "[OK] Installed Switch-AG.ps1 and profiles ($($Profiles -join ', ')) into $InstallDir" -ForegroundColor Green
powershell -NoProfile -ExecutionPolicy Bypass -File $dstSwitch -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File $dstSwitch -Status
