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
- `scripts/PokerStarsLogin.ps1`: native PokerStars login-form detection, field verification, and confirmed Login-button notification.
- `scripts/uninstall.ps1`: user-facing uninstall confirmation and delayed removal of the installed files.
- `assets/`: resources embedded into the executable. Place the supplied shortcut icon at `assets/PokerStarsLauncher.ico`.

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
go build -trimpath -ldflags '-s -w -H=windowsgui -X main.version=0.1.0-dev' -o PokerStarsLauncher.exe .
```

The PowerShell validation parses every runtime script and compiles the embedded C# Windows API declarations. CI performs the same checks and builds the Windows executable. Actual interaction with PokerStars, Xeester, StarsCaption, UAC, and the process cleanup behavior still requires a Windows test machine.

## Commit conventions

Use Conventional Commits. Commitizen validates commit messages; Lefthook runs Gitleaks on staged changes and checks pushes to `master` for deletion or non-fast-forward updates. Do not run `cz bump`; Release Please manages versions and changelog entries.

## Release process

1. Merge Conventional Commit changes to `master`.
2. Review and merge the Release Please pull request.
3. Release Please creates the version tag and GitHub Release.
4. A dependent Windows job in the same workflow run builds `PokerStarsLauncher.exe`, calculates its SHA-256 checksum, and attaches both files to that release.
5. Verify the release asset and test the published executable on Windows before announcing the release.

The release workflow currently targets Windows x64. Do not publish a release without the `PokerStarsLauncher.exe` asset.
