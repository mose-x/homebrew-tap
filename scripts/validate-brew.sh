#!/usr/bin/env bash
#
# validate-brew.sh [--no-install]
#
# Copies this working tree into Homebrew's own Library/Taps directory as
# mose-x/tap and exercises it with brew: audit, style, livecheck, fetch and
# (unless --no-install) a real install + `brew test` + uninstall of every
# formula and cask.
#
# The uncommitted working tree is what gets validated, and the tap directory
# is removed again on exit, so nothing else on the machine changes. Installing
# does touch the real Homebrew prefix, which is why it is refused outside CI
# unless BREW_VALIDATE_ALLOW_INSTALL=1 is set.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TAP_USER="${TAP_USER:-mose-x}"
TAP_NAME="${TAP_NAME:-tap}"
TAP="$TAP_USER/$TAP_NAME"

install_mode=1
if [ "${1:-}" = "--no-install" ]; then
  install_mode=0
fi

if [ "$install_mode" = 1 ] && [ "${CI:-}" != "true" ] &&
  [ -z "${BREW_VALIDATE_ALLOW_INSTALL:-}" ]; then
  cat >&2 <<MSG
validate-brew.sh: refusing to install into your real Homebrew prefix.
  * pass --no-install for the read-only checks (audit, style, fetch), or
  * set BREW_VALIDATE_ALLOW_INSTALL=1 to allow real installs.
MSG
  exit 1
fi

command -v brew >/dev/null 2>&1 || {
  echo "validate-brew.sh: brew not found in PATH" >&2
  exit 1
}

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

tap_dir="$(brew --repository)/Library/Taps/$TAP_USER/homebrew-$TAP_NAME"

# Invoked through the trap below.
# shellcheck disable=SC2329
cleanup() {
  if [ -d "$tap_dir" ]; then
    brew untap "$TAP" >/dev/null 2>&1 || rm -rf "$tap_dir"
  fi
  if [ "${trusted_here:-0}" = 1 ]; then
    brew untrust "$TAP" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

status=0
run() {
  echo "== $*"
  if ! "$@"; then
    echo "!! FAILED: $*"
    status=1
  fi
}

rm -rf "$tap_dir"
mkdir -p "$tap_dir"
(cd "$ROOT" && tar -cf - --exclude=.git .) | (cd "$tap_dir" && tar -xf -)
git -C "$tap_dir" init -q
git -C "$tap_dir" remote add origin "https://github.com/$TAP_USER/homebrew-$TAP_NAME.git"
git -C "$tap_dir" add -A
git -C "$tap_dir" -c user.name=tap-validate -c user.email=tap-validate@localhost \
  commit -qm "validate the working tree"

echo "== tapped $TAP from $ROOT (install_mode=$install_mode)"
brew tap-info "$TAP" || true

# Homebrew 6 only loads entries from a third-party tap once it is trusted, or
# when the tap or the fully qualified name appears on the command line -- which
# is what every call below does. CI runners are disposable, so trust the tap
# there as well; on a developer machine no trust entry is ever written.
trusted_here=0
if [ "${CI:-}" = "true" ] && brew trust --help >/dev/null 2>&1; then
  echo "== brew trust $TAP"
  if brew trust "$TAP"; then
    trusted_here=1
  else
    echo "(brew trust failed, continuing with fully qualified names)"
  fi
fi

audit_flags=(--strict)
if [ "${CI:-}" = "true" ]; then
  audit_flags+=(--online)
fi
run brew audit "${audit_flags[@]}" --tap "$TAP"
# `brew style <tap>` also lints scripts/*.sh and would install shellcheck for
# it, so only the Ruby entries are checked, by explicit path.
ruby_entries=("$ROOT"/Formula/*.rb "$ROOT"/Casks/*.rb)
existing_entries=()
for entry in "${ruby_entries[@]}"; do
  [ -e "$entry" ] && existing_entries+=("$entry")
done
if [ "${#existing_entries[@]}" -gt 0 ]; then
  run brew style "${existing_entries[@]}"
fi

echo "== brew livecheck --tap $TAP"
brew livecheck --tap "$TAP" || echo "(livecheck findings are not fatal)"

for path in "$ROOT"/Formula/*.rb; do
  [ -e "$path" ] || continue
  name=$(basename "$path" .rb)
  run brew fetch --force --retry "$TAP/$name"
  if [ "$install_mode" = 1 ]; then
    run brew install "$TAP/$name"
    run brew test "$TAP/$name"
    run brew uninstall "$TAP/$name"
  fi
done

for path in "$ROOT"/Casks/*.rb; do
  [ -e "$path" ] || continue
  name=$(basename "$path" .rb)
  run brew fetch --force --retry --cask "$TAP/$name"
  if [ "$install_mode" = 1 ]; then
    run brew install --cask --no-quarantine "$TAP/$name"
    run brew uninstall --cask "$TAP/$name"
  fi
done

if [ "$status" = 0 ]; then
  echo "== validation passed"
else
  echo "== validation FAILED"
fi
exit "$status"
