# Antigravity Account Switcher (Windows)

Lightweight PowerShell + `.bat` / `.lnk` profile switcher for **Google Antigravity IDE** on Windows.  
Lets you rotate between multiple Google accounts (e.g., `acc1`, `acc2`, `acc3`) without re-entering browser credentials every time, while **preserving your shared chats, brain artifacts, MCP servers, and skills** (`%USERPROFILE%\.gemini\antigravity`).

---

## How It Works

Antigravity splits its runtime state across three locations on Windows:

| Component | Path / Storage | Shared vs Isolated |
| :--- | :--- | :--- |
| **Conversations, Brain, Skills, MCP** | `%USERPROFILE%\.gemini\antigravity` | **Shared** across all accounts (so you can continue the same chat after switching accounts) |
| **Electron UI & Browser State** | `--user-data-dir="<BaseDir>\<profile>\userdata"` | **Isolated** per profile (`app_storage.json`, `Local State`, `window_state.json`, `Cookies`, `Cache`) |
| **OAuth Token & User Scope** | Windows Credential Manager (`gemini:antigravity`) + `%APPDATA%\Antigravity\credential-user-scope` | **Swapped** on switch via DPAPI (`DataProtectionScope.CurrentUser`) into `<BaseDir>\<profile>\cred.dpapi` |

> **Why isolated Firefox profiles pair well with this:**  
> Keep one dedicated Firefox profile per Google account for the initial `Sign In` OAuth flow. Once signed in, `Switch-AG.ps1` stores the DPAPI-encrypted refresh token locally per profile, so switching accounts never opens the browser again and avoids repeated Google anti-fraud checks across VPN IP changes.

---

## Features

* **DPAPI-Protected Token Vault (`cred.dpapi` + `cred.dpapi.bak`):** Encrypts `gemini:antigravity` using `System.Security.Cryptography.ProtectedData` (`CurrentUser`) and creates a backup before overwriting.
* **Email Ownership Guard:** Before saving the live token back to the previous profile, verifies in memory that `id_token_email` matches the profile's stored account (`agy.onboarding.lastLoginUsername` / `cred.dpapi`). Prevents accidental token overwrite if Antigravity was launched outside the switcher (e.g., after an auto-update).
* **Automatic Per-Version Backups:** When `Antigravity.exe` updates to a new version, snapshots all profiles' `cred.dpapi` and `credential-user-scope` into `_backup_versions\<timestamp>_to_<version>\`.
* **Detached Launcher (`CreateProcessW`):** Spawns `Antigravity.exe` detached (`DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP`) so closing the launcher console does not kill the IDE.
* **Single-Instance Mutex (`Local\AG_Profiles_Switch_Mutex`):** Prevents race conditions if two shortcuts are clicked at once.
* **Admin Support & Shortcuts:** `Install-Profiles.ps1` creates `.bat` launchers and Desktop `.lnk` shortcuts with the official `Antigravity.exe` icon and `RunAsUser` (`0x2000`) UAC elevation.

---

## Quick Start (Human Users)

1. Clone or download this repository (for example, to `C:\AG_Profiles` or a temporary folder).
2. Run the installer in PowerShell:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install-Profiles.ps1" -InstallDir "C:\AG_Profiles" -Profiles acc1,acc2,acc3
   ```
3. **Important:** Remove or stop using the default `Antigravity` Desktop shortcut (which launches without `--user-data-dir`). Always launch via `AG_Acc1.lnk`, `AG_Acc2.lnk`, etc.
4. For each new profile:
   * Open **only** the corresponding isolated Firefox profile (logged into that Google account).
   * Launch `AG_Acc1.lnk` -> click **Sign In** -> authorize in Firefox.
   * On the next profile switch (or relaunch), `Switch-AG.ps1` automatically saves the token into `C:\AG_Profiles\acc1\cred.dpapi`.

---

## CLI Reference (`Switch-AG.ps1`)

```powershell
# Switch to / launch profile "acc2"
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\AG_Profiles\Switch-AG.ps1" -Profile "acc2"

# Read-only diagnostics (active profile, live credential, running --user-data-dir, email match)
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\AG_Profiles\Switch-AG.ps1" -Status

# Non-destructive DPAPI & Windows Credential Manager roundtrip test (uses "gemini:antigravity-selftest")
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\AG_Profiles\Switch-AG.ps1" -SelfTest

# Reset saved session for a specific profile (backs up to cred.dpapi.bak first)
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\AG_Profiles\Switch-AG.ps1" -Profile "acc1" -ResetProfile
```

---

## 🤖 Instructions for AI Agents (Automated Setup & Diagnostics)

If a user asks you (an AI coding agent) to install, configure, audit, or troubleshoot this switcher on Windows, follow this exact protocol.

### 1. Safety & Security Rules (Mandatory)
* **NEVER** print, log, or commit `cred.dpapi`, `cred.dpapi.bak`, `credential-user-scope`, `id_token_email`, `agy.onboarding.lastLoginUsername`, or raw `gemini:antigravity` credential blobs.
* **NEVER** run `git init` inside an active `C:\AG_Profiles` directory that already contains `cred.dpapi` / `userdata` unless `.gitignore` is verified first; prefer staging clean code in a separate directory.
* **NEVER** modify `cred.dpapi` or `active_profile.txt` while `Antigravity` or `language_server` processes are running.
* **Use read-only checks first:** Run `Switch-AG.ps1 -Status` and `Switch-AG.ps1 -SelfTest` before modifying anything.

### 2. Prerequisites Check
Verify in PowerShell:
```powershell
Test-Path "$env:LOCALAPPDATA\Programs\antigravity\Antigravity.exe"
$PSVersionTable.PSVersion
```
* Target OS: Windows 10/11 (uses `advapi32.dll` `CredRead`/`CredWrite`/`CredDelete` and .NET `System.Security.Cryptography.ProtectedData` with `DataProtectionScope.CurrentUser`).
* All profiles using the switcher **must** run under the same Windows user SID (DPAPI `CurrentUser` is bound to the Windows user account).

### 3. Automated Installation
Clone or copy the repo files into a clean install directory (default `C:\AG_Profiles`), then run `Install-Profiles.ps1`:

```powershell
git clone https://github.com/Aldiyuar/antigravity-account-switcher.git "$env:TEMP\ag-switcher-src"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\ag-switcher-src\Install-Profiles.ps1" -InstallDir "C:\AG_Profiles" -Profiles acc1,acc2,acc3
```

Parameters for `Install-Profiles.ps1`:
* `-InstallDir <path>`: Target directory where `Switch-AG.ps1`, `.bat` launchers, and `<profile>\userdata` folders live (default: `C:\AG_Profiles`). Note: `Switch-AG.ps1` uses `$PSScriptRoot` as `$BaseDir`, so it is portable to any directory.
* `-Profiles <string[]>`: Profile names matching `^[A-Za-z0-9_-]+$` (default: `acc1`, `acc2`, `acc3`).
* `-NoAdmin`: Omit UAC self-elevation from `.bat` files and `RunAsUser` bit (`0x2000`) from `.lnk` shortcuts. (Default elevates both `.bat` and `.lnk`.)
* `-NoDesktopShortcuts`: Skip creating `.lnk` files on the user's Desktop.

### 4. Verification After Install
Always run both checks after installation or edits:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\AG_Profiles\Switch-AG.ps1" -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\AG_Profiles\Switch-AG.ps1" -Status
```
Expected `-SelfTest` output:
```text
SELFTEST_ROUNDTRIP=True BackupCreated=True PreserveOnMissing=True EmailGuard=True BlobSize=28 Type=1 Persist=2
```

### 5. Migrating an Existing Logged-In Antigravity Session into `acc1` (Optional)
If the user already uses Antigravity with the default `%APPDATA%\Antigravity` directory and wants to preserve that session as `acc1` without signing in again:
1. Ensure `Antigravity` and `language_server` are completely closed.
2. Copy `%APPDATA%\Antigravity\*` into `C:\AG_Profiles\acc1\userdata\` (skipping lockfiles if any).
3. Copy `%APPDATA%\Antigravity\credential-user-scope` (if present) into `C:\AG_Profiles\acc1\credential-user-scope`.
4. Set `C:\AG_Profiles\active_profile.txt` to `acc1` (UTF-8 without BOM), then run `Switch-AG.ps1 -Profile "acc2"` (or `-Profile "acc1"`) so `Switch-AG.ps1` saves the live `gemini:antigravity` credential into `acc1\cred.dpapi`.

### 6. Integrating with UI Mod Patchers & Post-Update Restarts
If the user uses a UI mod patcher (such as `Apply_AG_UI_Mods.bat` or similar `app.asar` patchers) that closes and restarts Antigravity:
* **Do NOT** let the patcher restart bare `%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe` without `--user-data-dir`. That launches `%APPDATA%\Antigravity` instead of the active profile.
* Instead, have the restart step read `C:\AG_Profiles\active_profile.txt` and invoke:
  ```bat
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\AG_Profiles\Switch-AG.ps1" -Profile "%ACTIVE_PROFILE%"
  ```
* Likewise, when Antigravity's built-in auto-updater runs `--updated --force-run`, it relaunches without `--user-data-dir`. Advise the user to close that window and launch via `AG_Acc*.lnk`.

### 7. Troubleshooting Guide for Agents

| Symptom / `-Status` Output | Cause | Fix |
| :--- | :--- | :--- |
| `[WARN] Antigravity запущен БЕЗ --user-data-dir` | IDE was opened from a default shortcut, file association, or post-update auto-relaunch | Close IDE and launch via `AG_Acc*.lnk`. `Switch-AG.ps1` email guard protects saved `cred.dpapi` from mismatching accounts. |
| `cred: NEW` on a profile | First-time setup (no `cred.dpapi` saved yet) | Launch profile via `AG_Acc*.lnk`, open only that account's Firefox profile, click **Sign In**, then close/switch once to persist `cred.dpapi`. |
| `cred: BAK ONLY` | `cred.dpapi` is missing while `cred.dpapi.bak` exists | Inspect `-Status`; if the backup belongs to that profile, copy `cred.dpapi.bak` -> `cred.dpapi` (only when IDE is closed). |
| `match: MISMATCH` | Email in `cred.dpapi` differs from `userdata\app_storage.json` | Run `Switch-AG.ps1 -Profile <name> -ResetProfile` to re-authenticate cleanly, or check if `cred.dpapi` came from another account. |
| `language_server.log` shows `reason=ineligible ... valid=false` | Server-side rejection from `v1internal:loadCodeAssist` (VPN/geo/account eligibility) | Check VPN IP/region, open the account's Firefox profile, sign in again cleanly. |
| Drag-and-drop from Explorer doesn't work | IDE running elevated (Admin) while Explorer runs at Medium IL (UIPI) | Re-install with `Install-Profiles.ps1 -NoAdmin` if elevation is not needed. |
