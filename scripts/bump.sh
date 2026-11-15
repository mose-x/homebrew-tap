#!/usr/bin/env bash
#
# bump.sh -- keep this tap pointed at the latest upstream GitHub release.
#
#   scripts/bump.sh check  [--formula NAME]...
#   scripts/bump.sh write  [--formula NAME]... [--force] [--dry-run]
#   scripts/bump.sh verify [--formula NAME]...
#
# check   report which entries are behind their upstream release (exit 1 if any)
# write   rewrite version + url lines and recompute every sha256 from the
#         published assets (--force recomputes even when the version matches)
# verify  re-download every url and compare it against the recorded sha256
#
# The upstream repo of an entry comes from a `# tap-source: owner/repo`
# comment, falling back to the `homepage` line when that is a github.com URL.
#
# Conventions this script relies on (see README.md):
#   * `url` lines are literal or interpolate `#{version}` and nothing else;
#     an interpolated url needs a `version` stanza to expand against
#   * every `sha256 "..."` line sits directly before or after the `url` line
#     it belongs to (formulas put it after, casks before)
#   * `sha256 :no_check` is left untouched
#   * the release tag contains the version (`v2.4.0` for version `2.4.0`)
#   * the current version is the `version "..."` stanza when there is one,
#     otherwise the release tag carried by the urls
#
# Requires bash, curl and awk only -- no jq, no python, no brew.

set -euo pipefail

API_ROOT="https://api.github.com"
CURL_RETRIES="${BUMP_CURL_RETRIES:-4}"
CURL_TIMEOUT="${BUMP_CURL_TIMEOUT:-900}"

log() { printf 'bump.sh: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

# The header comment above, up to the first non-comment line.
usage() {
  awk 'NR > 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

repo_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); }

ensure_tmp() {
  if [ -z "${BUMP_TMP:-}" ]; then
    BUMP_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bump-XXXXXX")
    export BUMP_TMP
    trap 'rm -rf "$BUMP_TMP"' EXIT
  fi
}

# --- reading an entry -------------------------------------------------------

current_version() { # FILE
  local declared
  declared=$(sed -nE 's/^[[:space:]]*version[[:space:]]+"([^"]+)".*$/\1/p' "$1" | head -1)
  if [ -n "$declared" ]; then
    printf '%s\n' "$declared"
    return 0
  fi
  extract_urls "$1" | version_from_urls
}

# urls on stdin -> the release tag they carry (`.../download/v1.2.3/x.tgz`).
version_from_urls() {
  sed -nE 's#.*/releases/download/v?([^/]+)/.*#\1#p' | head -1
}

# owner/repo, or empty when it cannot be determined.
source_repo() { # FILE
  local file="$1" explicit homepage
  explicit=$(sed -nE 's/^[[:space:]]*#[[:space:]]*tap-source:[[:space:]]*([^[:space:]]+).*$/\1/p' "$file" | head -1)
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  homepage=$(sed -nE 's/^[[:space:]]*homepage[[:space:]]+"([^"]+)".*$/\1/p' "$file" | head -1)
  printf '%s\n' "$homepage" |
    sed -nE 's#^https?://github\.com/([^/]+)/([^/]+)/?$#\1/\2#p' | head -1
}

# url lines outside of any livecheck block, in file order.
extract_urls() { # FILE
  awk '
    /^[[:space:]]*livecheck[[:space:]]+do/ { inlc = 1; next }
    inlc && /^[[:space:]]*end/ { inlc = 0; next }
    inlc { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (line !~ /^url[[:space:]]+"/) next
      print quoted(line)
    }
    function quoted(s,   q, rest, e) {
      q = index(s, "\"")
      rest = substr(s, q + 1)
      e = index(rest, "\"")
      if (e == 0) return ""
      return substr(rest, 1, e - 1)
    }' "$1"
}

# "url<TAB>sha256" for every url/sha256 pair, in url order. Formulas put the
# digest after its url, casks before it, so either neighbour is accepted.
extract_pairs() { # FILE
  awk '
    /^[[:space:]]*livecheck[[:space:]]+do/ { inlc = 1; next }
    inlc && /^[[:space:]]*end/ { inlc = 0; next }
    inlc { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (line ~ /^url[[:space:]]+"/) {
        if (pending_sha != "") {
          printf "%s\t%s\n", quoted(line), pending_sha
          pending_sha = ""
        } else {
          pending_url = quoted(line)
        }
        next
      }
      if (line ~ /^sha256[[:space:]]+"/) {
        if (pending_url != "") {
          printf "%s\t%s\n", pending_url, quoted(line)
          pending_url = ""
        } else {
          pending_sha = quoted(line)
        }
        next
      }
    }
    function quoted(s,   q, rest, e) {
      q = index(s, "\"")
      rest = substr(s, q + 1)
      e = index(rest, "\"")
      if (e == 0) return ""
      return substr(rest, 1, e - 1)
    }' "$1"
}

count_urls() { extract_urls "$1" | grep -c . || true; }

count_sha256() { # FILE
  awk '
    /^[[:space:]]*livecheck[[:space:]]+do/ { inlc = 1; next }
    inlc && /^[[:space:]]*end/ { inlc = 0; next }
    inlc { next }
    /^[[:space:]]*sha256[[:space:]]*"/ { n++ }
    END { print n + 0 }' "$1"
}

check_pairing() { # FILE
  local urls shas
  urls=$(count_urls "$1")
  shas=$(count_sha256 "$1")
  if [ "$urls" != "$shas" ]; then
    log "$(basename "$1"): $urls url lines but $shas sha256 lines"
    return 1
  fi
  return 0
}

# Fail when some url does not mention VERSION.
urls_at_version() { # FILE VERSION
  local url
  while read -r url; do
    [ -n "$url" ] || continue
    url=$(expand_url "$url" "$2")
    case "$url" in
    *"$2"*) ;;
    *)
      log "$(basename "$1"): url does not mention '$2': $url"
      return 1
      ;;
    esac
  done < <(extract_urls "$1")
}

version_from_tag() { printf '%s\n' "${1#v}"; }

# Homebrew expands `#{version}` in a url itself; bump.sh only ever sees the raw
# source line, so it has to do the same before it can download anything. Casks
# need the interpolation -- `brew audit` calls a literal url unversioned and
# then demands `sha256 :no_check` -- which is why it is supported at all.
expand_url() { # URL VERSION
  local needle='#{version}'
  printf '%s\n' "${1//"$needle"/$2}"
}

# --- upstream lookup -------------------------------------------------------

latest_tag() { # OWNER/REPO
  local repo="$1" body tag
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    body=$(curl -fsSL --retry "$CURL_RETRIES" --retry-delay 2 --max-time 60 \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$API_ROOT/repos/$repo/releases/latest") || return 1
  else
    body=$(curl -fsSL --retry "$CURL_RETRIES" --retry-delay 2 --max-time 60 \
      -H "Accept: application/vnd.github+json" \
      "$API_ROOT/repos/$repo/releases/latest") || return 1
  fi
  tag=$(printf '%s\n' "$body" |
    sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)
  [ -n "$tag" ] || return 1
  printf '%s\n' "$tag"
}

# --- checksums -------------------------------------------------------------

sha256_of_file() { # FILE
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    openssl dgst -sha256 -r "$1" | cut -d' ' -f1
  fi
}

curl_get() { # URL OUT [CURL FLAG ...]
  local url="$1" out="$2"
  shift 2
  curl -fsSL --retry "$CURL_RETRIES" --retry-delay 2 --max-time "$CURL_TIMEOUT" \
    "$@" -o "$out" "$url"
}

download_sha256() { # URL
  local url="$1" blob
  ensure_tmp
  blob=$(mktemp "$BUMP_TMP/dl-XXXXXX")
  if ! curl_get "$url" "$blob"; then
    # --retry does not cover curl error 16 (HTTP/2 framing), which flaky links
    # and some proxies produce on release downloads. Try once more over 1.1.
    if ! curl_get "$url" "$blob" --http1.1; then
      rm -f "$blob"
      return 1
    fi
  fi
  sha256_of_file "$blob"
  rm -f "$blob"
}

# --- rewriting -------------------------------------------------------------

rewrite_version_and_urls() { # FILE OLD_VERSION NEW_VERSION OUT
  awk -v old="$2" -v new="$3" '
    {
      line = $0
      bare = line
      sub(/^[[:space:]]*/, "", bare)
      if (bare ~ /^version[[:space:]]+"/) {
        q = index(line, "\"")
        rest = substr(line, q + 1)
        e = index(rest, "\"")
        line = substr(line, 1, q) new substr(rest, e)
      } else if (bare ~ /^url[[:space:]]+"/ && index(line, old) > 0) {
        rebuilt = ""
        remainder = line
        while ((p = index(remainder, old)) > 0) {
          rebuilt = rebuilt substr(remainder, 1, p - 1) new
          remainder = substr(remainder, p + length(old))
        }
        line = rebuilt remainder
      }
      print line
    }' "$1" > "$4"
}

assign_sha256() { # FILE SHA_LIST OUT
  awk -v list="$2" '
    BEGIN {
      n = 0
      while ((getline line < list) > 0) {
        if (line != "") { n++; sha[n] = line }
      }
      close(list)
      i = 0
    }
    {
      line = $0
      bare = line
      sub(/^[[:space:]]*/, "", bare)
      if (bare ~ /^sha256[[:space:]]+"/ && i < n) {
        i++
        q = index(line, "\"")
        rest = substr(line, q + 1)
        e = index(rest, "\"")
        line = substr(line, 1, q) sha[i] substr(rest, e)
      }
      print line
    }' "$1" > "$3"
}

# --- entry selection -------------------------------------------------------

target_files() { # ROOT [NAME ...]
  local root="$1"
  shift
  local f base want keep
  for f in "$root"/Formula/*.rb "$root"/Casks/*.rb; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .rb)
    if [ "$#" -gt 0 ]; then
      keep=0
      for want in "$@"; do
        [ "$want" = "$base" ] && keep=1
      done
      [ "$keep" = 1 ] || continue
    fi
    printf '%s\n' "$f"
  done
}

# --- commands --------------------------------------------------------------

cmd_check() { # ROOT [NAME ...]
  local root="$1"
  shift
  local behind=0 f name repo cur tag new
  while read -r f; do
    name=$(basename "$f" .rb)
    repo=$(source_repo "$f")
    if [ -z "$repo" ]; then
      log "$name: cannot determine the upstream repo"
      behind=1
      continue
    fi
    cur=$(current_version "$f")
    if ! tag=$(latest_tag "$repo"); then
      log "$name: $repo has no published release"
      behind=1
      continue
    fi
    new=$(version_from_tag "$tag")
    if [ "$new" = "$cur" ]; then
      printf '%-14s %-10s up to date (%s)\n' "$name" "$cur" "$repo"
    else
      printf '%-14s %-10s -> %s (%s)\n' "$name" "$cur" "$new" "$repo"
      behind=1
    fi
  done < <(target_files "$root" "$@")
  [ "$behind" = 0 ]
}

cmd_write() { # ROOT FORCE DRY [NAME ...]
  local root="$1" force="$2" dry="$3"
  shift 3
  ensure_tmp
  local f name repo cur tag new tmp list url sha
  while read -r f; do
    name=$(basename "$f" .rb)
    repo=$(source_repo "$f")
    [ -n "$repo" ] || die "$name: add a '# tap-source: owner/repo' comment"
    cur=$(current_version "$f")
    [ -n "$cur" ] || die "$name: add a version stanza or a release url to derive one from"
    tag=$(latest_tag "$repo") || die "$name: $repo has no published release"
    new=$(version_from_tag "$tag")
    case "$tag" in
    *"$new"*) ;;
    *) die "$name: tag '$tag' does not contain version '$new'" ;;
    esac
    if [ "$new" = "$cur" ] && [ "$force" != 1 ]; then
      log "$name: already at $cur"
      continue
    fi
    log "$name: $cur -> $new ($repo@$tag)"
    tmp="$BUMP_TMP/$name.rewritten.rb"
    rewrite_version_and_urls "$f" "$cur" "$new" "$tmp"
    check_pairing "$tmp" || die "$name: pair every url with a sha256"
    urls_at_version "$tmp" "$new" || die "$name: url still points at $cur"
    list="$BUMP_TMP/$name.sha256"
    : >"$list"
    while read -r url; do
      [ -n "$url" ] || continue
      url=$(expand_url "$url" "$new")
      sha=$(download_sha256 "$url") || die "$name: cannot download $url"
      printf '%s\n' "$sha" >>"$list"
      log "  $sha  $(basename "$url")"
    done < <(extract_urls "$tmp")
    assign_sha256 "$tmp" "$list" "$BUMP_TMP/$name.final.rb"
    if [ "$dry" = 1 ]; then
      diff -u "$f" "$BUMP_TMP/$name.final.rb" || true
    else
      cat "$BUMP_TMP/$name.final.rb" >"$f"
    fi
  done < <(target_files "$root" "$@")
}

cmd_verify() { # ROOT [NAME ...]
  local root="$1"
  shift
  ensure_tmp
  local status=0 f name cur url want got
  while read -r f; do
    name=$(basename "$f" .rb)
    check_pairing "$f" || status=1
    cur=$(current_version "$f")
    while IFS="$(printf '\t')" read -r url want; do
      [ -n "$url" ] || continue
      url=$(expand_url "$url" "$cur")
      if ! got=$(download_sha256 "$url"); then
        printf 'FAIL %-12s cannot download %s\n' "$name" "$url"
        status=1
        continue
      fi
      if [ "$got" = "$want" ]; then
        printf 'ok   %-12s %s\n' "$name" "$(basename "$url")"
      else
        printf 'FAIL %-12s %s\n' "$name" "$(basename "$url")"
        printf '       want %s\n' "$want"
        printf '       got  %s\n' "$got"
        status=1
      fi
    done < <(extract_pairs "$f")
  done < <(target_files "$root" "$@")
  return "$status"
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || { usage; exit 2; }
  shift
  local root force=0 dry=0
  local names=()
  root=$(repo_root)
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --formula)
      [ "$#" -gt 1 ] || die "--formula needs a name"
      names+=("$2")
      shift 2
      ;;
    --force) force=1; shift ;;
    --dry-run) dry=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
    esac
  done
  # ${names+...} keeps `set -u` happy on bash 3.2 when no --formula was given.
  case "$cmd" in
  check) cmd_check "$root" ${names+"${names[@]}"} ;;
  write) cmd_write "$root" "$force" "$dry" ${names+"${names[@]}"} ;;
  verify) cmd_verify "$root" ${names+"${names[@]}"} ;;
  *) usage; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
