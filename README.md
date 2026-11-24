<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 🐸 Artifactory Publishing

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/artifactory-publish-action) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
<!-- prettier-ignore-end -->

Uploads a Maven repository tree (the `m2repo` a
`mvn deploy -DaltDeploymentRepository=...::file:...` writes) to a JFrog
Artifactory repository, using the JFrog CLI.

## artifactory-publish-action

## No staging

Artifactory has no Nexus 2 style staging repositories: no open, close,
rule checks or drop. The tag-driven release lane needs none either: a
signed tag triggers the release build, which uploads straight to the
release repository, and the GitHub release records the result.

So this action has one job, upload, and works for snapshot and release
repositories alike. Where a project still wants a holding area, upload
to a separate repository and promote with a copy:

```bash
jf rt copy "libs-staging-local/org/example/app/1.0.0/*" \
  "libs-release-local/" --flat=false
```

Artifactory cannot publish to Maven Central; use a Central Portal
publisher for that.

## Usage Example

<!-- markdownlint-disable MD046 -->

```yaml
steps:
  - name: 'Publish to Artifactory'
    # yamllint disable-line rule:line-length
    uses: lfreleng-actions/artifactory-publish-action@<sha>  # v0.1.0
    with:
      artifactory_url: ${{ vars.ARTIFACTORY_URL }}
      access_token: ${{ secrets.ARTIFACTORY_ACCESS_TOKEN }}
      repository_name: 'libs-release-local'
      files_path: 'm2repo'
```

### Tag-driven release

A signed tag triggers the build; `mvn deploy` writes to a local
directory, then the action uploads that tree. Uploads go file by file:
a failed step can leave a partial version behind; `failed_files` lists
what is missing. Remove the partial version before re-running.

The action does not check tag signatures, and `tags: ['v*']` matches by
name, so any push of a `v*` tag runs this job. Enforce signing
outside the action: restrict who can create `v*` tags with a tag
ruleset, and verify the signature in the workflow before building, as
the first step below does. Its keyring is empty apart from the release
signers' public keys, held in the `RELEASE_SIGNING_KEYS` repository
or environment variable.

```yaml
on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      # yamllint disable-line rule:line-length
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
        with:
          persist-credentials: false

      # Keys come from a protected variable, not the checkout:
      # a tag creator controls the tagged tree
      - name: 'Verify the tag signature'
        env:
          RELEASE_KEYS: ${{ vars.RELEASE_SIGNING_KEYS }}
        run: |
          GNUPGHOME="$(mktemp -d)"
          export GNUPGHOME
          printf '%s\n' "$RELEASE_KEYS" | gpg --batch --import
          git fetch --force origin "+${GITHUB_REF}:${GITHUB_REF}"
          # The tag must still name the commit this job checked out
          test "$(git rev-parse "${GITHUB_REF}^{commit}")" = "${GITHUB_SHA}"
          git tag -v "${GITHUB_REF_NAME}"

      - name: 'Build and deploy to a local directory'
        run: |
          mvn -B deploy \
            -DaltDeploymentRepository="local::file:${PWD}/m2repo"

      - name: 'Publish to Artifactory'
        # yamllint disable-line rule:line-length
        uses: lfreleng-actions/artifactory-publish-action@<sha>  # v0.1.0
        with:
          artifactory_url: ${{ vars.ARTIFACTORY_URL }}
          access_token: ${{ secrets.ARTIFACTORY_ACCESS_TOKEN }}
          repository_name: 'libs-release-local'
          files_path: 'm2repo'
```

### Dry run

Lists what would upload, with no token and no network requests; useful
on pull requests.

```yaml
- name: 'Preview Artifactory upload'
  # yamllint disable-line rule:line-length
  uses: lfreleng-actions/artifactory-publish-action@<sha>  # v0.1.0
  with:
    artifactory_url: ${{ vars.ARTIFACTORY_URL }}
    repository_name: 'libs-release-local'
    files_path: 'm2repo'
    dry_run: 'true'
```

<!-- markdownlint-enable MD046 -->

## Token permissions

The access token needs Deploy on the target repository. Uploading to
a path that already exists, such as re-running a release, also needs
Delete, which Artifactory treats as overwrite; without it the upload
fails with 403. In a JFrog project, the Developer role grants Deploy
but not Delete.

## Inputs

<!-- markdownlint-disable MD013 -->

| Name            | Required | Default | Description                                               |
| --------------- | -------- | ------- | --------------------------------------------------------- |
| artifactory_url | True     |         | JFrog platform URL, must use `https://`                   |
| repository_name | True     |         | Target repository key, e.g. `libs-release-local`          |
| files_path      | True     |         | Directory holding the Maven layout to upload              |
| access_token    | False    |         | Access token; required unless `dry_run` is `true`         |
| upload_path     | False    | `''`    | Path prefix within the repository                         |
| dry_run         | False    | `false` | List what would upload, with no network requests          |

<!-- markdownlint-enable MD013 -->

Checksum files (`*.md5`, `*.sha1`, `*.sha256`, `*.sha512`) never
upload: Artifactory computes its own. Signatures (`*.asc`) do upload.

`files_path` is a literal path: `~`, a leading `-`, spaces and glob
characters carry no special meaning. The tree must hold regular files
and directories, nothing else; the action rejects symlinks and other special
files, and names containing a newline, before any upload, dry runs
included. A symlink above `files_path` is fine.

## Outputs

<!-- markdownlint-disable MD013 -->

| Name              | Description                                         |
| ----------------- | --------------------------------------------------- |
| publication_count | Number of files uploaded                            |
| published_files   | JSON array of uploaded repository paths             |
| failed_count      | Number of files that failed to upload               |
| failed_files      | JSON array of files under `files_path` not uploaded |
| dry_run_count     | Number of files a dry run would upload, else 0      |

<!-- markdownlint-enable MD013 -->

Any failed file, or an upload of nothing, fails the step.

## Compared with nexus-publish-action

Input and output names match
[nexus-publish-action](https://github.com/lfreleng-actions/nexus-publish-action)
where the concept exists in both. These differ on purpose:

- No `permit_fail` or `fail_fast`: a release must not pass with a
  partial upload, so any failed file fails the step.
- No `file_pattern`: the whole Maven tree uploads, minus checksum files.
- No `upload_attempts` or `retry_delay` inputs: each file gets the
  Nexus defaults, 4 attempts 2 seconds apart.
- No staging inputs; see [No staging](#no-staging).

## Notes

- A live run installs JFrog CLI 2.133.0 through `jfrog/setup-jfrog-cli`;
  a runner with a blocking egress policy must allow `releases.jfrog.io`,
  `releases-cdn.jfrog.io` (it redirects there) and the `artifactory_url`
  host.
- The action configures the CLI in a private, temporary home and names
  its server on every call. It never uses, changes or removes a server
  the job configured earlier, and passes the token on stdin, not the
  command line. The job's `JF_URL`, `JF_USER`, `JF_PASSWORD`,
  `JF_ACCESS_TOKEN` and `JF_ENV_*` variables neither reach the upload
  nor change the job's CLI configuration. Later steps in the job do see
  `jf` 2.133.0 on `PATH` and the `JFROG_CLI_*` defaults
  `setup-jfrog-cli` exports when unset.
- `scripts/publish.sh` runs on Bash 3.2 or later with GNU or BSD tools,
  including macOS `/bin/bash`.
- Test locally with `bash tests/test_publish.sh`, which runs the script
  against a fake `jf`, and `bash tests/test_cli.sh`, which runs the real
  JFrog CLI against a loopback HTTPS server; the latter needs `jf`,
  `jq`, `openssl` and `python3`.
- The live upload test in `testing.yaml` runs when the repository sets
  the `ARTIFACTORY_URL` and `ARTIFACTORY_REPOSITORY` repository
  variables, plus the `ARTIFACTORY_ACCESS_TOKEN` secret in the
  `integration-auto` environment. It uploads a unique test version,
  checks it, then deletes it. Without Delete permission the cleanup
  warns and leaves the test version behind.
