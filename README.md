# PokerStarsLauncher

A Windows launcher for PokerStars, Xeester, and StarsCaption. It starts the three configured executables in the same order as the original batch file, without waiting for one updater to finish before starting the next, then submits the saved PokerStars login form.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 (included with Windows).
- The three applications already installed.
- Git is only required for development and version control; it is not required to run the launcher.

The launcher does not install applications or require third-party runtime tools. It requests administrator permission once; all three applications and the login helper are started from that elevated process.

## Initial setup

1. Extract the repository to a stable folder. Do not move the folder after creating the Desktop shortcut without running setup again.
2. Run `setup.bat`.
3. Enter your PokerStars username and password. The three executable paths are pre-filled with the paths used by the original launcher; press Enter to accept each detected path or enter a different path.
4. Setup creates `PokerStars Launcher.lnk` on the current user's Desktop.

The username and executable paths are stored in `%APPDATA%\PokerStarsLauncher\config.json`. The password is stored separately as a DPAPI-protected value in `%APPDATA%\PokerStarsLauncher\password.dpapi`. The password file is tied to the Windows user profile and machine; do not copy it to another computer or commit it.

Setup can be run again to change the username or executable paths. Press Enter at the password prompt to keep the existing encrypted password; enter a new password to replace it.

## Launch

Use the Desktop shortcut or run `launch.bat`. Windows asks for administrator permission. After approval, the launcher:

1. Starts `PokerStarsUpdate.exe`.
2. Starts `xeester-update.exe`.
3. Starts `StarsCaption.exe`.
4. Waits for the actual PokerStars login form, fills the native username and password controls, and sends the confirmed parent-dialog `WM_COMMAND / BN_CLICKED` notification.

The three application processes are started concurrently in the order above. PokerStars login-form detection waits up to 180 seconds. After the Login notification, the original login dialog must disappear within 30 seconds for the helper to report success. This is a UI-submission signal; the helper does not independently inspect the authenticated lobby state.

If an executable cannot be started, a launcher process exits with a non-zero code, or the PokerStars login helper fails, the launcher stops and terminates the Windows Job Object created for that invocation. Each process is created suspended and assigned to the job before it can start, so its descendant processes inherit the same job membership. This avoids killing matching processes that were already running before the launcher started. Failure details are written under `%LOCALAPPDATA%\PokerStarsLauncher\logs\`.

## Shortcut icon

The setup script expects the icon at `assets\PokerStarsLauncher.ico`. That file is intentionally not included in this initial build yet. Setup will create the shortcut with its default Windows icon until the ICO is added. After adding it, run `setup.bat` again to update the shortcut.

## Project and Git conventions

The repository follows the project bootstrap structure and conventions used by [proinit](https://github.com/vit-ui/proinit):

- Separate scaffold, workflow, and commit-hook setup phases.
- Conventional Commits checked by Commitizen.
- Gitleaks on staged changes.
- A pre-push check that blocks deletion and non-fast-forward updates to `master`.
- Ubuntu merge-safety checks, plus Windows PowerShell syntax validation.
- Release Please creates release pull requests from conventional commits.

The local repository is initialized on `master`. No GitHub remote is configured and no push is performed by this project bootstrap.
