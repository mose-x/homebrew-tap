# mose-x/tap

Homebrew tap for the [mose-x](https://github.com/mose-x) projects. Every entry
points at the prebuilt assets of an upstream GitHub release, and a scheduled
workflow keeps the versions and checksums current.

## Usage

```sh
brew tap mose-x/tap
brew install mose-x/tap/nvm-rust
```

Homebrew 6 does not load entries from a third-party tap until that tap is
trusted. Naming it in full on the command line, as above, always works. To use
short names (`brew install nvm-rust`) as well, trust the tap once:

```sh
brew trust mose-x/tap        # brew untrust mose-x/tap undoes it
```

Until then `brew tap-info mose-x/tap` reports the tap as `Untrusted`, which is
expected and harmless.

Removing everything again:

```sh
brew uninstall mose-x/tap/nvm-rust
brew untap mose-x/tap
```

## Entries

| Entry | Kind | Upstream | Platforms |
| --- | --- | --- | --- |
| [`nvm-rust`](Formula/nvm-rust.rb) | formula | [mose-x/nvm-rust](https://github.com/mose-x/nvm-rust) | macOS x64/arm64, Linux x64/arm64 |

`nvm-rust` installs the `nvm` binary; run `nvm init` once afterwards to create
the shims and shell configuration (`brew info mose-x/tap/nvm-rust` prints the
full caveats, including how to clean up before uninstalling).

## Keeping entries current

`.github/workflows/tap.yml` runs daily at 21:23 UTC and on demand:

1. `scripts/bump.sh write` asks the GitHub API for each entry's latest release,
   rewrites the version and every `url`, then downloads each asset to recompute
   its `sha256`.
2. `scripts/bump.sh verify` downloads them all again and compares the digests.
3. If anything changed, the result is committed as `chore(tap): bump ...` and
   pushed to `main` (or opened as a pull request).
4. That push re-runs the `lint` and `brew` jobs, so a bumped entry is audited,
   installed, tested and uninstalled again before anyone has to notice.

Run it by hand from **Actions → tap → Run workflow**, with an optional entry
name, `direct`/`pr` publishing, and a `force` flag that recomputes checksums
even when the version already matches.

## Local development

```sh
scripts/bump.sh check                    # which entries are behind upstream?
scripts/bump.sh verify                   # re-download and compare every sha256
scripts/bump.sh write --dry-run          # show what a bump would change
bash scripts/test_bump.sh                # offline unit tests for bump.sh
scripts/validate-brew.sh --no-install    # audit, style, livecheck, fetch
scripts/validate-brew.sh                 # ... plus a real install + brew test
```

`validate-brew.sh` copies the working tree into
`$(brew --repository)/Library/Taps/mose-x/homebrew-tap`, exercises it and untaps
it again on exit. Nothing else on the machine changes, and outside CI it refuses
to install into the real prefix unless `BREW_VALIDATE_ALLOW_INSTALL=1` is set —
pass `--no-install` for the read-only checks.

`bump.sh` needs nothing but bash, curl and awk (no jq, no python, no brew) and
runs on the bash 3.2 that macOS ships.

## Adding a new entry

1. Create `Formula/<name>.rb` for a command line tool, or `Casks/<name>.rb` for
   a GUI app. Copy an existing entry as the starting point.
2. Follow the conventions `bump.sh` relies on:
   - `url` lines are literal — no `#{}` interpolation.
   - Each `sha256 "..."` directly follows the `url` it belongs to.
     `sha256 :no_check` is left alone.
   - The release tag contains the version (`v2.4.0` for `2.4.0`).
   - No `version` stanza unless the urls cannot express the version:
     `brew audit --strict` rejects one that only repeats what the url says.
     Without a stanza, `bump.sh` reads the current version back out of the
     `.../releases/download/<tag>/...` part of the urls.
   - `homepage` is the upstream GitHub repo, or add a
     `# tap-source: owner/repo` comment when it is not.
3. Fill in the checksums with `scripts/bump.sh write --formula <name> --force`,
   then confirm with `scripts/bump.sh verify` and
   `scripts/validate-brew.sh --no-install`.
4. Push a branch named `dev` and open a pull request against `main` — the local
   hooks only allow pushing `dev`, and `main` expects the CI jobs to pass.

Commits follow [Conventional Commits](https://www.conventionalcommits.org) and
the identity and message rules in
[mose-x/code-hooks](https://github.com/mose-x/code-hooks), which the
`commit-lint` job enforces on every pull request.

## 中文速览

```sh
brew tap mose-x/tap
brew install mose-x/tap/nvm-rust   # 全名安装，任何 Homebrew 版本都可以
brew trust mose-x/tap              # 之后才能用 brew install nvm-rust 短名
```

GitHub Actions 每天 21:23 (UTC) 检查上游 release，自动重写 url、重新计算
sha256 并提交，推送到 `main` 后会再跑一次完整的 brew 安装测试。新增条目请
按 “Adding a new entry” 的约定编写，走 `dev` 分支 + PR 合并。
