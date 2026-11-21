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
      repository: 'libs-release-local'
      files_path: 'm2repo'
```

### Tag-driven release

A signed tag triggers the build; `mvn deploy` writes to a local
directory, then the action uploads that tree. Uploads go file by file:
a failed step can leave a partial version behind; remove it before
re-running.

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
          repository: 'libs-release-local'
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
    repository: 'libs-release-local'
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
| repository      | True     |         | Target repository key, e.g. `libs-release-local`          |
| files_path      | True     |         | Directory holding the Maven layout to upload              |
| access_token    | False    |         | Access token; required unless `dry_run` is `true`         |
| upload_path     | False    | `''`    | Path prefix within the repository                         |
| dry_run         | False    | `false` | List what would upload, with no network requests          |

<!-- markdownlint-enable MD013 -->

Checksum files (`*.md5`, `*.sha1`, `*.sha256`, `*.sha512`) never
upload: Artifactory computes its own. Signatures (`*.asc`) do upload.

## Outputs

<!-- markdownlint-disable MD013 -->

| Name              | Description                                     |
| ----------------- | ----------------------------------------------- |
| publication_count | Number of files uploaded                        |
| failed_count      | Number of files that failed to upload           |
| dry_run_count     | Number of files a dry run would upload, else 0  |

<!-- markdownlint-enable MD013 -->

Any failed file, or an upload of nothing, fails the step.

## Notes

- A live run downloads the JFrog CLI through
  `jfrog/setup-jfrog-cli`; a runner with a blocking egress policy must
  allow `releases.jfrog.io` and the `artifactory_url` host.
- Test locally with `bash tests/test_publish.sh`; it runs the script
  against a fake `jf`.
- The live upload test in `testing.yaml` runs when the repository sets
  the `ARTIFACTORY_URL` and `ARTIFACTORY_REPOSITORY` repository
  variables, plus the `ARTIFACTORY_ACCESS_TOKEN` secret in the
  `integration-auto` environment. It uploads a unique test version,
  checks it, then deletes it. Without Delete permission the cleanup
  warns and leaves the test version behind.
