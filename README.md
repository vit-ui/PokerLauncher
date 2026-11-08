# PokerLauncher

A Windows launcher for one poker client and any number of helper applications. **PokerStars is the supported client in this version.** Helpers can be any Windows executable, including tools launched through updaters.

## Install and configure

1. Download **PokerLauncher.exe** from [Releases](../../releases) and run it.
2. In Settings, choose the PokerStars application or updater. New installations have no preselected paths or helpers.
3. Add your helpers. Edit, remove, or move them up and down to set their launch order.
4. Optionally enable automatic PokerStars login and enter your credentials.
5. Save, then use the Desktop or Start Menu **PokerLauncher** shortcut.

The single executable installs per user under `%LOCALAPPDATA%\Programs\PokerLauncher`. No Go, separate runtime, archive extraction, or administrator permission is needed for installation. Launching programs requests one administrator approval. Windows 10/11 x64 and the included Windows PowerShell 5.1 are required.

Open **Configure PokerLauncher** in the Start Menu to change settings. Under each program's Advanced settings you can supply arguments, a working directory, and the actual application executable when starting an updater. Selecting `PokerStarsUpdate.exe` in the window automatically selects the adjacent `PokerStars.exe` as its application.

## Application validation

Selecting a program does not execute it. The launcher checks executable structure and paths. PokerStars compatibility checks use executable names, version metadata, and the updater/application directory relationship; an unrelated EXE renamed to PokerStars is rejected. These checks are not proof of publisher authenticity. Helpers are unrestricted Windows EXEs; DLLs and invalid executable files are rejected.

At launch, readiness requires the actual configured executable path and membership in this invocation's Windows Job Object. Programs that are already open are matched by their executable paths and reused. For an unfamiliar helper updater, specify the executable of the application it eventually starts; the updater must hand off within the launcher's process job.

## Launch and failure behavior

The client starts first, followed by helpers in their configured order, without waiting for each updater to complete. Applications already running are reused; missing applications are launched. Automatic login is skipped when PokerStars was already open.

Helper failures leave the client and other helpers running and produce a combined report. Client startup failures, client crashes during startup, and automatic-login failures terminate only processes owned by this launch. Previously running applications remain untouched.

Updater handoff allows 30 seconds after updater exit, including nonzero exit codes when a verified application starts. Startup and login have a 240-second overall limit; pending helpers at that limit are reported as helper failures when the client and login have succeeded. Normal closure after confirmed startup is not a handoff failure. Closing PokerStars normally during pending login cancels automation and leaves other programs alone. The launcher does not supervise the session after startup completes.

Automatic login targets only a PokerStars process created by the current launch. It waits up to 180 seconds for the native login form and up to 30 seconds for that dialog to disappear after submission. This confirms submission, not successful authentication. Other clients are not yet supported.

## Configuration file

Settings are stored in `%APPDATA%\PokerLauncher\config.json`. Close Settings before editing the file directly. Changes take effect on the next launch. Example with manual login and one helper:

```json
{
  "SchemaVersion": 2,
  "Integration": "PokerStars",
  "PokerClient": {
    "Name": "PokerStars",
    "Path": "C:\\Program Files (x86)\\PokerStars\\PokerStarsUpdate.exe",
    "ApplicationPath": "C:\\Program Files (x86)\\PokerStars\\PokerStars.exe",
    "Arguments": "",
    "WorkingDirectory": ""
  },
  "Helpers": [
    {
      "Name": "My helper",
      "Path": "C:\\Tools\\Helper.exe",
      "ApplicationPath": "",
      "Arguments": "",
      "WorkingDirectory": ""
    }
  ],
  "LoginMode": "Manual",
  "PokerStarsUsername": ""
}
```

Use `"Helpers": []` for no helpers. Helpers start in array order. Every entry needs a name and launch path. Empty `ApplicationPath` uses the launch executable itself; empty `WorkingDirectory` uses its folder. Paths support Windows environment variables. Actual application paths must be unique across the client and helpers. Unknown schema versions and integrations are rejected.

Set `LoginMode` to `PokerStars` for automatic login, with `PokerStarsUsername` populated and a password saved through Settings. Passwords are stored separately in `password.dpapi`, protected by Windows DPAPI for the same Windows account; never put passwords in JSON. Leave the password field blank to retain a saved password. Manual mode requires no credentials.

Logs are under `%LOCALAPPDATA%\PokerLauncher\logs`. Error dialogs give a next step, with technical details retained in logs.

## Upgrading and uninstalling

This is a **2.x.x breaking-change release**, with a renamed executable, installation identity, folders, and configuration schema. The GitHub repository is now [vit-ui/PokerLauncher](https://github.com/vit-ui/PokerLauncher); release history is preserved and GitHub redirects old repository links.

Running the new download automatically transfers legacy PokerStarsLauncher settings, helper order, and encrypted credentials. Legacy users retain automatic login. Migration verifies credentials and stages configuration before publishing it; repeating migration does not overwrite an existing PokerLauncher configuration. An untouched legacy settings backup is retained under `%APPDATA%\PokerLauncher\legacy-backup`. Shortcuts and Windows Apps registration switch to PokerLauncher; the old installation is removed after the installer exits.

If migration fails, Settings opens for recovery and the failure is recorded in the logs. Your legacy program list and username are loaded when readable; enter a replacement password or turn off automatic login. Saving creates new settings before refreshing shortcuts and registration. Cancelling leaves the legacy installation and data intact.

For subsequent updates, run the latest download. Updates preserve settings and credentials and do not launch poker applications. Uninstall through Windows Settings → Apps → PokerLauncher. Choose whether to retain saved data, including the migration backup.

## Development

The Windows GUI executable is written in Go and embeds its PowerShell implementation and assets. Runtime extraction is automatic.

```sh
go test ./...
go vet ./...
GOOS=windows GOARCH=amd64 go build -trimpath -ldflags '-s -w -H=windowsgui -X main.version=dev' -o out/PokerLauncher.exe .
```

On Windows PowerShell 5.1, run:

```powershell
./tests/Validate-Project.ps1
```

Validation includes syntax/cmdlet checks, embedded C# compilation, native process jobs, synthetic startup/failure scenarios, configuration, migration, settings controls, and uninstall tests. Tests use isolated profiles and synthetic executables; they do not launch real poker applications or read saved user credentials. The settings test briefly opens and closes a test window. Real UAC and native PokerStars login were verified previously; their underlying mechanisms are unchanged. Optional login and reused-session behavior are covered by the synthetic runtime tests. Repeat real verification if those mechanisms change.

The icon is `assets/PokerLauncher.ico`; after changing artwork run `go generate .` and commit the updated native resource. See [assets/README.md](assets/README.md).

Complete each implementation task with its own Conventional Commit and relevant tests; preserve the commits when integrating. Incompatible changes use `!` and a `BREAKING CHANGE:` footer. Release Please owns versions and changelogs; do not run `cz bump`. The next release must be in the **2.x.x** series. Review its generated release PR before merging. See [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md).

CI and release workflows validate Windows runtime behavior and scan the final executable with Microsoft Defender and Windows Attachment Services. The release job verifies the published download and checksum. Initial builds remain unsigned, so SmartScreen reputation can vary.

## License and affiliation

MIT. Not affiliated with PokerStars or any helper application publisher.
