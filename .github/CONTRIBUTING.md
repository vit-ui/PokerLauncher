# Contributing

## Development requirements

- Go 1.23.0 or newer (the module uses only the standard library).
- Windows 10/11 for end-to-end testing.
- Windows PowerShell 5.1 for validating the embedded scripts.
- Git, `uv`, Commitizen, Lefthook, and Gitleaks for the repository hooks.

The installed application does not require Go, Git, Inno Setup, or a separate .NET runtime.

## Project layout

- `main.go` and `app_windows.go`: self-installing executable, per-user installation, UAC handoff, PowerShell host, and user-facing error dialogs.
- `scripts/register.ps1`: refreshes shortcuts and the per-user Windows uninstall registration.
- `scripts/setup.ps1`: first-run and repeat configuration UI and DPAPI credential storage.
- `scripts/launch.ps1`: elevated process controller and Windows Job Object failure cleanup.
- `scripts/ProcessJob.ps1`: shared native process creation, job ownership, and executable identity checks for the controller and login helper.
- `scripts/PokerStarsLogin.ps1`: native PokerStars login-form detection, field verification, and confirmed Login-button notification.
- `scripts/uninstall.ps1`: user-facing uninstall confirmation and delayed removal of the installed files.
- `assets/`: resources embedded into the executable. Place the supplied shortcut icon at `assets/PokerLauncher.ico`.

## Development tools and hooks

Install the repository-only tools (these are not application runtime dependencies):

```powershell
go install github.com/evilmartians/lefthook@v2.2.2
go install github.com/zricethezav/gitleaks/v8@v8.30.1
uv tool install commitizen
lefthook install
```

Ensure Go's bin directory and uv's tool bin directory are on `PATH` before installing the hooks. Git for Windows supplies Bash for the versioned pre-push hook.

## Local validation

Run on Windows PowerShell 5.1:

```powershell
./tests/Validate-Project.ps1
go test ./...
go vet ./...
$env:GOOS = 'windows'
$env:GOARCH = 'amd64'
go build -trimpath -ldflags '-s -w -H=windowsgui -X main.version=0.1.0-dev' -o PokerLauncher.exe .
```

The PowerShell validation parses every runtime script, checks cmdlet parameter sets, compiles the embedded C# Windows API declarations, and runs `tests/Test-LauncherRuntime.ps1`. That suite uses synthetic apps and isolated configuration to test updater exit codes and handoffs, delayed descendants, job/path ownership, process cleanup, complete controller success/failure/timeout paths, UTF-8 paths, and both deferred uninstall data choices through the real PowerShell 5.1 command line. Windows Go tests verify installation and updates extract all current embedded resources, replace stale executables/scripts, and preserve saved configuration and credentials. CI performs the same checks, runs actionlint on the workflows, and builds the Windows executable. Interaction with the real PokerStars, Xeester, StarsCaption, and UAC dialogs still requires a manual Windows test.

## Commit conventions

Use Conventional Commits. Commitizen validates commit messages; Lefthook runs Gitleaks on staged changes and checks pushes to `master` for deletion or non-fast-forward updates. Do not run `cz bump`; Release Please manages versions and changelog entries.

## Release process

1. Merge Conventional Commit changes to `master`. The release workflow calls the complete merge-safety workflow and waits for all its checks before running Release Please.
2. Review and merge the Release Please pull request.
3. Release Please creates the version tag and GitHub Release.
4. A dependent Windows job in the same workflow run checks out the release tag, repeats Go and PowerShell validation, builds `PokerLauncher.exe`, calculates its SHA-256 checksum, and scans the EXE with Microsoft Defender before attaching both files to that release. Go tests, vet, and PowerShell validation use separate steps so one successful command cannot hide another command's failure. CI also scans its Windows build. `tests/Scan-Release.ps1` updates Defender security intelligence and blocks upload on findings or scan failures without disabling protection.
5. The release job downloads the published EXE and verifies its checksum, Windows Attachment Services verdict, and Internet-origin metadata. Both CI and release scans use this browser download API in addition to the command-line Defender scan. Verify the actual browser download on the affected Windows machine before announcing a download-blocking issue as resolved.

The release workflow currently targets Windows x64. Do not publish a release without the `PokerLauncher.exe` asset.

## PokerLauncher 2.x transition

Keep each completed implementation task in a separate Conventional Commit, with its relevant tests. Do not squash the task commits. Mark incompatible changes with `!` and a `BREAKING CHANGE:` footer so Release Please proposes a major release. The transition targets the 2.x.x series; inspect the generated release PR before merging, and do not hand-edit a version bump or run `cz bump`.

The Windows validation entry point now also runs configuration, isolated legacy migration, and settings-control checks. Tests must not use real user credentials, change real application registration, or terminate processes outside their fixture paths. Verify real UAC and PokerStars login manually outside a live poker session.
