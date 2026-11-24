#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Runs scripts/publish.sh with the real JFrog CLI (jf on PATH) against
# loopback HTTPS fixtures; asserts what the server actually receives.
# Needs jf, jq, openssl and python3; uses no real registry or token.

set -euo pipefail

for tool in jf jq openssl python3; do
  command -v "$tool" > /dev/null || { echo "Error: $tool not found ❌" >&2; exit 1; }
done

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../scripts/publish.sh"
tmp="$(mktemp -d)"
pids=()
cleanup() {
  [ "${#pids[@]}" -eq 0 ] || kill "${pids[@]}" 2> /dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
cd "$tmp"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
  -addext subjectAltName=IP:127.0.0.1 -keyout key.pem -out cert.pem 2> /dev/null
for name in good old; do
  python3 "$here/artifactory_fixture.py" cert.pem key.pem "$name.port" "$name.log" &
  pids+=($!)
done
for name in good old; do
  for _ in $(seq 50); do [ -s "$name.port" ] && break; sleep 0.1; done
done
good="https://127.0.0.1:$(cat good.port)"
old="https://127.0.0.1:$(cat old.port)"

# The caller's own CLI home, with an unrelated default server
export SSL_CERT_FILE="$tmp/cert.pem" JFROG_CLI_HOME_DIR="$tmp/caller-home" \
  CI=true JFROG_CLI_REPORT_USAGE=false
# As in a GitHub job after setup-jfrog-cli: jf would add build.* and
# vcs.* params to every upload URL; uploads must carry none
export JFROG_CLI_BUILD_NAME=job JFROG_CLI_BUILD_NUMBER=1 GITHUB_ACTIONS=true \
  GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=org/repo \
  GITHUB_SHA=0123abc GITHUB_REF=refs/heads/main GITHUB_WORKFLOW=test \
  GITHUB_RUN_ID=1
jf config add old --url="$old" --access-token=OLDTOKEN --interactive=false > /dev/null 2>&1
jf config use old > /dev/null 2>&1

run() { # run <expect pass|fail> <files_path> [VAR=value ...]
  local expect="$1" files="$2" got; shift 2
  : > good.log; : > old.log; : > out
  if env ARTIFACTORY_URL="$good" ACCESS_TOKEN=GOODTOKEN REPOSITORY_NAME=repo \
    FILES_PATH="$files" UPLOAD_PATH= DRY_RUN=false GITHUB_OUTPUT="$tmp/out" \
    "$@" "$BASH" "$script" publish > log 2>&1; then got=pass; else got=fail; fi
  [ "$got" = "$expect" ] || { cat log; echo "FAIL: expected $expect for '$files' $*"; exit 1; }
}
# Paths PUT to the intended fixture, sorted, without /artifactory/repo/
puts() { jq -r 'select(.method=="PUT") | .path' good.log | sed 's|^/artifactory/repo/||' | LC_ALL=C sort; }
expect_puts() {
  [ "$(puts)" = "$1" ] || { echo "FAIL: uploaded:"; puts; echo "expected:"; echo "$1"; exit 1; }
}
has() { grep -qxF -- "$1" out || { echo "FAIL: '$1' not in outputs:"; cat out; exit 1; }; }

tree() { # tree <dir>: a small m2repo, checksums included
  mkdir -p -- "$1/org/x/1"
  echo jar > "$1/org/x/1/x-1.jar"
  echo pom > "$1/org/x/1/x-1.pom"
  echo sum > "$1/org/x/1/x-1.jar.sha1"
}

# Uses the action's server and token, not the caller's default
tree m2
run pass m2
expect_puts "org/x/1/x-1.jar${NL:=$'\n'}org/x/1/x-1.pom"
[ ! -s old.log ] || { echo 'FAIL: old default server contacted'; cat old.log; exit 1; }
auth="$(jq -r 'select(.method=="PUT") | .authorization' good.log | sort -u)"
[ "$auth" = "Bearer GOODTOKEN" ] || { echo "FAIL: auth '$auth'"; exit 1; }
[ "$(jq -r 'select(.path|endswith("x-1.jar")) | .body' good.log)" = jar ] || { echo 'FAIL: body'; exit 1; }
# Capture first: grep -q exiting early would SIGPIPE jf under pipefail
shown="$(jf config show 2> /dev/null)"
grep -qF "$old" <<< "$shown" || { echo 'FAIL: caller default changed'; exit 1; }
has publication_count=2
has 'published_files=["repo/org/x/1/x-1.jar","repo/org/x/1/x-1.pom"]'
has 'failed_files=[]'

# Preview lists exactly what uploads
run pass m2 DRY_RUN=true
[ "$(sed -n 's/^  //p' log)" = "$(printf 'org/x/1/x-1.jar\norg/x/1/x-1.pom')" ] ||
  { echo 'FAIL: preview differs from upload'; cat log; exit 1; }
has dry_run_count=2

# Symlinks are refused before any request, whether file or directory
mkdir outside; echo SECRET > outside/secret.txt
tree linkfile; ln -s "$tmp/outside/secret.txt" linkfile/org/x/1/secret.txt
run fail linkfile; [ ! -s good.log ] || { echo 'FAIL: request sent'; exit 1; }
tree linkdir; ln -s "$tmp/outside" linkdir/org/out
run fail linkdir; [ ! -s good.log ] || { echo 'FAIL: request sent'; exit 1; }
run fail linkdir DRY_RUN=true

# Awkward but literal roots: tilde, leading dash, spaces, wildcards and
# a symlinked ancestor
for root in '~' '-source' 'with space' 'glob[*]'; do
  tree "$root"; run pass "$root"; expect_puts "org/x/1/x-1.jar${NL}org/x/1/x-1.pom"
done
ln -s m2 m2-link
run pass m2-link/org; expect_puts "x/1/x-1.jar${NL}x/1/x-1.pom"

# Partial failure: counts and artifact identities, and the step fails
tree partial; echo bad > partial/org/x/1/reject-1.jar
run fail partial
has publication_count=2
has failed_count=1
has 'failed_files=["repo/org/x/1/reject-1.jar"]'
has 'published_files=["repo/org/x/1/x-1.jar","repo/org/x/1/x-1.pom"]'

# The follow-up search names each selected file, never a wildcard over
# the target (with no upload_path, that is the whole repository)
aql="$(jq -r 'select(.path | endswith("/api/search/aql")) | .body' good.log)"
[ "$(printf '%s\n' "$aql" | grep -c 'items.find')" -eq 3 ] ||
  { echo "$aql"; echo 'FAIL: expected one search per selected file'; exit 1; }
if grep -qF "\"\$match\"" <<< "$aql"; then
  echo "$aql"; echo 'FAIL: search used a wildcard'; exit 1
fi
echo 'All real-CLI publish tests passed ✅'
