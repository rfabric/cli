# CI wrappers

Run rFabric simulation suites from CI and gate the pipeline on the verdict: one suite (`suite`), or every approved suite of a definition directory (`dir`), the directory in your repository that holds your simulation evaluation definitions as files. Three wrappers around the `rfabric` CLI, one input set:

| Provider | Use |
|---|---|
| GitHub Actions | `uses: rfabric/cli@v0.1` (`action.yml`) |
| GitLab CI | `include: remote: https://raw.githubusercontent.com/rfabric/cli/v0.1/templates/sim-run.yml` |
| Bitbucket Pipelines | `pipe: docker://public.ecr.aws/rfabric/cli:0.1` (`pipe.yml`) |

`v0.1` and the image tag `0.1` move together to the newest release of 0.1 once its image is published, so a pipeline gets its fixes without an edit. To pin an exact patch, use its full version: `rfabric/cli@v0.1.10`, `https://raw.githubusercontent.com/rfabric/cli/v0.1.10/templates/sim-run.yml`, `public.ecr.aws/rfabric/cli:0.1.10`.

Each wrapper registers the candidate image (`rfabric artifact-build register`) once when `image` is given, runs the CLI commands below, publishes the JUnit reports and the markdown summary where the provider shows them, and exits with the CLI's exit code (`rfabric help exit-codes` lists the verdict codes). Cancelling the pipeline cancels the evaluation jobs.

| Run | `suite` | `dir` |
|---|---|---|
| pull request | preflight, `rfabric sim run <suite> --wait` | `rfabric eval apply --preview` (problems fail the step and nothing runs), then `rfabric sim run --dir` (blocking) and, when the preview changes a definition and `test-run` is `auto`, at the same time `rfabric eval test-run --changed` (never fails the step) |
| any other run on `base-branch` (a push) | same | `rfabric eval apply`, then `rfabric sim run --dir` |
| any other run | same | `rfabric sim run --dir` |
| pull request without an identity token and without `client-secret` (a fork) | fails before any CLI call with the notice that a trusted run on the same commit is needed | same |

`rfabric sim run --dir` runs the suites the platform holds as approved for this repository and directory (published by an apply on the base branch), never the pull request's files, so a pull request cannot drop or weaken its own suites; no approved suite matching is not passing (exit 20). The test run runs the changed suites as unpublished definitions; its result is reported in its own section, "Test run - not yet approved", and never satisfies a merge check.

## Credentials

A merge check is honest only when a pull request cannot change what checks it. Give the wrapper two secretless service credentials, created once from a workstation; each trusts your CI provider's identity tokens for one repository, pinned by the repository's immutable id:

| Credential | Input | Trust | Permissions |
|---|---|---|---|
| base-branch | `client-id` | runs on `base-branch` | `evaluationDefinition:author,publish`, `simAsset:publish`, `simSuite:launch`, `evaluationJob:launch,cancel`, `artifact:read,create,build`, `model:read,create` |
| pull request | `pull-request-client-id` | pull request runs | `simSuite:launch`, `evaluationJob:launch,cancel`, `artifact:read,create,build`, `model:read,create` |

`artifact` and `model` are for registering `image`. The wrapper signs in with `pull-request-client-id` on a pull request run and with `client-id` on every other run. Empty `pull-request-client-id` means `client-id` on every run: the pipeline works, but a pull request job then holds a credential that publishes definitions and can change the approved suites its own merge check runs, so the check is not an honest one.

```bash
rfabric credential create --name robot-ci-base-branch \
  --permission evaluationDefinition:author,publish --permission simAsset:publish \
  --permission simSuite:launch --permission evaluationJob:launch,cancel \
  --permission artifact:read,create,build --permission model:read,create \
  --trust-issuer https://token.actions.githubusercontent.com \
  --trust-condition repository_id=123456789 --trust-condition ref=refs/heads/main
rfabric credential create --name robot-ci-pull-request \
  --permission simSuite:launch --permission evaluationJob:launch,cancel \
  --permission artifact:read,create,build --permission model:read,create \
  --trust-issuer https://token.actions.githubusercontent.com \
  --trust-condition repository_id=123456789 --trust-condition 'ref=refs/pull/*/merge'
```

| Provider | Issuer | Repository claim | Base-branch condition | Pull request condition |
|---|---|---|---|---|
| GitHub Actions | `https://token.actions.githubusercontent.com` | `repository_id` | `ref=refs/heads/main` | `ref=refs/pull/*/merge` |
| GitLab.com | `https://gitlab.com` (self-managed: your GitLab URL) | `project_id` | `ref_path=refs/heads/main` | `pipeline_source=merge_request_event` |
| Bitbucket Pipelines | `https://api.bitbucket.org/2.0/workspaces/<workspace>/pipelines-config/identity/oidc` | `repositoryUuid` | `branchName=main` | none: the token has no pull request claim; the credential cannot publish, so it may trust every pipeline of the repository |

Each command prints the trust's audience. GitLab's `audience` input and Bitbucket's `oidc: audiences:` must equal it; GitHub requests it on its own. `client-secret` is only for a credential created without a trust.

## GitHub Actions

```yaml
permissions:
  contents: read
  id-token: write        # the identity token the CLI exchanges
  pull-requests: write   # the pull request comment
jobs:
  sim:
    runs-on: ubuntu-latest
    steps:
      - uses: rfabric/cli@v0.1
        id: sim
        with:
          dir: eval
          image: ghcr.io/acme/controller@sha256:4f2a...
          client-id: ${{ vars.RFABRIC_CLIENT_ID }}
          pull-request-client-id: ${{ vars.RFABRIC_PULL_REQUEST_CLIENT_ID }}
```

Run it on `pull_request` and on `push` to the default branch. The summary goes to the job summary and, on a pull request, to one comment per suite or definition directory, written by the job token and updated in place on every push (a pull request from a fork has a read-only token: no comment, a notice). The JUnit reports and the markdown are uploaded as the artifact `rfabric-sim-run-<suite>-<job id>` (`rfabric-sim-run-dir-<dir>-<first job id>` with `dir`). The base branch defaults to the repository's default branch from the event payload.

## GitLab CI

```yaml
include:
  - remote: https://raw.githubusercontent.com/rfabric/cli/v0.1/templates/sim-run.yml
    inputs:
      dir: eval
      image: $CI_REGISTRY_IMAGE/controller@sha256:4f2a...
      client-id: rf_svc_...
      pull-request-client-id: rf_svc_...
      audience: https://auth.rfabric.io
```

For `pull-request-client-id`, give a client id or nothing: a project CI/CD variable `RFABRIC_PULL_REQUEST_CLIENT_ID` reaches the job without the input, as project variables override the template's job variables of the same name, while an input `$RFABRIC_PULL_REQUEST_CLIENT_ID` stays that text when the variable is unset.

The job `rfabric-sim-run` runs in `public.ecr.aws/rfabric/cli:<cli-version>` on the stage `stage` (default `test`); run the pipeline for merge requests and the default branch. A merge request pipeline is a pull request; the base branch defaults to `CI_DEFAULT_BRANCH`. JUnit goes to the merge request's test report, the outputs to the dotenv report (`RFABRIC_JOB_ID`, `RFABRIC_REPORT_ID`, `RFABRIC_CONCLUSION`, `RFABRIC_OPERATIONAL_CLASSIFICATION`, `RFABRIC_JOB_URL`, `RFABRIC_ARTIFACT_ID`) and every output, `suites` included (dotenv takes no JSON), to the artifact `rfabric-sim-run/outputs.json`. A canceled job cancels the blocking evaluation jobs in `after_script`. A merge request pipeline that runs in the fork project gets the fork notice. With a CI/CD variable `RFABRIC_GITLAB_TOKEN` (a token with the `api` scope), a merge request pipeline creates or updates one note per suite or definition directory, written by that token's user.

## Bitbucket Pipelines

```yaml
pipelines:
  pull-requests:
    '**':
      - step:
          oidc:
            audiences:
              - https://auth.rfabric.io
          script:
            - pipe: docker://public.ecr.aws/rfabric/cli:0.1
              variables:
                RFABRIC_DIR: eval
                RFABRIC_IMAGE: docker.io/acme/controller@sha256:4f2a...
                RFABRIC_CLIENT_ID: rf_svc_...
                RFABRIC_PULL_REQUEST_CLIENT_ID: rf_svc_...
```

Run the step in `pull-requests` and in `branches:` for the base branch. `oidc: audiences:` turns on the step's identity token with the trust's audience. Bitbucket gives a step no default branch: `RFABRIC_BASE_BRANCH` defaults to `main`. JUnit goes to `test-results/rfabric/` (Bitbucket's test report), a Code Insights report `rfabric-sim-run-<suite>` (`rfabric-sim-run-dir-<dir>` with `RFABRIC_DIR`) with an annotation per failed case (every case the JUnit reports mark failed or errored) to the commit, the outputs to `rfabric-result.json` in the clone directory. Bitbucket takes at most 1000 annotations per report: past that, the report details give the number of failed cases, the first 1000 are annotated, and the scorecard lists them all. With `RFABRIC_BITBUCKET_TOKEN` (an access token with pull request write access), a pull request pipeline posts one new comment per run, starting with the marker `<!-- rfabric-sim-run:<suite> -->` (`<!-- rfabric-sim-run:dir:<dir> -->`). The pipe never edits a comment: Bitbucket's tokens give it no way to tell its own comment from a copy. Bitbucket documents no signal or grace period for a stopped step and runs no `after-script` then: `RFABRIC_WALL_DEADLINE` bounds a job whose step was stopped.

## Inputs

GitHub and GitLab use these names; the Bitbucket pipe uses `RFABRIC_` plus the name in upper snake case (`client-id` is `RFABRIC_CLIENT_ID`).

| Input | Meaning | Default |
|---|---|---|
| `suite` | sim suite slug, `slug@version` or id; set this or `dir` | - |
| `dir` | definition directory whose approved suites run (the table above); set this or `suite` | - |
| `suites` | with `dir`: suite slugs, comma or newline separated | every approved suite |
| `tags` | with `dir`: only the suites carrying any of these tags, comma or newline separated | - |
| `base-branch` | branch whose runs apply `dir` and whose passing jobs `baseline: auto` reads | the repository's default branch (Bitbucket: `main`) |
| `test-run` | with `dir`, on a pull request that changes a definition: `auto` test-runs the changed suites, `false` skips the test run | `auto` |
| `image` | candidate image `<repository>@sha256:<digest>`, registered with `rfabric artifact-build register` | - |
| `candidate` | candidate artifact id instead of `image` | - |
| `weights` | weights directory or archive registered with `image` | - |
| `model` | model id for registration | created or reused by name |
| `model-name` | model name for registration | last path segment of the image repository |
| `baseline` | baseline subject id, or `auto`: on `base-branch` run without one and designate each passing job as its protocol's standing baseline (needs `evaluationDefinition:author`); elsewhere compare with the designated job's subject (never a test run; the test run takes an explicit id only) | - |
| `cells` | with `suite`: evaluation cell ids, comma or newline separated | the suite matrix |
| `pool` | compute pool id | the suite's pool |
| `max-worker-hours`, `max-parallel-gpu`, `max-parallel-cpu` | launch budget (all three or none); with `dir`, one budget across every suite | none |
| `wall-deadline` | seconds each job may run; also bounds the wait | `7200` |
| `workspace` | workspace id | the credential's workspace |
| `profile` | CLI profile (`production`, `staging`, `dev`) | `production` |
| `api-url`, `auth-url` | explicit URLs instead of `profile` | - |
| `client-id` | service credential client id (required); the base-branch credential (Credentials above) | - |
| `pull-request-client-id` | service credential client id used on pull request runs instead of `client-id`; the pull request credential | `client-id` |
| `client-secret` | secret, only for a credential without a trust | - |
| `cli-version` | CLI version (GitHub, GitLab; the pipe image pins its own) | this release's `VERSION` |
| `comment` | GitHub: create or update one pull request comment per suite or definition directory | `true` |
| `audience` | GitLab: the identity token's audience, equal to the trust's audience (it changes with `profile` or `auth-url`) | `https://auth.rfabric.io` |
| `stage` | GitLab: the pipeline stage of the job | `test` |

## Outputs

`job-id`, `report-id`, `conclusion`, `operational-classification`, `job-url` (with `suite`; empty with `dir`), `artifact-id` (the artifact registered from `image`), `suites` (each suite's result as JSON: `[{suite, version, jobId, reportId, conclusion, operationalClassification, exitCode, jobUrl}]`): GitHub step outputs, GitLab dotenv variables `RFABRIC_<NAME>` (`suites` in `rfabric-sim-run/outputs.json` only), Bitbucket `rfabric-result.json`.

## Development

`scripts/sim-run.sh` is the one script that chooses the `rfabric` commands and the client id for the run, maps the inputs to their flags and reads the result; `github.sh`, `gitlab.sh` and `pipe.sh` only tell it the run's event (pull request, base-branch run, other; identity token; fork) and publish the result. `mise run test` runs `tests/unit.sh` (the release promotion, the request body size, the annotation limit, and each entry point's commands and client id per event for a definition directory with the CLI stubbed; no stack), then every entry point, and the pipe in its image, against a local rFabric stack (`tests/run.sh`): it creates its own workspace with the suites and candidate it runs, and deletes it at the end. `scripts/set-version.sh <version>` pins a release.

`.github/workflows/image.yml` publishes `public.ecr.aws/rfabric/cli:<version>` for each stable release, then `scripts/promote.sh <version>` moves the git tag `v<major>.<minor>`, then the image tag `<major>.<minor>`, to the newest stable patch of the line whose image exists: that release or a newer one; a reference already there stays. If that release's own image cannot be read, the promotion fails and moves nothing. GitHub may cancel a pending promotion of the line when another one queues; the next promotion completes it. The git tag is pushed with the repository secret `RELEASE_GITHUB_TOKEN`, a token with Contents and Workflows write on `rfabric/cli`: the job token cannot hold the workflows permission, and GitHub may refuse it a tag move to a commit that changes `.github/workflows/`. A refused push leaves both references where they were. A failed promotion is fixed by re-running the failed job (`Re-run failed jobs`; re-running the whole workflow stops at `Refuse an existing version tag`), or by the next release of the line.
