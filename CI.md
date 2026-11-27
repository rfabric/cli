# CI wrappers

Run rFabric simulation suites from CI and gate the pipeline on the verdict: one suite (`suite`), or every approved suite of a definition directory (`dir`), the directory in your repository that holds your simulation evaluation definitions as files. Three wrappers around the `rfabric` CLI, one input set. Launching training runs from CI has its own entry points, in the same release: see Training runs below.

| Provider | Use |
|---|---|
| GitHub Actions | `uses: rfabric/cli@v0.1` (`action.yml`) |
| GitLab CI | `include: remote: https://raw.githubusercontent.com/rfabric/cli/v0.1/templates/sim-run.yml` |
| Bitbucket Pipelines | `pipe: docker://ghcr.io/rfabric/cli:0.1` (`pipe.yml`) |

`v0.1` and the image tag `0.1` move together to the newest release of 0.1 once its image is published, so a pipeline gets its fixes without an edit. To pin an exact patch, use its full version: `rfabric/cli@v0.1.11`, `https://raw.githubusercontent.com/rfabric/cli/v0.1.11/templates/sim-run.yml`, `ghcr.io/rfabric/cli:0.1.11`.

Each wrapper registers the candidate image (`rfabric artifact-build register`) once when `image` is given, runs the CLI commands below, publishes the JUnit reports and the markdown summary where the provider shows them, and exits with the CLI's exit code (`rfabric help exit-codes` lists the verdict codes). Cancelling the pipeline cancels the evaluation jobs.

| Run | `suite` | `dir` |
|---|---|---|
| pull request | preflight, `rfabric sim run <suite> --wait` | `rfabric eval apply --preview` (problems fail the step and nothing runs), then `rfabric sim run --dir` (blocking) and, when the preview changes a definition and `test-run` is `auto`, at the same time `rfabric eval test-run --changed` (never fails the step) |
| any other run on `base-branch` (a push) | same | `rfabric eval apply`, then `rfabric sim run --dir` |
| any other run | same | `rfabric sim run --dir` |
| pull request from a fork (GitHub: the event's head repository is not this repository, `pull_request_target` included; GitLab: the merge request's source project, or the pipeline's project, is not the merge request's project), or without an identity token and without `client-secret` | fails before any CLI call, whatever credential the job holds, with the notice that a trusted run on the same commit is needed | same |

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

The GitHub actions (`rfabric/cli` and `rfabric/cli/training-run`) need `jq` on the runner; GitHub-hosted runners have it. They read the event payload with it: without `jq`, or with an unreadable event file, every pull request is refused as a possible fork (the notice names the cause) and a push is not recognised as a run on the base branch.

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

The job `rfabric-sim-run` runs in `ghcr.io/rfabric/cli:<cli-version>` on the stage `stage` (default `test`); run the pipeline for merge requests and the default branch. A merge request pipeline is a pull request; the base branch defaults to `CI_DEFAULT_BRANCH`. JUnit goes to the merge request's test report, the outputs to the dotenv report (`RFABRIC_JOB_ID`, `RFABRIC_REPORT_ID`, `RFABRIC_CONCLUSION`, `RFABRIC_OPERATIONAL_CLASSIFICATION`, `RFABRIC_JOB_URL`, `RFABRIC_ARTIFACT_ID`) and every output, `suites` included (dotenv takes no JSON), to the artifact `rfabric-sim-run/outputs.json`. A canceled job cancels the blocking evaluation jobs in `after_script`. A merge request from a fork gets the fork notice, whether its pipeline runs in the fork project or in this project. With a CI/CD variable `RFABRIC_GITLAB_TOKEN` (a token with the `api` scope), a merge request pipeline creates or updates one note per suite or definition directory, written by that token's user.

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
            - pipe: docker://ghcr.io/rfabric/cli:0.1
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

## Training runs

Launch a training run from a launch template on the trainer image the pipeline built (`rfabric training run`), optionally after applying the repository's launch template files (`rfabric training apply`), and optionally wait for it to end. The same sign-in, event detection, credential choice and fork refusal as the sim wrappers.

| Provider | Use |
|---|---|
| GitHub Actions | `uses: rfabric/cli/training-run@v0.1` (`training-run/action.yml`) |
| GitLab CI | `include: remote: https://raw.githubusercontent.com/rfabric/cli/v0.1/templates/training-run.yml` (job `rfabric-training-run`, result directory `rfabric-training-run/`) |
| Bitbucket Pipelines | `pipe: docker://ghcr.io/rfabric/cli:0.1` with `RFABRIC_LAUNCH_TEMPLATE` set (`pipe.yml` documents both variable sets); no Code Insights report for a training run, only `rfabric-result.json` and, with `RFABRIC_BITBUCKET_TOKEN`, the pull request comment |

| Run | Commands |
|---|---|
| pull request | with `dir`: `rfabric training apply --dir <dir> --preview` (problems fail the step and nothing launches); then `rfabric training run` |
| any other run on `base-branch` (a push) | with `dir`: `rfabric training apply --dir <dir>`, with `--image <launch-template>=<image>` when `image` is set and `--code-version <code-version>` when both are; then `rfabric training run` |
| any other run (tag, manual, schedule) | `rfabric training run` |
| pull request from a fork, or without an identity token and without `client-secret` (as for the sim wrappers) | fails before any CLI call, whatever credential the job holds, with the notice that a trusted run on the same commit is needed |

`rfabric training run <launch-template> --experiment <experiment>` gets `--dataset-version` per dataset version, `--tag` per run tag (`run-tags`), `--base-model`, `--config-overrides`, `--compute-overrides`, `--image`, `--code-version` (only when set), `--wait` and `--wait-timeout`, `--replace-previous`, and `--markdown` (the summary the job summary and the pull request comment show). The CLI prints `✓ Training run <run id> launched from launch template <slug>` once per launch; the wrapper records the run id from it. Cancelling the pipeline while it waits cancels the run (GitLab: in `after_script`). With `dir`, the job must hold the repository's files: on GitHub, check out the commit in the job that runs the action (`actions/checkout`); GitLab and Bitbucket jobs clone it.

The step exits with the CLI's exit code (`rfabric help exit-codes`):

| Code | Meaning |
|---|---|
| 0 | launched (without `wait`), or completed (with `wait`) |
| 40 | the run was cancelled, or the wait was interrupted (the run is cancelled) |
| 50 | the run failed |
| 60 | `wait-timeout` expired; the run keeps going |
| 3 | validation: the apply preview or apply found problems in `dir`, or the launch was refused (a guardrail, a trainer image rFabric cannot read from its registry or one built for another platform than the pool's machines) |
| 2 | usage: a missing or contradictory input (`code-version` without `image`, `wait-timeout` without `wait`, ...) |
| 5 | permission denied (e.g. `replace-previous` without `training:cancel`) |
| 1 | the pull request cannot reach rFabric (a fork), or another failure |

`image` is any container image that contains the training command, pinned by digest; it is not built from an rFabric image. The training command may use the trainer library `rfabric-trainer` (Python module `rfabric_trainer`) or speak the trainer protocol itself. On rFabric's pools and on connected pools, an image in Amazon ECR or Google Artifact Registry is pulled through the container registry connected to the launching workspace or its organization (`rfabric provider-credential setup-token --help` shows how to connect one); an image on any other registry host, the presets' `ghcr.io`, GitLab Container Registry and `docker.io` included, must be publicly readable. On self-hosted pools the host's own `docker login` decides what it can pull.

`code-version` is the commit `image` was built from. The wrappers never default it: the pipeline states it (the provider's commit variable: `github.sha`, `CI_COMMIT_SHA`, `BITBUCKET_COMMIT`), and it goes only with `image`.

Credentials, as for the sim wrappers: `client-id` for base-branch runs (`training:configure` to apply `dir`, `training:launch,read,cancel`), `pull-request-client-id` for pull request runs (`training:launch,read,cancel`, no `training:configure`). `replace-previous` needs `training:cancel`. The base-branch credential has a second trust for runs off the base branch (the tag and manual presets):

| Provider | Base branch trust | Second trust |
|---|---|---|
| GitHub Actions | `ref=refs/heads/main` | `ref=refs/tags/train/*` |
| GitLab | `ref_path=refs/heads/main` | `ref_path=refs/tags/train/*` |
| Bitbucket Pipelines | `branchName=main` | `deploymentEnvironmentUuid={...}`: the deployment environment `training` |

Bitbucket's identity token names no tag, so a run off the base branch signs in through the deployment environment. Create the deployment environment `training` (Repository settings > Deployments), allow only maintainers to deploy to it (Bitbucket Premium custom deployment permissions), and copy its UUID, braces included, into the credential trust. Every step that launches off the base branch declares `deployment: training` (the tag, manual and schedule presets do). Without that restriction any branch with a `deployment: training` step signs in as the base-branch credential. Protect the tag pattern `train/*` on GitHub (tag rulesets) and GitLab (protected tags) for the same reason.

### Training inputs

GitHub and GitLab use these names; the Bitbucket pipe uses `RFABRIC_` plus the name in upper snake case. `client-id`, `pull-request-client-id`, `client-secret`, `workspace`, `profile`, `api-url`, `auth-url`, `cli-version`, `comment` (GitHub), `audience` and `stage` (GitLab) are as in Inputs above.

| Input | Meaning | Default |
|---|---|---|
| `launch-template` | launch template id or slug (required); with `dir`, the slug of the template's file | - |
| `experiment` | experiment id the run belongs to (required) | - |
| `dataset-versions` | dataset version ids, comma or newline separated | - |
| `base-model` | base model id to fine-tune from | - |
| `config-overrides`, `compute-overrides` | JSON objects; the template's guardrails decide which keys are allowed | - |
| `run-tags` | the training run's tags `key=value`, comma or newline separated (sim's `tags` selects suites) | - |
| `image` | trainer image `<repository>@sha256:<digest>` instead of the template's (the template must allow the `image` override) | - |
| `code-version` | the commit `image` was built from; only with `image` | - |
| `dir` | definition directory of launch template files (e.g. `training`), applied as the table above says | - |
| `base-branch` | branch whose runs apply `dir` | the repository's default branch (Bitbucket: `main`) |
| `wait` | `true`: wait until the run ends | `false` |
| `wait-timeout` | with `wait`: how long to wait (a duration, e.g. `6h`); the run keeps going after a timeout | the CLI's |
| `replace-previous` | `true`: cancel the runs this repository launched earlier from the same ref and launch template before launching | `false` |

### Training outputs

`run-id`, `status` (as launched; with `wait`, the terminal status), `run-url`, `best-checkpoint-id` (with `wait`, when the run has one): GitHub step outputs, GitLab dotenv variables `RFABRIC_RUN_ID`, `RFABRIC_STATUS`, `RFABRIC_RUN_URL`, `RFABRIC_BEST_CHECKPOINT_ID` (and `rfabric-training-run/outputs.json`), Bitbucket `rfabric-result.json`.

### Trigger presets

Ready pipeline files under `presets/training-run/<github|gitlab|bitbucket>/`, one per preset. Each builds and pushes the trainer image, passes it on by digest, and calls the training entry point with `code-version` set to the commit it built from, named in the file. GitHub presets use `permissions: id-token: write`; the GPU presets run the launch in the environment `gpu-training`, whose required reviewers approve before GPU spend. No commit-message markers. The presets read their values from CI variables named `TRAINING_*` (`TRAINING_CLIENT_ID`, `TRAINING_EXPERIMENT_ID`, `TRAINING_DATASET_VERSIONS`; pull request presets `TRAINING_PULL_REQUEST_CLIENT_ID`, `TRAINING_PULL_REQUEST_WORKSPACE_ID`, `TRAINING_PULL_REQUEST_EXPERIMENT_ID`, `TRAINING_PULL_REQUEST_DATASET_VERSIONS`, Bitbucket `TRAINING_BITBUCKET_TOKEN`): on GitLab a project CI/CD variable named like a template job variable (`RFABRIC_<INPUT>`, e.g. `RFABRIC_DATASET_VERSIONS`) overrides the value the template maps from the input, a value typed into the Run pipeline form included.

Each preset's image build passes the BuildKit secret `github_token` from `RFABRIC_PACKAGES_TOKEN` (GitHub: a repository secret; GitLab: a masked CI/CD variable; Bitbucket: a secured repository variable): a GitHub token that reads the private rFabric Python packages `rfabric/rfabric-candidate`, `rfabric/rfabric-simulator` and `rfabric/rfabric-trainer`, needed when the trainer image installs `rfabric-trainer` (`rfabric-trainer @ git+https://github.com/rfabric/rfabric-trainer.git@v0.1.0`), whose Dockerfile reads it with `RUN --mount=type=secret,id=github_token`. The token exists only during the build and never reaches a layer; it is separate from rFabric authentication. A trainer image that does not install the library builds with the variable unset.

| Preset | Trigger | Launch |
|---|---|---|
| `manual.yml` | manual run with launch template, dataset version and overrides (GitHub `workflow_dispatch`, GitLab Run pipeline form, Bitbucket custom pipeline `train`) | GPU |
| `tag.yml` | tag push `train/*` | GPU, tagged `git-tag=<tag>` |
| `trainer-change.yml` | push to the base branch touching the trainer's paths (code, config, `Dockerfile`, lockfile, `training/`) | GPU, applies `training/` with the image and commit first |
| `schedule.yml` | schedule on the base branch | GPU |
| `pull-request-approved.yml` | a maintainer approves the pull request (GitHub and GitLab: the label `train`; Bitbucket, which has no labels: a manual step) | short step-capped template in the pull request workspace, `replace-previous` |
| `pull-request.yml` | every pull request push | a short CPU training run of the dedicated template `trainer-pull-request-cpu` in the pull request workspace, `replace-previous` |

## Development

`scripts/ci-job.sh` is the CI job side every entry point shares: the run's event model, the client id the CLI signs in with, the refusal of a pull request that cannot reach rFabric, signal forwarding to the CLI, the definition directory apply, the result directory, the outputs and provider REST calls. A run script maps the inputs to `rfabric` flags and reads the result: `scripts/sim-run.sh` for simulation runs, `scripts/training-run.sh` for training runs. `github.sh`, `gitlab.sh` and `pipe.sh` choose the run script (GitHub and GitLab: the second argument, `sim-run` by default or `training-run`; the pipe: `training-run` when `RFABRIC_LAUNCH_TEMPLATE` is set), detect the run's event (pull request, base-branch run, other; identity token; fork) and publish the result. `mise run test` runs `tests/unit.sh` (the release promotion, the request body size, the annotation limit, each entry point's commands and client id per event for a definition directory, and the exact training commands, client id and outputs per event, with the CLI stubbed; no stack), then every entry point, and the pipe in its image, against a local rFabric stack (`tests/run.sh`): it creates its own workspace with the suites, candidate, experiment and launch template it runs, and deletes it at the end. `scripts/set-version.sh <version>` pins a release.

`.github/workflows/image.yml` publishes the public GitHub Container Registry package `ghcr.io/rfabric/cli:<version>` for each stable release with the job token, then `scripts/promote.sh <version>` moves the git tag `v<major>.<minor>`, then the image tag `<major>.<minor>`, to the newest stable patch of the line whose image exists: that release or a newer one; a reference already there stays. If that release's own image cannot be read, the promotion fails and moves nothing. GitHub may cancel a pending promotion of the line when another one queues; the next promotion completes it. The git tag is pushed with the repository secret `RELEASE_GITHUB_TOKEN`, a token with Contents and Workflows write on `rfabric/cli`: the job token cannot hold the workflows permission, and GitHub may refuse it a tag move to a commit that changes `.github/workflows/`. A refused push leaves both references where they were. A failed promotion is fixed by re-running the failed job (`Re-run failed jobs`; re-running the whole workflow stops at `Refuse an existing version tag`), or by the next release of the line.
