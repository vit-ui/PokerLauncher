`PokerStarsLauncher.ico` is the application icon used by the executable, Desktop and Start Menu shortcuts, and the Windows Apps entry.

The Go executable embeds the entire `assets/` directory. The self-installing application extracts the ICO into its per-user installation directory for shortcut and uninstall registration.

The checked-in `rsrc_windows_amd64.syso` in the project root embeds the same icon as a native Windows executable resource. After replacing the ICO, run `go generate .` from the project root and commit both files. Generation uses [rsrc](https://github.com/akavel/rsrc), pinned to v0.10.2; normal builds need no additional tools or downloads.
