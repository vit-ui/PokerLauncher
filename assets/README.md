Place the supplied icon at `assets/PokerStarsLauncher.ico` before building a release.

The Go executable embeds the entire `assets/` directory. The self-installing application extracts the ICO into its per-user installation directory and uses it for Desktop and Start Menu shortcuts. If the ICO is not present at build time, Windows uses the executable's default icon until a later build includes it.
