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

## rFabric agent

`rfabric agent` starts the rFabric agent: a coding agent in your terminal that does what you may do on rFabric, as you, through the rFabric MCP server of the active profile, and asks you before every change. It has no shell unless you start it with `--with-shell`; its file tools stay inside the directory you start it in, and it moves file bytes only to upload and download URLs that rFabric issued in the session. Start it in a project directory: it refuses your home directory, a filesystem root, the CLI's configuration and cache directories, a directory whose `.env` or `.env.*` sets `OMP_*` or `PI_*` keys, and a directory whose `.omp/tools/` or `.omp/plugins/` holds modules (the agent would run them).

With `--with-shell` the agent can also run shell commands, so it can do the whole task for you. Every command asks first. An approved command runs as you, in your own environment: your signed-in `rfabric` CLI, Docker, cloud CLIs, git and SSH work as in your terminal. It can read any file you can and reach any network, so approve only commands you would run yourself.

```bash
rfabric agent                              # interactive session for the active profile
rfabric agent --print "List my workspaces" # one prompt, no UI; changes are refused
rfabric agent --continue                   # continue the last session; --resume [<id>] reopens one
rfabric agent --with-shell                 # also let the agent run shell commands, each one approved by you
rfabric agent update                       # install the newest agent release
rfabric agent update --version 0.1.0       # install exactly that release, older ones included
```

- The first `rfabric agent` downloads the newest agent release and checks it against its published SHA-256 checksums. The CLI itself does not grow. Once a day `rfabric agent` tells you when a newer release is available; `rfabric agent update` installs it.
- The agent needs no `rfabric auth login`. Until you have signed in, it puts `/mcp reauth rfabric` in its prompt: press Enter and your browser opens to sign in to rFabric and authorize `rFabric agent`.
- You bring your own model provider account: sign in with `/login` inside the agent, or keep the provider's API key (for example `ANTHROPIC_API_KEY`) in your environment.
- Each CLI profile (`--profile`) has its own agent sessions, rFabric sign-in and model provider sign-in. `rfabric doctor` reports the installed agent.

## Coding agents

rFabric runs a remote [Model Context Protocol](https://modelcontextprotocol.io) server at `https://api.rfabric.io/mcp`. On first use your agent opens the browser for you to sign in to rFabric with OAuth and authorize it. Register it with your agent, e.g. `claude mcp add --transport http rfabric https://api.rfabric.io/mcp`.

Its three tools - `search_operations`, `describe_operation` and `call_operation` - reach every rFabric API operation.

Agent skills teach an agent rFabric workflows that span several operations, such as `sim-asset-build` (from a prompt and a robot to reviewed, qualified simulation assets). They live in [rfabric/skills](https://github.com/rfabric/skills), whose plugin `rfabric` gives Claude Code and Codex the skills and the `rfabric` MCP server in one install. The rFabric agent ships with them.

## Documentation

- Full CLI reference: <https://docs.rfabric.io/cli>
- Platform docs: <https://docs.rfabric.io>

## Issues & support

Report bugs and request features in this repo's [issue tracker](https://github.com/rfabric/cli/issues).
