# Agent Guidelines

## Code Hooks

This project uses an external code-hooks repository to enforce
commit/PR validation. Rules are defined in the public repo:

- Hook repo: `https://github.com/mose-x/code-hooks`

Key rules (full rules take precedence from the hook repo):

- Both commit author **and** committer emails must be on the allowlist (currently: `602187256@qq.com`)
- Total commit message length must NOT exceed 200 characters, subject NOT exceed 100, ASCII only
- Forbidden tokens in commit messages: `Co-authored-by`, `traeagent`, etc.
- Use Conventional Commits format (e.g., `feat(tap): ...`, `chore(tap): ...`)
- Allowed push branch: `dev` only (changes reach `main` through a PR)

## What lives here

- `Formula/*.rb` and `Casks/*.rb` are the published entries. They are Ruby, but
  they are validated with brew (`scripts/validate-brew.sh`), never installed
  from a local build.
- `scripts/bump.sh` is the only thing that rewrites entries: version, urls and
  checksums. Hand-editing a version or a `sha256` is how a tap goes stale or
  wrong — run `scripts/bump.sh write --formula <name> --force` instead.
- `scripts/test_bump.sh` is the offline test suite for `bump.sh` (no network, no
  brew). Extend it whenever `bump.sh` gains a behaviour.
- `.github/workflows/tap.yml` runs lint (ubuntu), brew validation (macOS) and
  the scheduled bump.

## Testing requirements

Every change to `scripts/*.sh` needs matching coverage in
`scripts/test_bump.sh`, and every change to an entry needs
`scripts/validate-brew.sh --no-install` to pass locally. Do not run
`validate-brew.sh` without `--no-install` on a developer machine: it installs
into the real Homebrew prefix.

Ruby entries have no unit tests of their own — `brew audit --strict`,
`brew style` and the install/test cycle in CI are the test.
