# Repository Guidelines

## Project Structure & Module Organization

This repository is a compact Bash installer project. The primary source file is `install.sh`, which handles platform detection, dependency checks, model download, build/prebuilt install paths, launcher generation, uninstall, dry-run, and health-check behavior. User-facing documentation lives in `README.md`; keep it aligned with any flag or install-path changes. CI configuration is in `.github/workflows/ci.yml`. There is no separate test directory today; validation is driven through ShellCheck and installer dry runs.

## Build, Test, and Development Commands

- `./install.sh --dry-run --yes --use-case 4`: exercise the default agent-oriented non-interactive path without installing files.
- `./install.sh --help`: verify CLI flag text and defaults after argument changes.
- `shellcheck -e SC1091 install.sh`: run the same lint intent as CI, with sourced-file warnings excluded.
- `./install.sh --health-check`: smoke test an already configured local install by starting `llm-server`, polling `/health`, and stopping it.

Avoid running a full install during routine development unless the change affects download, build, or launcher behavior. Prefer `--dry-run` for fast checks.

## Coding Style & Naming Conventions

Write Bash for `bash` with `set -euo pipefail` compatibility. Use four-space indentation inside functions and conditionals. Keep helper functions small, named in lowercase with underscores, for example `ask_number` or `detect_backend`. Constants and global configuration should be uppercase. Quote variable expansions unless arithmetic or pattern matching requires otherwise. Preserve the existing stderr-oriented logging helpers (`info`, `ok`, `warn`, `error`) for user messages.

## Testing Guidelines

Every change to `install.sh` should pass ShellCheck and at least one dry run. For CLI parsing, test both default and explicit flags, for example:

```bash
./install.sh --dry-run --yes --use-case 2 --port 8000 --context 16384
```

When changing platform/backend logic, describe which OS/backend path was tested or simulated. Add CI dry-run coverage when a new required path can be checked cheaply.

## Commit & Pull Request Guidelines

Use short, imperative commit subjects, matching project history: `Fix install_prebuilt symlink handling`, `Add dry-run validation for flags`. Keep commits focused on one behavior or documentation update.

Pull requests should include a brief problem statement, the implementation approach, commands run, and any platform-specific impact. Link issues when available. Include terminal output snippets only when they clarify failures or validation results.

## Security & Configuration Tips

Do not commit downloaded models, build outputs, local env files, or credentials. Treat Hugging Face repo IDs, release URLs, and install paths as user-controlled input; validate before executing commands or writing launcher content.
