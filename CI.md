# CI wrappers

Run an rFabric simulation suite from CI and gate the pipeline on its verdict. Three wrappers around the `rfabric` CLI, one input set:

| Provider | Use |
|---|---|
| GitHub Actions | `uses: rfabric/cli@v0.1` (`action.yml`) |
| GitLab CI | `include: remote: https://raw.githubusercontent.com/rfabric/cli/v0.1/templates/sim-run.yml` |
| Bitbucket Pipelines | `pipe: docker://public.ecr.aws/rfabric/cli:0.1` (`pipe.yml`) |

`v0.1` and the image tag `0.1` move together to the newest release of 0.1 once its image is published, so a pipeline gets its fixes without an edit. To pin an exact patch, use its full version: `rfabric/cli@v0.1.10`, `https://raw.githubusercontent.com/rfabric/cli/v0.1.10/templates/sim-run.yml`, `public.ecr.aws/rfabric/cli:0.1.10`.

Each wrapper registers the candidate image (`rfabric artifact-build register`) when `image` is given, preflights the launch, launches the suite, waits for the report, publishes the JUnit report and the markdown scorecard where the provider shows them, and exits with the CLI's exit code (`rfabric help exit-codes` lists the verdict codes). Cancelling the pipeline cancels the evaluation job.

## Credential

Create a secretless service credential once, from a workstation. Its trust accepts the identity tokens of your CI provider for one repository, pinned by the repository's immutable id:

```bash
rfabric credential create --name robot-ci \
  --permission simSuite:launch --permission evaluationJob:launch,cancel \
  --permission artifact:read,create,build --permission model:read,create \
  --trust-issuer https://token.actions.githubusercontent.com \
  --trust-condition repository_id=123456789
```

| Provider | Issuer | Repository claim |
|---|---|---|
| GitHub Actions | `https://token.actions.githubusercontent.com` | `repository_id` |
| GitLab.com | `https://gitlab.com` (self-managed: your GitLab URL) | `project_id` |
| Bitbucket Pipelines | `https://api.bitbucket.org/2.0/workspaces/<workspace>/pipelines-config/identity/oidc` | `repositoryUuid` |

The command prints the trust's audience. GitLab's `audience` input and Bitbucket's `oidc: audiences:` must equal it; GitHub requests it on its own. `client-secret` is only for a credential created without a trust.

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
          suite: dock-acceptance
          image: ghcr.io/acme/policy@sha256:4f2a...
          client-id: rf_svc_...
```

The scorecard goes to the job summary and, on a pull request, to one comment per suite, written by the job token and updated in place on every push (a pull request from a fork has a read-only token: no comment, a notice). The JUnit report and the scorecard are uploaded as the artifact `rfabric-sim-run-<suite>-<job id>`.

## GitLab CI

```yaml
include:
  - remote: https://raw.githubusercontent.com/rfabric/cli/v0.1/templates/sim-run.yml
    inputs:
      suite: dock-acceptance
      image: $CI_REGISTRY_IMAGE/policy@sha256:4f2a...
      client-id: rf_svc_...
      audience: https://auth.rfabric.io
```

The job `rfabric-sim-run` runs in `public.ecr.aws/rfabric/cli:<cli-version>` on the stage `stage` (default `test`). JUnit goes to the merge request's test report, the outputs to the dotenv report (`RFABRIC_JOB_ID`, `RFABRIC_REPORT_ID`, `RFABRIC_CONCLUSION`, `RFABRIC_OPERATIONAL_CLASSIFICATION`, `RFABRIC_JOB_URL`, `RFABRIC_ARTIFACT_ID`). A canceled job cancels the evaluation job in `after_script`. With a CI/CD variable `RFABRIC_GITLAB_TOKEN` (a token with the `api` scope), a merge request pipeline creates or updates one note per suite, written by that token's user.

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
                RFABRIC_SUITE: dock-acceptance
                RFABRIC_IMAGE: docker.io/acme/policy@sha256:4f2a...
                RFABRIC_CLIENT_ID: rf_svc_...
```

`oidc: audiences:` turns on the step's identity token with the trust's audience. JUnit goes to `test-results/rfabric/` (Bitbucket's test report), a Code Insights report `rfabric-sim-run-<suite>` with an annotation per failed case (every case the JUnit report marks failed or errored) to the commit, the outputs to `rfabric-result.json` in the clone directory. Bitbucket takes at most 1000 annotations per report: past that, the report details give the number of failed cases, the first 1000 are annotated, and the scorecard lists them all. With `RFABRIC_BITBUCKET_TOKEN` (an access token with pull request write access), a pull request pipeline posts one new comment per run, starting with the marker `<!-- rfabric-sim-run:<suite> -->`. The pipe never edits a comment: Bitbucket's tokens give it no way to tell its own comment from a copy. Bitbucket documents no signal or grace period for a stopped step and runs no `after-script` then: `RFABRIC_WALL_DEADLINE` bounds a job whose step was stopped.

## Inputs

GitHub and GitLab use these names; the Bitbucket pipe uses `RFABRIC_` plus the name in upper snake case (`client-id` is `RFABRIC_CLIENT_ID`).

| Input | Meaning | Default |
|---|---|---|
| `suite` | sim suite slug, `slug@version` or id (required) | - |
| `image` | candidate image `<repository>@sha256:<digest>`, registered with `rfabric artifact-build register` | - |
| `candidate` | candidate artifact id instead of `image` | - |
| `weights` | weights directory or archive registered with `image` | - |
| `model` | model id for registration | created or reused by name |
| `model-name` | model name for registration | last path segment of the image repository |
| `baseline` | baseline subject id | - |
| `cells` | evaluation cell ids, comma or newline separated | the suite matrix |
| `pool` | compute pool id | the suite's pool |
| `max-worker-hours`, `max-parallel-gpu`, `max-parallel-cpu` | launch budget (all three or none) | none |
| `wall-deadline` | seconds the job may run; also bounds the wait | `7200` |
| `workspace` | workspace id | the credential's workspace |
| `profile` | CLI profile (`production`, `staging`, `dev`) | `production` |
| `api-url`, `auth-url` | explicit URLs instead of `profile` | - |
| `client-id` | service credential client id (required) | - |
| `client-secret` | secret, only for a credential without a trust | - |
| `cli-version` | CLI version (GitHub, GitLab; the pipe image pins its own) | this release's `VERSION` |
| `comment` | GitHub: create or update one pull request comment per suite | `true` |
| `audience` | GitLab: the identity token's audience, equal to the trust's audience (it changes with `profile` or `auth-url`) | `https://auth.rfabric.io` |
| `stage` | GitLab: the pipeline stage of the job | `test` |

## Outputs

`job-id`, `report-id`, `conclusion`, `operational-classification`, `job-url`, `artifact-id` (the artifact registered from `image`): GitHub step outputs, GitLab dotenv variables `RFABRIC_<NAME>`, Bitbucket `rfabric-result.json`.

## Development

`scripts/sim-run.sh` is the one script that maps the inputs to `rfabric` flags and reads the result; `github.sh`, `gitlab.sh` and `pipe.sh` only publish it. `mise run test` runs `tests/unit.sh` (the release promotion, the request body size and the annotation limit, no stack), then every entry point, and the pipe in its image, against a local rFabric stack (`tests/run.sh`): it creates its own workspace with the suites and candidate it runs, and deletes it at the end. `scripts/set-version.sh <version>` pins a release.

`.github/workflows/image.yml` publishes `public.ecr.aws/rfabric/cli:<version>` for each stable release, then `scripts/promote.sh <version>` moves the git tag `v<major>.<minor>`, then the image tag `<major>.<minor>`, to the newest stable patch of the line whose image exists: that release or a newer one; a reference already there stays. If that release's own image cannot be read, the promotion fails and moves nothing. GitHub may cancel a pending promotion of the line when another one queues; the next promotion completes it. The git tag is pushed with the repository secret `RELEASE_GITHUB_TOKEN`, a token with Contents and Workflows write on `rfabric/cli`: the job token cannot hold the workflows permission, and GitHub may refuse it a tag move to a commit that changes `.github/workflows/`. A refused push leaves both references where they were. A failed promotion is fixed by re-running the failed job (`Re-run failed jobs`; re-running the whole workflow stops at `Refuse an existing version tag`), or by the next release of the line.
