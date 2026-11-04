# Repository Template (`repo-template`)

A production-ready GitHub Template repository with built-in code quality, commit governance, secret protection, and CI gates.

## 🚀 What's Included

* **Commit Governance:** Conventional Commits with a strict 72-character header limit (`.commitlintrc.json`) to prevent GitHub PR title truncation.
* **Pre-commit Automation:** Git hook configuration (`.pre-commit-config.yaml`) including Ruff (lint + format), Yamllint, Bandit, Pyright, and Commitlint.
* **Security & Secret Scanning:** Local TruffleHog configuration (`.trufflehog/`) to block credential leaks.
* **Path Leak Guard:** Pygrep pre-commit hook preventing leakage of local absolute filesystem paths (e.g., `/home/...`).
* **Editor Consistency:** `.editorconfig` (spaces, UTF-8, LF) and `.vscode/settings.json` (commit character counter warning at 72 chars).
* **CI/CD Pipeline:** GitHub Actions workflow (`.github/workflows/ci.yml`) validating all PR commits and pre-commit checks.

## 📦 How to Use

1. Click the green **"Use this template"** button at the top of this GitHub repository page.
2. Clone your new repository.
3. Install the pre-commit Git hooks:
   ```bash
   pre-commit install --hook-type pre-commit --hook-type commit-msg
   ```
