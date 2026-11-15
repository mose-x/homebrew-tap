#!/usr/bin/env bash
#
# Offline unit tests for scripts/bump.sh: no network, no brew, no writes
# outside a temporary directory. Run with `bash scripts/test_bump.sh`.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# bump.sh is checked on its own; sourcing it here only imports its functions.
# shellcheck source=/dev/null disable=SC1091
. "$HERE/bump.sh"
# bump.sh turns on errexit; the tests need to observe non-zero statuses.
set +e

checks=0
failures=0

check() { # DESC EXPECTED ACTUAL
  checks=$((checks + 1))
  if [ "$2" = "$3" ]; then
    printf 'ok %d - %s\n' "$checks" "$1"
  else
    failures=$((failures + 1))
    printf 'not ok %d - %s\n' "$checks" "$1"
    printf '  want: %s\n' "$2"
    printf '  got:  %s\n' "$3"
  fi
}

check_status() { # DESC EXPECTED_STATUS ACTUAL_STATUS
  checks=$((checks + 1))
  if [ "$2" = "$3" ]; then
    printf 'ok %d - %s\n' "$checks" "$1"
  else
    failures=$((failures + 1))
    printf 'not ok %d - %s (exit %s, expected %s)\n' "$checks" "$1" "$3" "$2"
  fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/bump-test-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

cat >"$TMP/widget.rb" <<RUBY
class Widget < Formula
  desc "Test fixture"
  homepage "https://github.com/acme/widget"
  version "1.2.3"
  license "MIT"

  livecheck do
    url "https://github.com/acme/widget/releases"
    regex(%r{href=".*?/tag/v?(\\\\d+(?:\\\\.\\\\d+)+)"})
  end

  on_macos do
    url "https://github.com/acme/widget/releases/download/v1.2.3/widget-1.2.3-macos.tar.gz"
    sha256 "$A"
  end

  on_linux do
    url "https://github.com/acme/widget/releases/download/v1.2.3/widget-1.2.3-linux.tar.gz"
    sha256 "$B"
  end

  def caveats
    <<~EOS
      Prose mentioning 1.2.3 must not be rewritten.
    EOS
  end
end
RUBY

cat >"$TMP/app.rb" <<RUBY
cask "app" do
  version "1.2.3"
  sha256 "$A"

  url "https://github.com/acme/app/releases/download/v1.2.3/app-1.2.3.dmg"
  name "App"
  desc "Fixture cask"
  homepage "https://example.com/app"

  app "App.app"
end
RUBY

# Casks put `sha256` before the `url` it belongs to, split both into
# per-architecture blocks and interpolate the version into the url, because
# `brew audit` calls a literal cask url unversioned -- the shape
# `Casks/svc.rb` uses.
ARM_URL='https://github.com/acme/archcask/releases/download/v#{version}/archcask-#{version}-arm64.dmg'
X64_URL='https://github.com/acme/archcask/releases/download/v#{version}/archcask-#{version}-x64.dmg'
cat >"$TMP/archcask.rb" <<RUBY
cask "archcask" do
  on_arm do
    version "1.2.3"
    sha256 "$A"

    url "$ARM_URL"
  end
  on_intel do
    version "1.2.3"
    sha256 "$B"

    url "$X64_URL"
  end

  name "Archcask"
  homepage "https://github.com/acme/archcask"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "Archcask.app"
end
RUBY

cat >"$TMP/loose.rb" <<'RUBY'
cask "loose" do
  version "1.0.0"
  sha256 :no_check

  # tap-source: acme/mirror
  url "https://example.com/loose-1.0.0.dmg"
  name "Loose"
  homepage "https://example.com/loose"

  app "Loose.app"
end
RUBY

cat >"$TMP/unpaired.rb" <<'RUBY'
class Unpaired < Formula
  desc "Fixture with a url that has no sha256"
  homepage "https://github.com/acme/unpaired"
  version "1.0.0"
  url "https://github.com/acme/unpaired/releases/download/v1.0.0/x.tar.gz"
end
RUBY

# No version stanza: `brew audit --strict` rejects one that merely repeats the
# version the urls already carry, so it has to be scanned back out of them.
cat >"$TMP/scanned.rb" <<RUBY
class Scanned < Formula
  desc "Fixture whose version comes from the urls"
  homepage "https://github.com/acme/scanned"
  license "MIT"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/acme/scanned/releases/download/v1.2.3/scanned-1.2.3-arm64.tar.gz"
      sha256 "$A"
    else
      url "https://github.com/acme/scanned/releases/download/v1.2.3/scanned-1.2.3-x64.tar.gz"
      sha256 "$B"
    end
  end
end
RUBY

# --- parsing ---------------------------------------------------------------

check "current_version reads the version stanza" \
  "1.2.3" "$(current_version "$TMP/widget.rb")"
check "current_version scans the urls without a version stanza" \
  "1.2.3" "$(current_version "$TMP/scanned.rb")"
check "version_from_urls strips the leading v of the tag" \
  "1.2.3" "$(printf '%s\n' "https://x/releases/download/v1.2.3/a.tgz" | version_from_urls)"
check "version_from_urls is empty for a url with no release tag" \
  "" "$(printf '%s\n' "https://example.com/a-1.2.3.tgz" | version_from_urls)"
check "source_repo falls back to the homepage" \
  "acme/widget" "$(source_repo "$TMP/widget.rb")"
check "source_repo is empty for a non-github homepage" \
  "" "$(source_repo "$TMP/app.rb")"
check "source_repo prefers the tap-source comment" \
  "acme/mirror" "$(source_repo "$TMP/loose.rb")"
check "extract_urls skips the livecheck block" \
  "2" "$(count_urls "$TMP/widget.rb")"
check "extract_urls keeps file order" \
  "https://github.com/acme/widget/releases/download/v1.2.3/widget-1.2.3-macos.tar.gz" \
  "$(extract_urls "$TMP/widget.rb" | head -1)"
check "count_sha256 skips :no_check" \
  "0" "$(count_sha256 "$TMP/loose.rb")"
check "count_sha256 counts quoted digests" \
  "2" "$(count_sha256 "$TMP/widget.rb")"
check "extract_pairs joins a url with its digest" \
  "https://github.com/acme/widget/releases/download/v1.2.3/widget-1.2.3-linux.tar.gz $B" \
  "$(extract_pairs "$TMP/widget.rb" | tail -1 | tr '\t' ' ')"
check "extract_pairs joins a digest placed before its url" \
  "https://github.com/acme/app/releases/download/v1.2.3/app-1.2.3.dmg $A" \
  "$(extract_pairs "$TMP/app.rb" | tr '\t' ' ')"
check "extract_pairs keeps cask arch digests with their own url" \
  "$ARM_URL $A" \
  "$(extract_pairs "$TMP/archcask.rb" | head -1 | tr '\t' ' ')"
check "extract_pairs pairs every url of a cask" \
  "$X64_URL $B" \
  "$(extract_pairs "$TMP/archcask.rb" | tail -1 | tr '\t' ' ')"
check "current_version reads a version inside an arch block" \
  "1.2.3" "$(current_version "$TMP/archcask.rb")"
check "source_repo falls back to the homepage of a cask" \
  "acme/archcask" "$(source_repo "$TMP/archcask.rb")"
check_pairing "$TMP/archcask.rb"
check_status "check_pairing accepts a cask with arch blocks" 0 "$?"
urls_at_version "$TMP/archcask.rb" "1.2.3" >/dev/null 2>&1
check_status "urls_at_version expands an interpolated cask url" 0 "$?"
check_pairing "$TMP/widget.rb"
check_status "check_pairing accepts a well formed formula" 0 "$?"
check_pairing "$TMP/unpaired.rb" >/dev/null 2>&1
check_status "check_pairing rejects an unpaired url" 1 "$?"

# --- version handling -----------------------------------------------------

check "version_from_tag strips a leading v" "1.2.3" "$(version_from_tag v1.2.3)"
check "version_from_tag keeps a bare tag" "1.2.3" "$(version_from_tag 1.2.3)"
check "expand_url fills in every interpolation" \
  "https://x/v9.9.9/a-9.9.9.dmg" \
  "$(expand_url 'https://x/v#{version}/a-#{version}.dmg' 9.9.9)"
check "expand_url leaves a literal url alone" \
  "https://x/a-1.2.3.dmg" "$(expand_url 'https://x/a-1.2.3.dmg' 9.9.9)"
urls_at_version "$TMP/scanned.rb" "1.2.3" >/dev/null 2>&1
check_status "urls_at_version accepts urls carrying the version" 0 "$?"
urls_at_version "$TMP/scanned.rb" "9.9.9" >/dev/null 2>&1
check_status "urls_at_version rejects urls left behind" 1 "$?"

# --- rewriting ------------------------------------------------------------

rewrite_version_and_urls "$TMP/widget.rb" "1.2.3" "9.9.9" "$TMP/widget.new.rb"
check "rewrite updates the version stanza" \
  "9.9.9" "$(current_version "$TMP/widget.new.rb")"
check "rewrite updates the release tag in urls" \
  "2" "$(grep -c 'download/v9\.9\.9/widget-9\.9\.9-' "$TMP/widget.new.rb")"
check "rewrite leaves no stale version in urls" \
  "0" "$(grep -c 'url .*1\.2\.3' "$TMP/widget.new.rb" || true)"
check "rewrite leaves prose alone" \
  "1" "$(grep -c 'Prose mentioning 1.2.3' "$TMP/widget.new.rb")"
check "rewrite leaves livecheck alone" \
  "1" "$(grep -c 'acme/widget/releases"' "$TMP/widget.new.rb")"

rewrite_version_and_urls "$TMP/scanned.rb" "1.2.3" "9.9.9" "$TMP/scanned.new.rb"
check "rewrite scans a new version out of the rewritten urls" \
  "9.9.9" "$(current_version "$TMP/scanned.new.rb")"
check "rewrite leaves no stale version in a versionless formula" \
  "0" "$(grep -c 'url .*1\.2\.3' "$TMP/scanned.new.rb" || true)"
urls_at_version "$TMP/scanned.new.rb" "9.9.9" >/dev/null 2>&1
check_status "rewritten urls all carry the new version" 0 "$?"

printf '%s\n%s\n' "$A" "$B" >"$TMP/hashes.txt"
assign_sha256 "$TMP/widget.new.rb" "$TMP/hashes.txt" "$TMP/widget.assigned.rb"
check "assign_sha256 keeps every digest" \
  "2" "$(grep -c "sha256 \"$A\"\|sha256 \"$B\"" "$TMP/widget.assigned.rb")"
assign_sha256 "$TMP/loose.rb" "$TMP/hashes.txt" "$TMP/loose.assigned.rb"
check "assign_sha256 leaves :no_check alone" \
  "1" "$(grep -c 'sha256 :no_check' "$TMP/loose.assigned.rb")"
check "assign_sha256 is a no-op without quoted digests" \
  "0" "$(diff "$TMP/loose.rb" "$TMP/loose.assigned.rb" | grep -c '^[<>]' || true)"

rewrite_version_and_urls "$TMP/archcask.rb" "1.2.3" "9.9.9" "$TMP/archcask.new.rb"
check "rewrite updates every arch version stanza of a cask" \
  "2" "$(grep -c 'version "9\.9\.9"' "$TMP/archcask.new.rb")"
check "rewrite leaves an interpolated cask url alone" \
  "2" "$(grep -cF 'download/v#{version}/archcask-#{version}-' "$TMP/archcask.new.rb")"
urls_at_version "$TMP/archcask.new.rb" "9.9.9" >/dev/null 2>&1
check_status "rewritten cask urls expand to the new version" 0 "$?"
printf '%s\n%s\n' "$B" "$A" >"$TMP/hashes-swapped.txt"
assign_sha256 "$TMP/archcask.rb" "$TMP/hashes-swapped.txt" "$TMP/archcask.assigned.rb"
check "assign_sha256 follows the digest order of a cask" \
  "sha256 \"$B\"" \
  "$(grep -m1 'sha256 "' "$TMP/archcask.assigned.rb" | sed 's/^[[:space:]]*//')"
check "assign_sha256 keeps a cask paired for the next verify" \
  "2" "$(extract_pairs "$TMP/archcask.assigned.rb" | grep -c .)"

# --- ruby -----------------------------------------------------------------

if command -v ruby >/dev/null 2>&1; then
  ruby -c "$TMP/widget.assigned.rb" >/dev/null 2>&1
  check_status "rewritten formula is valid ruby" 0 "$?"
  ruby -c "$TMP/app.rb" >/dev/null 2>&1
  check_status "fixture cask is valid ruby" 0 "$?"
  ruby -c "$TMP/archcask.assigned.rb" >/dev/null 2>&1
  check_status "rewritten cask is valid ruby" 0 "$?"
else
  printf 'ok - ruby missing, skipped syntax checks\n'
fi

bash -n "$HERE/bump.sh"
check_status "bump.sh parses" 0 "$?"

printf '\n%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" = 0 ]
