# Changelog

All notable changes to this project are documented here. Release Please updates this file from Conventional Commit messages.

## [1.0.9](https://github.com/vit-ui/PokerStarsLauncher/compare/v1.0.8...v1.0.9) (2026-11-06)


### Bug Fixes

* embed application icon in executable and shortcuts ([635b71b](https://github.com/vit-ui/PokerStarsLauncher/commit/635b71b210019b56add60327d0572b2701aa90c6))

## [1.0.8](https://github.com/vit-ui/PokerStarsLauncher/compare/v1.0.7...v1.0.8) (2026-11-06)


### Bug Fixes

* handle normal app closure and finish updates before launching ([feefc87](https://github.com/vit-ui/PokerStarsLauncher/commit/feefc8705ac35280f5232d354ae32fbc066abaa9))

## [1.0.7](https://github.com/vit-ui/PokerStarsLauncher/compare/v1.0.6...v1.0.7) (2026-11-06)


### Bug Fixes

* show a clear notice when PokerStars is already running ([84ddd52](https://github.com/vit-ui/PokerStarsLauncher/commit/84ddd52e73270f2b7c6642e3ff7eaadd2becdaa3))

## [1.0.6](https://github.com/vit-ui/PokerStarsLauncher/compare/v1.0.5...v1.0.6) (2026-11-06)


### Bug Fixes

* restrict process inspection to owned jobs and scan release executables ([cccae32](https://github.com/vit-ui/PokerStarsLauncher/commit/cccae32760110edc41188bea3adcfa1fe0e6bd6a))

## [1.0.5](https://github.com/vit-ui/PokerStarsLauncher/compare/v1.0.4...v1.0.5) (2026-11-06)


### Bug Fixes

* verify updater handoffs and gate releases on runtime checks ([004a399](https://github.com/vit-ui/PokerStarsLauncher/commit/004a399a4765af4f72ef7e77ac6f5178a9e210eb))

## [1.0.4](https://github.com/vit-ui/PokerStarsLauncher/compare/v1.0.3...v1.0.4) (2026-11-06)


### Bug Fixes

* strengthen Windows runtime validation before release ([2b8f6a5](https://github.com/vit-ui/PokerStarsLauncher/commit/2b8f6a5a2fb12e5c050d5b491168f95093fdcd13))

## [1.0.3](https://github.com/vit-ui/PokerStarsLauncher/compare/v1.0.2...v1.0.3) (2026-11-06)


### Bug Fixes

* use compatible path handling in launcher ([c97345b](https://github.com/vit-ui/PokerStarsLauncher/commit/c97345bc18eb31188a423c2c814aa19fd5535c07))

## [1.0.2](https://github.com/vit-ui/PokerStarsLauncher/compare/v1.0.1...v1.0.2) (2026-11-06)


### Bug Fixes

* hide setup console without hiding dialog ([ab02392](https://github.com/vit-ui/PokerStarsLauncher/commit/ab0239270ecdfbfb122f57ae2a2e4ba4f02b5b7e))

## [1.0.1](https://github.com/vit-ui/PokerStarsLauncher/compare/v1.0.0...v1.0.1) (2026-11-06)


### Bug Fixes

* show interactive setup and uninstall dialogs ([144705d](https://github.com/vit-ui/PokerStarsLauncher/commit/144705dac8360b8bfc14220ade99ddba8f752615))

## 1.0.0 (2026-11-05)


### Features

* add setup and elevated application launcher ([5f06897](https://github.com/vit-ui/PokerStarsLauncher/commit/5f0689730d9a784802e72ec4691f1574c00c4956))
* automate native PokerStars login ([807923d](https://github.com/vit-ui/PokerStarsLauncher/commit/807923df10af98fc640b37545ce36e683e4fc8be))
* package launcher as self-installing Windows application ([5065e57](https://github.com/vit-ui/PokerStarsLauncher/commit/5065e57819458873f20719dca872e595c21cad67))


### Bug Fixes

* contain launched processes in a Windows job ([51db495](https://github.com/vit-ui/PokerStarsLauncher/commit/51db49574bb4755f165dfacaf6dc0729657ce6cb))
* keep runtime timeouts in the login helper ([2e3e366](https://github.com/vit-ui/PokerStarsLauncher/commit/2e3e366e4c64eb0039dca0b065a5ccf1f79471f4))

## 0.1.0

- Initial self-installing Windows application release.
- Single-file Go executable embeds the PowerShell launcher and PokerStars login helper.
- Per-user installation, graphical setup, Desktop and Start Menu shortcuts, and uninstaller.
