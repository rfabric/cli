# rfabric

The terminal-native interface to the [rFabric](https://rfabric.io) robotics lifecycle platform. Manage data, training, models, releases, deployments, fleets, and operations from the command line.

- Single static binary, ~10ms startup, no runtime dependencies
- linux / macOS / Windows on amd64 + arm64
- Structured output (`json`, `yaml`, `table`, `tsv`, `value`) for scripting
- OAuth device flow for humans; service credentials for CI, secretless in GitHub Actions, GitLab CI and Bitbucket Pipelines

## Install

```bash
# macOS / Linux (Homebrew)
brew install rfabric/tap/rfabric

# Windows (Scoop)
scoop bucket add rfabric https://github.com/rfabric/scoop
scoop install rfabric

# macOS / Linux (curl)
curl -fsSL https://get.rfabric.io/cli.sh | sh

# Node.js ecosystem
npm install -g @rfabric/cli
```

On Linux with apt-get or dnf (Debian, Ubuntu, Fedora, RHEL), `cli.sh` adds the rFabric package repository <https://linux.rfabric.io> and installs the `rfabric` package, so `sudo apt-get upgrade` / `sudo dnf upgrade` keep it current. Everywhere else it installs the binary from the GitHub Release into `RFABRIC_INSTALL_DIR` (default `/usr/local/bin`), checksum-verified. Binary-only install on any OS: `curl -fsSL https://get.rfabric.io/cli.sh | RFABRIC_INSTALL_DIR=/usr/local/bin sh`.

Pre-release builds are available via `@next` on npm and the `rc` channel (`curl -fsSL https://get.rfabric.io/cli.sh | RFABRIC_CHANNEL=rc sh`).

## Quick start

```bash
rfabric config init     # writes ~/.config/rfabric/config.yaml with local/dev/staging/production profiles
rfabric auth login      # OAuth device flow
rfabric data ls         # list datasets
rfabric --help          # full command tree
```

Every command supports `--help`, `--output {json,yaml,table,tsv,value}`, and `--profile {local,dev,staging,production}`.

## CI/CD

The GitHub Action, GitLab template and Bitbucket pipe that wrap these commands are documented in [CI.md](https://github.com/rfabric/cli/blob/main/CI.md). They take two service credentials: `client-id`, which may publish definitions and is trusted on the base branch only, and `pull-request-client-id`, which may not publish and is used on pull request runs; without it `client-id` runs everywhere, and the merge check is no longer one a pull request cannot weaken ([CI.md, Credentials](https://github.com/rfabric/cli/blob/main/CI.md#credentials)).

Gate a pipeline on a simulation suite:

```bash
rfabric artifact-build register ghcr.io/acme/policy@sha256:4f2a... --weights ./checkpoint --timeout 30m   # prints the artifact id
rfabric sim run dock-acceptance --candidate art_... --wait --junit report.xml --markdown report.md
```

### Authentication

Create a service credential once, from a workstation. A secretless credential trusts the identity tokens your CI provider issues; pin the repository by its immutable id (`repository_id` on GitHub Actions, `project_id` on GitLab, `repositoryUuid` on Bitbucket Pipelines). A launch credential registers the candidate image and runs suites:

```bash
rfabric credential create --name robot-ci --workspace-id wks_... \
  --permission simSuite:launch --permission evaluationJob:launch,cancel \
  --permission artifact:read,create,build --permission model:read,create \
  --trust-issuer https://token.actions.githubusercontent.com \
  --trust-condition repository_id=123456789 --trust-condition ref=refs/heads/main
rfabric credential trust list rf_svc_...     # the trusts and the audience their tokens must carry
rfabric credential trust add rf_svc_... --issuer https://gitlab.com --condition project_id=4242
rfabric credential trust remove rf_svc_... cctr_...
```

A definition directory (`rfabric eval apply`, `rfabric sim run --dir`) needs two credentials, so a pull request cannot change the approved suites its own merge check runs: a base-branch credential that also holds `evaluationDefinition:author,publish` and `simAsset:publish` (it publishes the directory and designates standing baselines), trusting only base-branch runs, and a pull request credential with the launch permissions above, trusting only pull request runs. CI.md (Credentials) has both commands and each provider's trust conditions; the CI wrappers take their client ids as `client-id` and `pull-request-client-id`.

In CI set only `RFABRIC_CLIENT_ID`, the client id of the credential that run uses (and `--profile` for an environment other than production; the profiles `local`, `dev`, `staging` and `production` need no config file). The CLI obtains the CI identity token and exchanges it for an access token, renewing it during long waits. Commands use the workspace the credential is scoped to unless `--workspace`, `RFABRIC_WORKSPACE` or the profile names one:

| CI | Identity token |
| --- | --- |
| GitHub Actions | requested for the printed audience; the job needs `permissions: id-token: write` |
| GitLab CI | an `id_tokens:` entry named `RFABRIC_ID_TOKEN` with `aud:` the printed audience |
| Bitbucket Pipelines | `oidc: audiences:` on the step with the printed audience (`BITBUCKET_STEP_OIDC_TOKEN`) |
| any other | `RFABRIC_ID_TOKEN` |

A refused exchange prints the token's issuer and audience and the audience expected. A credential with a secret uses `RFABRIC_CLIENT_ID` and `RFABRIC_CLIENT_SECRET`.

### `rfabric sim run`

`rfabric sim run <suite>` takes a sim suite id, a slug (its latest published version in the workspace) or `slug@version`. The suite's protocol decides whether the verdict gates. `--preflight` prints the plan, the image checks and every blocker without launching.

In GitHub Actions, GitLab CI, Bitbucket Pipelines, Jenkins, CircleCI, Buildkite and Azure Pipelines the launch records the CI build: repository, commit built, build id, pipeline page, git ref, pull request and its head commit. Each `--ci-*` flag (`--ci-repository`, `--ci-commit`, `--ci-build-id`, `--ci-pipeline-url`, `--ci-ref`, `--ci-pull-request`, `--ci-pull-request-url`, `--ci-head-commit`, `--ci-destination-merged`) overrides its field. Without `--idempotency-key` the launch is keyed on the pipeline run and attempt: a retried step returns the same job, a new attempt launches a new one. `rfabric evaluation-job ls --ci-commit <sha>` and `--ci-head-commit <sha>` find the jobs of a commit.

With `--wait` the command prints the report summary, writes `--junit` and `--markdown` (a scorecard for pull request comments and job summaries), and exits with the verdict; `--wait-timeout` bounds the wait (default `2h`; the job keeps running). With `--output json` the printed report carries `failedCases`: every failed or inconclusive case-side of the report's JUnit document, with its run, cell, scenario, seed and reason. SIGINT or SIGTERM during the wait cancels the job; during the launch it cancels the job when the launch carries an idempotency key (`--idempotency-key`, or the CI default). `rfabric eval run --wait` exits the same way. `rfabric help exit-codes` prints the exit codes.

### `rfabric artifact-build register`

`rfabric artifact-build register <repository>@sha256:<digest> [--weights <dir|file>] [--model <mdl_id>] [--model-name <name>] [--source-ref <ref>]` turns a built image into a ready `model_release` artifact in one idempotent command: it reads the manifest from the registry (with your Docker login) or, for a reference without a registry host, from the local Docker engine, uploads only what the build lacks and waits until the artifact is ready. The artifact is identified by the model, the image digest and the weights digest: a rerun returns it unchanged. The build attestation records `--source-ref`, else the CI commit, else the image reference.

## Coding agents

rFabric runs a remote [Model Context Protocol](https://modelcontextprotocol.io) server at `https://api.rfabric.io/mcp`. On first use your agent opens the browser for you to sign in to rFabric with OAuth and authorize it. Register it with your agent, e.g. `claude mcp add --transport http rfabric https://api.rfabric.io/mcp`.

Its three tools - `search_operations`, `describe_operation` and `call_operation` - reach every rFabric API operation.

Agent skills in [`skills/`](skills) teach an agent a workflow with the CLI and the MCP tools:

- [`sim-asset-build`](skills/sim-asset-build/SKILL.md) - sim asset builds: from a prompt and a robot to reviewed, qualified simulation assets, and the robot models they need, imported from the asset catalog or a GitHub or Hugging Face repository.

## Documentation

- Full CLI reference: <https://docs.rfabric.io/cli>
- Platform docs: <https://docs.rfabric.io>

## Issues & support

Report bugs and request features in this repo's [issue tracker](https://github.com/rfabric/cli/issues).
