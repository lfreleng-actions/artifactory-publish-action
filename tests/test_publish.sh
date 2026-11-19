#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Self-test for scripts/publish.sh against a fake jf on PATH.

set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/publish.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

m2="$tmp/m2repo/org/example/app/1.0.0"
mkdir -p "$m2" "$tmp/bin" "$tmp/empty"
touch "$m2/app-1.0.0.jar" "$m2/app-1.0.0.pom" "$m2/app-1.0.0.pom.asc" \
  "$m2/app-1.0.0.jar.sha1" "$m2/app-1.0.0.jar.md5"

# Fake jf: records its arguments, prints JFROG_FAKE_OUT, exits JFROG_FAKE_RC
cat > "$tmp/bin/jf" <<'JF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$JFROG_FAKE_ARGS"
echo "$JFROG_FAKE_OUT"
exit "${JFROG_FAKE_RC:-0}"
JF
chmod +x "$tmp/bin/jf"

export PATH="$tmp/bin:$PATH" JFROG_FAKE_ARGS="$tmp/args"
base_env=(ARTIFACTORY_URL=https://example.jfrog.io REPOSITORY=libs-staging-local
  FILES_PATH="$tmp/m2repo" UPLOAD_PATH= ACCESS_TOKEN=t DRY_RUN=false)

run() { # run <expect pass|fail> <mode> [VAR=value ...]
  local expect="$1" mode="$2"; shift 2
  : > "$tmp/out"
  if env "${base_env[@]}" GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY=/dev/null \
    "$@" "$script" "$mode" > "$tmp/log" 2>&1; then got=pass; else got=fail; fi
  if [ "$got" != "$expect" ]; then
    cat "$tmp/log"; echo "FAIL: expected $expect for $mode $*"; exit 1
  fi
}
has() { grep -qxF -- "$1" "$2" || { echo "FAIL: '$1' not in $2:"; cat "$2"; exit 1; }; }

# Validation at the trust boundary
run pass validate DRY_RUN=' TRUE '; has dry_run=true "$tmp/out"
run fail validate DRY_RUN=maybe
run fail validate ARTIFACTORY_URL=http://example.jfrog.io
run fail validate ARTIFACTORY_URL='https://x.io;rm -rf /'
run fail validate REPOSITORY='../etc'
run fail validate UPLOAD_PATH='org/../etc'
run fail validate UPLOAD_PATH='/org'
run fail validate FILES_PATH="$tmp/missing"
run fail validate ACCESS_TOKEN=
run pass validate ACCESS_TOKEN= DRY_RUN=true

# Dry run: counts files minus checksums, never calls jf
rm -f "$tmp/args"
run pass publish DRY_RUN=true
has dry_run_count=3 "$tmp/out"
[ ! -e "$tmp/args" ] || { echo 'FAIL: dry run called jf'; exit 1; }
run fail publish DRY_RUN=true FILES_PATH="$tmp/empty"

# Live: argument shape and parsed totals
ok='{"status":"success","totals":{"success":3,"failure":0}}'
run pass publish JFROG_FAKE_OUT="$ok" UPLOAD_PATH=org/
has publication_count=3 "$tmp/out"
has "$tmp/m2repo/(*)" "$tmp/args"
has 'libs-staging-local/org/{1}' "$tmp/args"
has '--fail-no-op' "$tmp/args"
has '--exclusions=*.md5;*.sha1;*.sha256;*.sha512' "$tmp/args"

# Live: any failed file, or a jf error, fails the step with counts set
part='{"status":"failure","totals":{"success":2,"failure":1}}'
run fail publish JFROG_FAKE_OUT="$part" JFROG_FAKE_RC=1
has failed_count=1 "$tmp/out"
run fail publish JFROG_FAKE_OUT='not json' JFROG_FAKE_RC=2
# Unreadable totals never pass as success, even when jf exits 0
run fail publish JFROG_FAKE_OUT='not json'
run fail publish JFROG_FAKE_OUT='{"status":"success"}'

echo 'All publish.sh tests passed ✅'
