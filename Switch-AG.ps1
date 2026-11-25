param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Profile,

    [switch]$SelfTest,
    [switch]$Status,
    [switch]$ResetProfile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Security

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class AgCredStore {
    private const uint CRED_TYPE_GENERIC = 1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredRead(string target, uint type, int flags, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredWrite(ref CREDENTIAL userCredential, uint flags);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredDelete(string target, uint type, int flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    public class CredData {
        public uint Type;
        public uint Persist;
        public string UserName;
        public byte[] Blob;
    }

    public static CredData Read(string target) {
        IntPtr ptr;
        if (!CredRead(target, CRED_TYPE_GENERIC, 0, out ptr)) {
            int err = Marshal.GetLastWin32Error();
            if (err == 1168) return null; // ERROR_NOT_FOUND
            throw new System.ComponentModel.Win32Exception(err);
        }
        try {
            var c = Marshal.PtrToStructure<CREDENTIAL>(ptr);
            byte[] blob = new byte[c.CredentialBlobSize];
            if (c.CredentialBlobSize > 0 && c.CredentialBlob != IntPtr.Zero) {
                Marshal.Copy(c.CredentialBlob, blob, 0, (int)c.CredentialBlobSize);
            }
            return new CredData {
                Type = c.Type,
                Persist = c.Persist,
                UserName = c.UserName ?? "antigravity",
                Blob = blob
            };
        } finally {
            CredFree(ptr);
        }
    }

    public static void Write(string target, string userName, uint type, uint persist, byte[] blob) {
        if (blob == null) {
            blob = new byte[0];
        }
        IntPtr blobPtr = IntPtr.Zero;
        try {
            if (blob.Length > 0) {
                blobPtr = Marshal.AllocHGlobal(blob.Length);
                Marshal.Copy(blob, 0, blobPtr, blob.Length);
            }
            var c = new CREDENTIAL {
                Flags = 0,
                Type = type == 0 ? CRED_TYPE_GENERIC : type,
                TargetName = target,
                Comment = null,
                CredentialBlobSize = (uint)blob.Length,
                CredentialBlob = blobPtr,
                Persist = persist == 0 ? 2u : persist,
                AttributeCount = 0,
                Attributes = IntPtr.Zero,
                TargetAlias = null,
                UserName = string.IsNullOrEmpty(userName) ? "antigravity" : userName
            };
            if (!CredWrite(ref c, 0)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
        } finally {
            if (blobPtr != IntPtr.Zero) {
                Marshal.FreeHGlobal(blobPtr);
            }
        }
    }

    public static void Delete(string target) {
        if (!CredDelete(target, CRED_TYPE_GENERIC, 0)) {
            int err = Marshal.GetLastWin32Error();
            if (err == 1168) return; // ERROR_NOT_FOUND
            throw new System.ComponentModel.Win32Exception(err);
        }
    }
}

public static class AgLauncher {
    private const uint DETACHED_PROCESS = 0x00000008;
    private const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
    private const uint ATTACH_PARENT_PROCESS = 0xFFFFFFFF;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public uint cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(
        string lpApplicationName,
        System.Text.StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    public static void StartDetached(string exePath, string arguments) {
        var si = new STARTUPINFO();
        si.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
        var cmd = new System.Text.StringBuilder("\"" + exePath + "\" " + arguments);
        string workDir = System.IO.Path.GetDirectoryName(exePath);

        // Detach from the launcher console before spawning so Electron/language_server cannot inherit or attach to it.
        FreeConsole();
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(
            exePath,
            cmd,
            IntPtr.Zero,
            IntPtr.Zero,
            false,
            DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
            IntPtr.Zero,
            workDir,
            ref si,
            out pi
        )) {
            int err = Marshal.GetLastWin32Error();
            AttachConsole(ATTACH_PARENT_PROCESS);
            throw new System.ComponentModel.Win32Exception(err);
        }
        if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
        if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
    }
}
"@

function Save-CredentialToFile {
    param([string]$TargetName, [string]$OutFile)
    $cred = [AgCredStore]::Read($TargetName)
    if ($null -eq $cred -or $null -eq $cred.Blob -or $cred.Blob.Length -eq 0) {
        return $false
    }
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $cred.Blob,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $obj = [ordered]@{
        Type                = $cred.Type
        Persist             = $cred.Persist
        UserName            = $cred.UserName
        ProtectedBlobBase64 = [Convert]::ToBase64String($protected)
        SavedAt             = (Get-Date).ToString("o")
    }
    $tmp = "$OutFile.tmp"
    $json = $obj | ConvertTo-Json
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $OutFile) {
        Copy-Item -LiteralPath $OutFile -Destination "$OutFile.bak" -Force
    }
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    return $true
}

function Restore-CredentialFromFile {
    param([string]$TargetName, [string]$InFile)
    $raw = Get-Content -LiteralPath $InFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Файл учётных данных пуст: $InFile"
    }
    $obj = $raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($obj.ProtectedBlobBase64)) {
        throw "В файле учётных данных отсутствует ProtectedBlobBase64: $InFile"
    }
    $protected = [Convert]::FromBase64String($obj.ProtectedBlobBase64)
    $blob = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    if ($null -eq $blob -or $blob.Length -eq 0) {
        throw "Расшифрованный токен пуст: $InFile"
    }
    [AgCredStore]::Write($TargetName, $obj.UserName, [uint32]$obj.Type, [uint32]$obj.Persist, $blob)
}

function Read-ActiveProfileName {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $raw) {
        return $null
    }
    return $raw.Trim([char]0xFEFF, ' ', "`t", "`r", "`n")
}

function Get-EmailFromCredBlob {
    param([byte[]]$Blob)
    if ($null -eq $Blob -or $Blob.Length -eq 0) {
        return $null
    }
    try {
        $jsonText = [System.Text.Encoding]::UTF8.GetString($Blob)
        $parsed = $jsonText | ConvertFrom-Json
        if ($null -ne $parsed -and -not [string]::IsNullOrWhiteSpace($parsed.id_token_email)) {
            return $parsed.id_token_email.Trim().ToLowerInvariant()
        }
    } catch {
        # Non-JSON or malformed credential blob
    }
    return $null
}

function Get-EmailFromCredFile {
    param([string]$CredFile)
    if (-not (Test-Path -LiteralPath $CredFile)) {
        return $null
    }
    try {
        $raw = Get-Content -LiteralPath $CredFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($obj.ProtectedBlobBase64)) { return $null }
        $protected = [Convert]::FromBase64String($obj.ProtectedBlobBase64)
        $blob = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return (Get-EmailFromCredBlob -Blob $blob)
    } catch {
        return $null
    }
}

function Get-EmailFromAppStorage {
    param([string]$ProfileDir)
    $appStorage = Join-Path (Join-Path $ProfileDir "userdata") "app_storage.json"
    if (-not (Test-Path -LiteralPath $appStorage)) {
        return $null
    }
    try {
        $raw = Get-Content -LiteralPath $appStorage -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw | ConvertFrom-Json
        $prop = $obj.PSObject.Properties["agy.onboarding.lastLoginUsername"]
        if ($null -ne $prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            return ([string]$prop.Value).Trim().ToLowerInvariant()
        }
    } catch {
        return $null
    }
    return $null
}

function Get-ProfileExpectedEmail {
    param([string]$ProfileDir)
    $fromCred = Get-EmailFromCredFile -CredFile (Join-Path $ProfileDir "cred.dpapi")
    if (-not [string]::IsNullOrWhiteSpace($fromCred)) {
        return $fromCred
    }
    return (Get-EmailFromAppStorage -ProfileDir $ProfileDir)
}

function Get-AntigravityVersion {
    param([string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) {
        return "unknown"
    }
    try {
        $vi = (Get-Item -LiteralPath $ExePath).VersionInfo
        $ver = if (-not [string]::IsNullOrWhiteSpace($vi.FileVersion)) { $vi.FileVersion } else { $vi.ProductVersion }
        if (-not [string]::IsNullOrWhiteSpace($ver)) {
            return ($ver.Trim() -replace '[^A-Za-z0-9._-]', '_')
        }
    } catch {
        # Fallback below
    }
    return "unknown"
}

function Backup-ProfilesOnVersionChange {
    param([string]$BaseDir, [string]$ExePath)
    $currentVer = Get-AntigravityVersion -ExePath $ExePath
    $verFile = Join-Path $BaseDir "last_ag_version.txt"
    $prevVer = Read-ActiveProfileName -Path $verFile
    if ($prevVer -eq $currentVer) {
        return
    }
    $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $backupRoot = Join-Path (Join-Path $BaseDir "_backup_versions") "${stamp}_to_${currentVer}"
    $dirs = @(Get-ChildItem -LiteralPath $BaseDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "_*" })
    $copiedAny = $false
    foreach ($d in $dirs) {
        foreach ($fname in @("cred.dpapi", "cred.dpapi.bak", "credential-user-scope")) {
            $src = Join-Path $d.FullName $fname
            if (Test-Path -LiteralPath $src) {
                $dstDir = Join-Path $backupRoot $d.Name
                New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
                Copy-Item -LiteralPath $src -Destination (Join-Path $dstDir $fname) -Force
                $copiedAny = $true
            }
        }
    }
    [System.IO.File]::WriteAllText($verFile, $currentVer, [System.Text.UTF8Encoding]::new($false))
    if ($copiedAny -and -not [string]::IsNullOrWhiteSpace($prevVer)) {
        Write-Host "[INFO] Обнаружено обновление Antigravity ($prevVer -> $currentVer). Сделан бэкап токенов всех профилей в $backupRoot" -ForegroundColor Cyan
    }
}

$CredTarget = "gemini:antigravity"
$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { "C:\AG_Profiles" }
$ActiveFile = Join-Path $BaseDir "active_profile.txt"
$AppRoamingDir = Join-Path $env:APPDATA "Antigravity"
$LiveScopeFile = Join-Path $AppRoamingDir "credential-user-scope"
$AgExe = Join-Path $env:LOCALAPPDATA "Programs\antigravity\Antigravity.exe"

if ($SelfTest) {
    $testTarget = "gemini:antigravity-selftest"
    $testFile = Join-Path $env:TEMP "ag_cred_selftest.dpapi"
    try {
        $sample1 = [Text.Encoding]::UTF8.GetBytes("selftest-payload-1234567890")
        [AgCredStore]::Write($testTarget, "antigravity", 1, 2, $sample1)
        $saved1 = Save-CredentialToFile -TargetName $testTarget -OutFile $testFile
        if (-not $saved1) { throw "Save-CredentialToFile (1) returned false" }

        $sample2 = [Text.Encoding]::UTF8.GetBytes("selftest-payload-updated-999")
        [AgCredStore]::Write($testTarget, "antigravity", 1, 2, $sample2)
        $saved2 = Save-CredentialToFile -TargetName $testTarget -OutFile $testFile
        if (-not $saved2) { throw "Save-CredentialToFile (2) returned false" }
        if (-not (Test-Path -LiteralPath "$testFile.bak")) { throw "Backup .bak was not created on overwrite" }

        [AgCredStore]::Delete($testTarget)
        if ($null -ne [AgCredStore]::Read($testTarget)) { throw "Delete failed" }

        # Saving when live cred is missing must return false and preserve existing file
        $savedMissing = Save-CredentialToFile -TargetName $testTarget -OutFile $testFile
        if ($savedMissing) { throw "Save-CredentialToFile should return false when target is missing" }
        if (-not (Test-Path -LiteralPath $testFile)) { throw "Existing file was lost when live cred was missing" }

        Restore-CredentialFromFile -TargetName $testTarget -InFile $testFile
        $restored = [AgCredStore]::Read($testTarget)
        if ($null -eq $restored) { throw "Read after restore returned null" }
        $ok = ([Text.Encoding]::UTF8.GetString($restored.Blob) -eq "selftest-payload-updated-999")

        # Verify email extraction from DPAPI cred file for ownership guard
        $jsonSample = [Text.Encoding]::UTF8.GetBytes('{"id_token_email":"User1@Example.Test","token":{"access_token":"x"}}')
        [AgCredStore]::Write($testTarget, "antigravity", 1, 2, $jsonSample)
        if (-not (Save-CredentialToFile -TargetName $testTarget -OutFile $testFile)) { throw "Save JSON sample failed" }
        $extractedLive = Get-EmailFromCredBlob -Blob ([AgCredStore]::Read($testTarget)).Blob
        $extractedFile = Get-EmailFromCredFile -CredFile $testFile
        $emailOk = ($extractedLive -eq "user1@example.test") -and ($extractedFile -eq "user1@example.test")
        if (-not $emailOk) { throw "Email extraction self-test failed" }

        Write-Output "SELFTEST_ROUNDTRIP=$ok BackupCreated=True PreserveOnMissing=True EmailGuard=$emailOk BlobSize=$($restored.Blob.Length) Type=$($restored.Type) Persist=$($restored.Persist)"
    } finally {
        [AgCredStore]::Delete($testTarget)
        Remove-Item -LiteralPath $testFile, "$testFile.bak", "$testFile.tmp" -ErrorAction SilentlyContinue
    }
    exit 0
}

if ($Status) {
    $active = Read-ActiveProfileName -Path $ActiveFile
    $liveCred = [AgCredStore]::Read($CredTarget)
    $hasLiveScope = Test-Path -LiteralPath $LiveScopeFile
    $running = @(Get-Process -Name "Antigravity", "language_server" -ErrorAction SilentlyContinue)

    Write-Host "=== Antigravity Profiles Status ===" -ForegroundColor Cyan
    Write-Host ("AG version     : {0}" -f (Get-AntigravityVersion -ExePath $AgExe))
    Write-Host ("Active profile : {0}" -f ($(if ($active) { $active } else { "<none>" })))
    if ($null -ne $liveCred) {
        Write-Host ("Live cred      : OK (BlobSize={0}, Type={1}, Persist={2})" -f $liveCred.Blob.Length, $liveCred.Type, $liveCred.Persist) -ForegroundColor Green
    } else {
        Write-Host "Live cred      : MISSING" -ForegroundColor Yellow
    }
    Write-Host ("Live scope     : {0}" -f ($(if ($hasLiveScope) { "OK" } else { "MISSING" })))
    Write-Host ("Running procs  : {0}" -f $running.Count)

    if ($running.Count -gt 0) {
        try {
            $mainProcs = @(Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' -and $_.CommandLine -notmatch '--import=' })
            foreach ($p in $mainProcs) {
                if ($p.CommandLine -match '--user-data-dir="([^"]+)"' -or $p.CommandLine -match '--user-data-dir=(\S+)') {
                    $runningDir = $Matches[1]
                    Write-Host ("Running dataDir: {0}" -f $runningDir)
                    if ($active -and ($runningDir -notlike "*\$active\userdata")) {
                        Write-Host "[WARN] Запущенный --user-data-dir не совпадает с active_profile.txt ('$active')!" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "[WARN] Antigravity запущен БЕЗ --user-data-dir (дефолтный %APPDATA%\Antigravity)!" -ForegroundColor Yellow
                }
            }
        } catch {
            # Non-fatal diagnostic check
        }
    }

    Write-Host ""
    Write-Host "Profiles in ${BaseDir}:" -ForegroundColor Cyan
    $dirs = @(Get-ChildItem -LiteralPath $BaseDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "_*" } |
        Sort-Object Name)

    foreach ($d in $dirs) {
        $pName = $d.Name
        $marker = if ($pName -eq $active) { "*" } else { " " }
        $credPath = Join-Path $d.FullName "cred.dpapi"
        $bakPath = "$credPath.bak"
        $scopePath = Join-Path $d.FullName "credential-user-scope"
        $udPath = Join-Path $d.FullName "userdata"

        $credState = "NEW"
        if (Test-Path -LiteralPath $credPath) {
            try {
                $meta = Get-Content -LiteralPath $credPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $savedAt = if ($meta.SavedAt) { $meta.SavedAt } else { "unknown" }
                $credState = "OK ($savedAt)"
            } catch {
                $credState = "CORRUPT"
            }
        } elseif (Test-Path -LiteralPath $bakPath) {
            $credState = "BAK ONLY"
        }

        $scopeState = if (Test-Path -LiteralPath $scopePath) { "OK" } else { "missing" }
        $udHasFiles = (Test-Path -LiteralPath $udPath) -and (@(Get-ChildItem -LiteralPath $udPath -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0)
        $udState = if ($udHasFiles) { "OK" } else { "empty" }

        $credEmail = Get-EmailFromCredFile -CredFile $credPath
        $appEmail = Get-EmailFromAppStorage -ProfileDir $d.FullName
        $matchState = "n/a"
        if ($credEmail -and $appEmail) {
            $matchState = if ($credEmail -eq $appEmail) { "OK" } else { "MISMATCH" }
        }

        Write-Host ("  {0} {1,-10} | cred: {2,-38} | scope: {3,-7} | userdata: {4,-5} | match: {5}" -f $marker, $pName, $credState, $scopeState, $udState, $matchState)
    }
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Profile) -or ($Profile -notmatch '^[A-Za-z0-9_-]+$')) {
    Write-Host "[ERR] Не указан корректный параметр -Profile." -ForegroundColor Red
    Write-Host "      Примеры: Switch-AG.ps1 -Profile acc2 | Switch-AG.ps1 -Status | Switch-AG.ps1 -SelfTest"
    exit 1
}

if (-not (Test-Path -LiteralPath $AgExe)) {
    Write-Host "[ERR] Не найден Antigravity.exe: $AgExe" -ForegroundColor Red
    exit 1
}

$ProfileDir = Join-Path $BaseDir $Profile
$UserDataDir = Join-Path $ProfileDir "userdata"

$mutexName = "Local\AG_Profiles_Switch_Mutex"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)
$lockAcquired = $false

try {
    try {
        $lockAcquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $lockAcquired = $true
    }

    if (-not $lockAcquired) {
        Write-Host "[ERR] Другой экземпляр Switch-AG.ps1 уже выполняется. Дождись его завершения." -ForegroundColor Red
        exit 1
    }

    # 1. Wait until Antigravity and language_server are fully closed
    $running = @(Get-Process -Name "Antigravity", "language_server" -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Host ""
        Write-Host "[!] Antigravity сейчас запущен (найдено процессов: $($running.Count))." -ForegroundColor Yellow
        Write-Host "    Закрой окно Antigravity — переключение продолжится автоматически."
        Write-Host "    (Чтобы отменить, просто закрой это окно консоли.)"
        while (Get-Process -Name "Antigravity", "language_server" -ErrorAction SilentlyContinue) {
            Start-Sleep -Milliseconds 400
        }
        # Brief grace window so SQLite and Credential Manager finish flushing
        Start-Sleep -Milliseconds 500
        Write-Host "[OK] Процессы Antigravity завершены." -ForegroundColor Green
    }

    # 1.5. Backup all saved profile credentials automatically when Antigravity updates
    Backup-ProfilesOnVersionChange -BaseDir $BaseDir -ExePath $AgExe

    # 2. Save currently loaded profile's live credential and scope before switching
    $prevProfile = Read-ActiveProfileName -Path $ActiveFile
    if (-not [string]::IsNullOrWhiteSpace($prevProfile)) {
        if ($prevProfile -match '^[A-Za-z0-9_-]+$') {
            $prevDir = Join-Path $BaseDir $prevProfile
            New-Item -ItemType Directory -Path $prevDir -Force | Out-Null
            $prevCredFile = Join-Path $prevDir "cred.dpapi"
            $prevScopeFile = Join-Path $prevDir "credential-user-scope"

            $liveCred = [AgCredStore]::Read($CredTarget)
            $liveEmail = if ($null -ne $liveCred) { Get-EmailFromCredBlob -Blob $liveCred.Blob } else { $null }
            $expectedEmail = Get-ProfileExpectedEmail -ProfileDir $prevDir

            if (-not [string]::IsNullOrWhiteSpace($liveEmail) -and -not [string]::IsNullOrWhiteSpace($expectedEmail) -and ($liveEmail -ne $expectedEmail)) {
                Write-Host "[WARN] Живой токен в Credential Manager не совпадает с аккаунтом '$prevProfile' (возможно, IDE запускалась мимо батника — например, после автообновления). Сохранение пропущено, чтобы не перезаписать токен '$prevProfile'." -ForegroundColor Yellow
            } else {
                $saved = Save-CredentialToFile -TargetName $CredTarget -OutFile $prevCredFile
                if ($saved) {
                    if (Test-Path -LiteralPath $LiveScopeFile) {
                        Copy-Item -LiteralPath $LiveScopeFile -Destination $prevScopeFile -Force
                    }
                } elseif (Test-Path -LiteralPath $prevCredFile) {
                    # Do not destroy an existing saved token if the live store was empty
                    Write-Host "[WARN] Живой токен для '$prevProfile' не найден в Credential Manager. Существующий cred.dpapi сохранён без изменений." -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "[WARN] Некорректное имя профиля в active_profile.txt ('$prevProfile'). Сохранение предыдущего профиля пропущено." -ForegroundColor Yellow
        }
    }

    # 3. Prepare and load target profile
    New-Item -ItemType Directory -Path $UserDataDir -Force | Out-Null
    New-Item -ItemType Directory -Path $AppRoamingDir -Force | Out-Null

    $targetCredFile = Join-Path $ProfileDir "cred.dpapi"
    $targetScopeFile = Join-Path $ProfileDir "credential-user-scope"

    if ($ResetProfile) {
        if (Test-Path -LiteralPath $targetCredFile) {
            Copy-Item -LiteralPath $targetCredFile -Destination "$targetCredFile.bak" -Force
            Remove-Item -LiteralPath $targetCredFile -Force
        }
        if (Test-Path -LiteralPath $targetScopeFile) {
            Remove-Item -LiteralPath $targetScopeFile -Force
        }
        Write-Host "[INFO] Сохранённая сессия профиля '$Profile' сброшена (бэкап в cred.dpapi.bak)." -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $targetCredFile) {
        Restore-CredentialFromFile -TargetName $CredTarget -InFile $targetCredFile
        if (Test-Path -LiteralPath $targetScopeFile) {
            Copy-Item -LiteralPath $targetScopeFile -Destination $LiveScopeFile -Force
        } elseif (Test-Path -LiteralPath $LiveScopeFile) {
            Write-Host "[WARN] Для '$Profile' отсутствует credential-user-scope; очищаем старый live scope." -ForegroundColor Yellow
            Remove-Item -LiteralPath $LiveScopeFile -Force
        }
        [System.IO.File]::WriteAllText($ActiveFile, $Profile, [System.Text.UTF8Encoding]::new($false))
        Write-Host "[OK] Профиль '$Profile' активирован (сессия восстановлена)." -ForegroundColor Green
    } else {
        if (Test-Path -LiteralPath "$targetCredFile.bak") {
            Write-Host "[WARN] Для '$Profile' отсутствует cred.dpapi, но найден cred.dpapi.bak (вход начнётся как для нового профиля)." -ForegroundColor Yellow
        }
        [AgCredStore]::Delete($CredTarget)
        if (Test-Path -LiteralPath $LiveScopeFile) {
            Remove-Item -LiteralPath $LiveScopeFile -Force
        }
        [System.IO.File]::WriteAllText($ActiveFile, $Profile, [System.Text.UTF8Encoding]::new($false))
        Write-Host ""
        Write-Host "[NEW] Профиль '$Profile' подготовлен для первого входа." -ForegroundColor Cyan
        Write-Host "      1) Открой нужный профиль Firefox (убедись, что браузерный VPN выключен)."
        Write-Host "      2) Нажми Sign In в открывшемся Antigravity и подтверди вход."
        Write-Host "      После входа сессия сохранится автоматически для следующих запусков."
        Start-Sleep -Seconds 2
    }

    # 4. Launch Antigravity detached from the launcher console (shared %USERPROFILE%\.gemini)
    [AgLauncher]::StartDetached($AgExe, "--user-data-dir=`"$UserDataDir`"")
} finally {
    if ($lockAcquired) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
