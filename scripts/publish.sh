#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Uploads a Maven repository tree (an m2repo) to JFrog Artifactory.
# Usage: publish.sh validate|publish
# Reads ARTIFACTORY_URL, ACCESS_TOKEN, REPOSITORY, FILES_PATH,
# UPLOAD_PATH and DRY_RUN from the environment; the action sets them.

set -euo pipefail

# Artifactory computes checksums itself, and rejects or shadows
# uploaded ones, so these never upload.
# ponytail: fixed list; make it an input if a format needs them
EXCLUDES=('*.md5' '*.sha1' '*.sha256' '*.sha512')

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
  dry_run="${DRY_RUN:-}"
  dry_run="${dry_run//[[:space:]]/}"
  dry_run="${dry_run,,}"
  [[ "$dry_run" == true || "$dry_run" == false ]] ||
    fail "dry_run must be 'true' or 'false', not '${DRY_RUN:-}'"

  [[ "${ARTIFACTORY_URL:-}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] ||
    fail 'artifactory_url must be an https:// URL'
  [[ "${REPOSITORY:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    fail 'repository must be a repository key such as libs-release-local'

  upload_path="${UPLOAD_PATH:-}"
  upload_path="${upload_path%/}"
  if [ -n "$upload_path" ]; then
    [[ "$upload_path" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] ||
      fail 'upload_path must be a relative path such as org/opendaylight'
    [[ "/$upload_path/" != */../* && "/$upload_path/" != */./* ]] ||
      fail 'upload_path must not contain . or .. segments'
  fi

  files_path="${FILES_PATH:-}"
  files_path="${files_path%/}"
  [ -d "$files_path" ] || fail "files_path is not a directory: '${FILES_PATH:-}'"
  # JFrog CLI reads the source as a wildcard pattern
  [[ "$files_path" != *[\*\?\(\)\{\}\[\]]* ]] ||
    fail 'files_path must not contain * ? ( ) { } [ ]'

  if [ "$dry_run" = false ] && [ -z "${ACCESS_TOKEN:-}" ]; then
    fail 'a live run needs access_token (dry_run is false)'
  fi
}

list_files() {
  local args=()
  for pattern in "${EXCLUDES[@]}"; do args+=(! -name "$pattern"); done
  (cd "$files_path" && find . -type f "${args[@]}" | sed 's|^\./||' | sort)
}

target() { echo "${REPOSITORY}/${upload_path:+$upload_path/}"; }

publish() {
  local files count
  files="$(list_files)"
  count=0
  [ -z "$files" ] || count="$(wc -l <<< "$files")"
  [ "$count" -gt 0 ] || fail "no files to upload under '$files_path'"

  if [ "$dry_run" = true ]; then
    echo "Dry run: would upload $count file(s) to $(target)"
    echo "  ${files//$'\n'/$'\n'  }"
    out dry_run_count "$count"
    out publication_count 0
    out failed_count 0
    summary "## Artifactory publish (dry run)" "" \
      "Would upload **$count** file(s) to \`$(target)\`"
    return
  fi

  command -v jq > /dev/null || fail "jq is required to read upload totals"

  local exclusions result rc=0
  exclusions="$(IFS=';'; echo "${EXCLUDES[*]}")"
  result="$(jf rt upload "${files_path}/(*)" "$(target){1}" \
    --flat=false --fail-no-op --exclusions="$exclusions")" || rc=$?

  local ok failed
  if ! ok="$(jq -er '.totals.success' <<< "$result" 2>/dev/null)" ||
    ! failed="$(jq -er '.totals.failure' <<< "$result" 2>/dev/null)"; then
    # Unreadable output only explains itself when jf also failed
    [ "$rc" -ne 0 ] || fail "could not read upload totals from jf output"
    ok=0
    failed=0
  fi
  out dry_run_count 0
  out publication_count "$ok"
  out failed_count "$failed"
  summary "## Artifactory publish" "" \
    "| Target | Uploaded | Failed |" "|---|---|---|" \
    "| \`$(target)\` | $ok | $failed |"

  [ "$rc" -eq 0 ] && [ "$failed" -eq 0 ] ||
    fail "upload to $(target) failed: $ok uploaded, $failed failed (jf exit $rc)"
  echo "Uploaded $ok file(s) to $(target) ✅"
}

case "${1:-}" in
  validate) validate; out dry_run "$dry_run" ;;
  publish) validate; publish ;;
  *) fail "usage: $0 validate|publish" ;;
esac
