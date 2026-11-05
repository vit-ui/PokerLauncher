# Contributing

## Local requirements

- Git.
- Windows PowerShell 5.1 for validating and exercising the launcher scripts.
- Commitizen (`cz`), Gitleaks, and Lefthook for the repository's local commit hooks.

The launcher runtime itself does not depend on Commitizen, Gitleaks, or Lefthook.

## Validate PowerShell scripts

Run from the repository root in PowerShell:

```powershell
./tests/Validate-Project.ps1
```

This uses the PowerShell parser included with PowerShell; it does not install modules.

## Commit conventions

Use Conventional Commits, for example:

```text
feat: add launcher setup
fix: terminate launched processes after login failure
ci: validate PowerShell scripts on Windows
```

Do not run `cz bump`. Release Please manages versioning and changelog updates from commits.

## Hooks

Lefthook runs Gitleaks on staged changes, Commitizen on commit messages, and a Bash pre-push check that protects `master` against deletion and non-fast-forward updates.
