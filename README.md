# PokerStarsLauncher

A small Windows application that starts PokerStars, Xeester, and StarsCaption in the same order and with the same concurrent startup behavior as the original launcher, then submits the PokerStars login form.

The public download is a **single self-installing executable**. Users do not need to extract an archive, run a batch file, open PowerShell, install Go, or edit scripts.

## Download and install

1. Open [Releases](../../releases).
2. Download **`PokerStarsLauncher.exe`** from the latest release Assets.
3. Run the downloaded file. On first run, it copies itself to `%LOCALAPPDATA%\Programs\PokerStarsLauncher`, installs its internal components, and opens the setup window.
4. Enter your PokerStars username and password. Confirm or change the three application paths. The password field is masked.
5. Select **Save**. Setup creates a Desktop shortcut and Start Menu entries.
6. Delete the downloaded copy if you wish. The installed copy is now under your Windows profile.

The application is installed per user and does not need administrator permission to install. Administrator approval is requested when the Desktop shortcut starts the three applications. The first public builds are unsigned, so Windows SmartScreen may show an unrecognized-app warning until the executable has an established reputation or is signed.

## First-run configuration

The setup window pre-fills these conventional paths and lets you confirm them or browse to different executables:

| Application | Default executable |
|---|---|
| PokerStars updater | `C:\Program Files (x86)\PokerStars\PokerStarsUpdate.exe` |
| Xeester updater | `C:\Program Files (x86)\Xeester\xeester-update.exe` |
| StarsCaption | `C:\StarsCaption\StarsCaption.exe` |

The password is stored separately from configuration using Windows DPAPI in the current Windows user context. Configuration and credentials are kept under `%APPDATA%\PokerStarsLauncher`; logs are under `%LOCALAPPDATA%\PokerStarsLauncher\logs`. They are not stored in the application installation directory or committed to Git.

The setup wizard is available later from **Start Menu → PokerStarsLauncher → Configure PokerStarsLauncher**. Enter a new password to replace the saved one; leave the password blank to keep the existing value.

## Launch behavior

Close any existing PokerStars process first, then use the Desktop shortcut or the Start Menu launcher. The launcher refuses to start if `PokerStars.exe` is already running, because login automation must target the process created by that launch. Windows shows one UAC prompt. After approval, the application:

1. Starts `PokerStarsUpdate.exe`.
2. Starts `xeester-update.exe`.
3. Starts `StarsCaption.exe`.
4. Waits for the real PokerStars login form, fills its native username and password controls, and sends the confirmed parent-dialog `WM_COMMAND / BN_CLICKED` notification.

The three applications are started in that order without waiting for one updater to finish before starting the next. Login-form detection waits up to 180 seconds. After the Login notification, the original login dialog must disappear within 30 seconds. This confirms that the dialog accepted the submission; it does not independently prove that PokerStars authenticated the account.

If application startup or login submission fails, the launcher stops and terminates the processes started by that invocation, including their descendants. Processes that were already running before this launcher invocation are not placed in its Windows Job Object and are not terminated. Failure details are shown in a Windows dialog and written to `%LOCALAPPDATA%\PokerStarsLauncher\logs\launcher.log`.

The elevated process runs under the same Windows account that approved UAC. This is required because the password is protected with that account's DPAPI context.

## Updating

To update, download the new `PokerStarsLauncher.exe` from the latest GitHub Release and run it. It replaces the installed application files under LocalAppData while preserving configuration and the encrypted password. The Desktop and Start Menu shortcuts continue to point to the same installed path.

## Uninstalling

Open **Settings → Apps → Installed apps → PokerStarsLauncher → Uninstall**. The uninstaller asks whether to also remove the saved username, executable paths, and encrypted password. Choosing **No** removes the application but keeps those settings for a later reinstall. Choosing **Yes** removes them as well.

## Requirements

- Windows 10 or Windows 11, x64.
- PokerStars, Xeester, and StarsCaption already installed.
- Windows PowerShell 5.1, included with Windows.
- A Windows account permitted to approve the UAC prompt.

No Go installation, Inno Setup, separate .NET runtime, or third-party launcher dependency is required on the user's PC.

## Project development

The EXE is a Go Windows GUI executable. The working PowerShell implementation is embedded into it at build time and extracted into the per-user application directory at runtime. It is not a PowerShell rewrite of the existing PokerStars native login automation.

Build locally from a Windows or cross-compiling Go environment:

```powershell
go test ./...
$env:GOOS = 'windows'
$env:GOARCH = 'amd64'
go build -trimpath -ldflags '-s -w -H=windowsgui -X main.version=0.1.0-dev' -o PokerStarsLauncher.exe .
```

The Release Please workflow creates the release and, in a dependent Windows job in that same workflow run, builds the executable and attaches it to that GitHub Release. This avoids relying on a tag-push event created by the workflow token to trigger a separate workflow. The repository retains the `proinit` scaffold/workflow/commit conventions: Conventional Commits, Commitizen, Lefthook, Gitleaks, merge-safety checks, and Release Please. It does not create or push a remote as part of local project setup.

## License and affiliation

MIT. This project is not affiliated with, endorsed by, or supported by PokerStars, Xeester, or StarsCaption.
