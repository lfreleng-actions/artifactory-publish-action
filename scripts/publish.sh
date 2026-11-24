#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Uploads a Maven repository tree (an m2repo) to JFrog Artifactory.
# Usage: publish.sh validate|publish
# Reads ARTIFACTORY_URL, ACCESS_TOKEN, REPOSITORY_NAME, FILES_PATH,
# UPLOAD_PATH and DRY_RUN from the environment; the action sets them.
# Portable to Bash 3.2 and BSD utilities (macOS system shell).

set -euo pipefail

# Artifactory computes checksums itself, and rejects or shadows
# uploaded ones, so these never upload.
# ponytail: fixed list; make it an input if a format needs them
EXCLUDES=('*.md5' '*.sha1' '*.sha256' '*.sha512')
NL=$'\n'

fail() { echo "::error::$*"; exit 1; }

out() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi
}

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}

validate() {
  dry_run="$(printf '%s' "${DRY_RUN:-}" | tr -d '[:space:]' |
    tr '[:upper:]' '[:lower:]')"
  [[ "$dry_run" == true || "$dry_run" == false ]] ||
    fail "dry_run must be 'true' or 'false', not '${DRY_RUN:-}'"

  [[ "${ARTIFACTORY_URL:-}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] ||
    fail 'artifactory_url must be an https:// URL'
  [[ "${REPOSITORY_NAME:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    fail 'repository_name must be a repository key such as libs-release-local'

  upload_path="${UPLOAD_PATH:-}"
  upload_path="${upload_path%/}"
  if [ -n "$upload_path" ]; then
    [[ "$upload_path" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] ||
      fail 'upload_path must be a relative path such as org/opendaylight'
    [[ "/$upload_path/" != */../* && "/$upload_path/" != */./* ]] ||
      fail 'upload_path must not contain . or .. segments'
  fi

  # Resolve one absolute, symlink-free source; a leading / or ./ keeps
  # cd from reading a name such as '-x' as an option
  local given="${FILES_PATH:-}"
  [ -n "$given" ] || fail 'files_path is required'
  case "$given" in /*) ;; *) given="./$given" ;; esac
  [ -d "$given" ] || fail "files_path is not a directory: '${FILES_PATH:-}'"
  # A sentinel keeps $(...) from dropping trailing newlines, which would
  # turn 'm2<newline>' into a different directory, 'm2'
  src="$(cd -P "$given" && pwd -P && echo .)" ||
    fail "cannot enter files_path: '${FILES_PATH:-}'"
  src="${src%.}"
  src="${src%"$NL"}"
  [[ "$src" != *"$NL"* ]] || fail 'files_path must not contain newlines'

  # The CLI follows symlinks out of the tree and skips nothing, so only
  # plain files and directories may exist; then preview equals upload
  local odd
  odd="$(find "$src" ! -type f ! -type d)"
  [ -z "$odd" ] ||
    fail "files_path may hold only regular files and directories; found: ${odd//$NL/, }"
  odd="$(find "$src" -name "*$NL*")"
  [ -z "$odd" ] || fail 'file names under files_path must not contain newlines'

  if [ "$dry_run" = false ] && [ -z "${ACCESS_TOKEN:-}" ]; then
    fail 'a live run needs access_token (dry_run is false)'
  fi
}

# One path per line, relative to $src; validate() ruled out newlines
list_files() {
  local args=() pattern
  for pattern in "${EXCLUDES[@]}"; do args+=(! -name "$pattern"); done
  (cd "$src" && find . -type f "${args[@]}" | sed 's|^\./||' | LC_ALL=C sort)
}

target() { echo "${REPOSITORY_NAME}/${upload_path:+$upload_path/}"; }

# JSON array of repository paths, one per input line
json_list() { jq -cRn '[inputs | select(length > 0)]'; }

sha256() {
  if command -v sha256sum > /dev/null; then sha256sum; else shasum -a 256; fi |
    cut -d' ' -f1
}

# On failure the CLI lists no files: selected files the repository now
# holds with identical content count as published (a re-run included).
# One pattern per selected file keeps the search to this upload, not
# everything under the target, which may be the whole repository.
remote_matches() {
  local remote file spec="$JFROG_CLI_HOME_DIR/search.json"
  printf '%s\n' "$files" |
    jq -Rn --arg t "$(target)" \
      '{files: [inputs | select(length > 0) | {pattern: ($t + .)}]}' \
      > "$spec" || return 1
  remote="$(jf rt search --spec="$spec" --server-id=publish |
    jq -r '.[] | "\(.path) \(.sha256)"')" || return 1
  while IFS= read -r file; do
    if grep -qxF "$(target)$file $(sha256 < "$src/$file")" <<< "$remote"; then
      echo "$(target)$file"
    fi
  done <<< "$files" | LC_ALL=C sort
}

publish() {
  local files count
  files="$(list_files)"
  count="$(printf '%s\n' "$files" | grep -c . || true)"
  [ "$count" -gt 0 ] || fail "no files to upload under '$src'"

  if [ "$dry_run" = true ]; then
    echo "Dry run: would upload $count file(s) to $(target)"
    echo "  ${files//$NL/$NL  }"
    out dry_run_count "$count"
    out publication_count 0
    out failed_count 0
    summary "## Artifactory publish (dry run)" "" \
      "Would upload **$count** file(s) to \`$(target)\`"
    return
  fi

  command -v jq > /dev/null || fail "jq is required to read upload totals"

  # Private CLI home: an action-owned server entry, never a default
  # server the caller or an earlier step configured
  JFROG_CLI_HOME_DIR="$(mktemp -d)"
  trap 'rm -rf "$JFROG_CLI_HOME_DIR"' EXIT
  export JFROG_CLI_HOME_DIR CI=true JFROG_CLI_REPORT_USAGE=false \
    JFROG_CLI_AVOID_NEW_VERSION_WARNING=true
  # In a CI job, jf adds vcs.* matrix params to every upload URL, and
  # build.* ones plus build-info collection when setup-jfrog-cli has
  # exported a build name. This action does a plain upload.
  export JFROG_CLI_CI_VCS_PROPS_DISABLED=true
  unset JFROG_CLI_BUILD_NAME JFROG_CLI_BUILD_NUMBER JFROG_CLI_BUILD_PROJECT
  printf '%s' "$ACCESS_TOKEN" | jf config add publish \
    --url="$ARTIFACTORY_URL" --access-token-stdin --interactive=false \
    > /dev/null 2>&1 || fail "could not configure JFrog CLI for $ARTIFACTORY_URL"

  local exclusions result rc=0
  exclusions="$(IFS=';'; echo "${EXCLUDES[*]}")"
  # 4 attempts, 2s apart: nexus-publish-action's defaults. Run from
  # inside $src: JFrog expands '~' and wildcards anywhere in a
  # source pattern, so the pattern holds no part of the path at all
  result="$(cd "$src" && jf rt upload '(*)' "$(target){1}" \
    --server-id=publish --flat=false --fail-no-op --detailed-summary \
    --retries=3 --retry-wait-time=2s \
    --exclusions="$exclusions")" || rc=$?

  local ok failed published failed_files
  if ! ok="$(jq -er '.totals.success' <<< "$result" 2>/dev/null)" ||
    ! failed="$(jq -er '.totals.failure' <<< "$result" 2>/dev/null)"; then
    # Unreadable output only explains itself when jf also failed
    [ "$rc" -ne 0 ] || fail "could not read upload totals from jf output"
    ok=0
  fi
  if [ "$rc" -eq 0 ] && [ "$failed" -eq 0 ]; then
    published="$(jq -r --arg p "${ARTIFACTORY_URL%/}/artifactory/" \
      '.files[]?.target | ltrimstr($p)' <<< "$result" | LC_ALL=C sort)"
  elif ! published="$(remote_matches)"; then
    # ponytail: unknown, so the whole selection reports as failed
    echo "::warning::could not search $(target) to identify failed files"
    published=''
  fi
  # Failures are the selection minus what reached the repository
  failed_files="$(printf '%s\n' "$files" | sed "s|^|$(target)|" |
    LC_ALL=C comm -23 - <(printf '%s\n' "$published"))"
  failed="$(printf '%s\n' "$failed_files" | grep -c . || true)"
  out dry_run_count 0
  out publication_count "$ok"
  out failed_count "$failed"
  out published_files "$(printf '%s\n' "$published" | json_list)"
  out failed_files "$(printf '%s\n' "$failed_files" | json_list)"
  summary "## Artifactory publish" "" \
    "| Target | Uploaded | Failed |" "|---|---|---|" \
    "| \`$(target)\` | $ok | $failed |"

  if [ "$rc" -ne 0 ] || [ "$failed" -ne 0 ]; then
    [ -z "$failed_files" ] || echo "Not uploaded:$NL  ${failed_files//$NL/$NL  }"
    fail "upload to $(target) failed: $ok uploaded, $failed failed (jf exit $rc)"
  fi
  echo "Uploaded $ok file(s) to $(target) ✅"
}

case "${1:-}" in
  validate) validate; out dry_run "$dry_run" ;;
  publish) validate; publish ;;
  *) fail "usage: $0 validate|publish" ;;
esac
