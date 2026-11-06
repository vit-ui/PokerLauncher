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

Close any existing PokerStars process first, then use the Desktop shortcut or the Start Menu launcher. If `PokerStars.exe` is already running, the launcher shows an informational "PokerStars is already running" dialog. It explains that you can close PokerStars when ready and launch again, and that your current session has been left running. This expected condition does not show a failure screen or old diagnostic logs. Login automation must target the process created by that launch. Windows shows one UAC prompt. After approval, the application:

1. Starts `PokerStarsUpdate.exe`.
2. Starts `xeester-update.exe`.
3. Starts `StarsCaption.exe`.
4. Waits for the real PokerStars login form, fills its native username and password controls, and sends the confirmed parent-dialog `WM_COMMAND / BN_CLICKED` notification.

The three applications are started in that order without waiting for one updater to finish before starting the next. Updater exit codes are logged, and startup is confirmed by the actual applications: `PokerStars.exe`, Xeester's `jre\bin\xeester.exe`, and the configured StarsCaption executable. Each must match the expected executable path and belong to this invocation's Windows Job Object. A nonzero updater exit does not stop a confirmed application handoff. If an updater exits without its application, the launcher allows 30 seconds for the handoff before reporting a failure, including when the updater returned zero.

Login-form detection waits up to 180 seconds and targets only PokerStars in this invocation's process job. After the Login notification, the original login dialog must disappear within 30 seconds while PokerStars remains running. This confirms that the dialog accepted the submission; it does not independently prove that PokerStars authenticated the account. The controller also enforces a 240-second limit for application startup and login, so a stuck helper cannot leave it waiting indefinitely.

After an application has been confirmed started, closing it normally does not turn its updater handoff into a startup failure. Closing PokerStars during pending login stops login automation and leaves the other applications alone. Genuine startup failures and application crashes still stop the launch and terminate processes owned by that invocation. Processes that were already running are not placed in its Windows Job Object and are not terminated. Error dialogs show a short explanation and next step. Technical details stay in the log files under `%LOCALAPPDATA%\PokerStarsLauncher\logs`.

The elevated process runs under the same Windows account that approved UAC. This is required because the password is protected with that account's DPAPI context.

## Updating

To update, download the new `PokerStarsLauncher.exe` from the latest GitHub Release and run it. It replaces the installed application files, refreshes shortcuts and the Windows Apps version entry, and then confirms the installed version. Configuration and the encrypted password are preserved; uninstalling first is unnecessary. Updating does not launch the poker applications. Use the Desktop or Start Menu shortcut when ready to launch.

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

The Release Please workflow first calls the complete merge-safety workflow, including workflow linting, secret scanning, Go checks, and Windows runtime validation. Only after those checks pass can Release Please create or update a release PR or create a release. A dependent Windows job checks out the release tag, repeats the Go and PowerShell checks, builds the executable, and attaches it to that GitHub Release. Native commands run in separate PowerShell steps so a later successful command cannot mask an earlier failure. This avoids relying on a tag-push event created by the workflow token to trigger a separate workflow.

The Windows validation job runs on Windows PowerShell 5.1, matching the launcher runtime. It parses every shipped script, validates named cmdlet parameters against the real PowerShell parameter sets, and compiles embedded native declarations. Runtime tests use synthetic applications to exercise updater handoffs (including exit code 2 and delayed grandchildren), failed updaters, job and executable-path isolation, cleanup, controller success and failure, a stuck login helper, and UTF-8 configuration paths. Deferred uninstall is executed through `powershell.exe -File` with both keep-data and remove-data choices. These tests use an isolated profile and do not launch the real poker applications or read saved credentials. Windows Go tests verify installation and updates extract every embedded component, replace the installed executable, and preserve configuration and credentials; they also check that setup and uninstall keep their dialogs visible while background scripts remain hidden. Real application updates, UAC approval, and PokerStars login UI interaction still require a manual Windows test.

CI scans the built Windows executable with Microsoft Defender after updating its security intelligence. The release job repeats the scan on the final versioned EXE before upload. A detection, unavailable scanner, failed update, or incomplete scan blocks the upload. The scanner leaves antivirus protection enabled and checks that the artifact is unchanged after scanning.

The repository retains the `proinit` scaffold/workflow/commit conventions: Conventional Commits, Commitizen, Lefthook, Gitleaks, merge-safety checks, and Release Please. It does not create or push a remote as part of local project setup.

## License and affiliation

MIT. This project is not affiliated with, endorsed by, or supported by PokerStars, Xeester, or StarsCaption.
