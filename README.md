# rfabric

The terminal-native interface to the [rFabric](https://rfabric.io) robotics lifecycle platform. Manage data, training, models, releases, deployments, fleets, and operations from the command line.

- Single static binary, ~10ms startup, no runtime dependencies
- linux / macOS / Windows on amd64 + arm64
- Structured output (`json`, `yaml`, `table`, `tsv`, `value`) for scripting
- OAuth device flow for humans, client credentials for CI

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

## Coding agents

rFabric runs a remote [Model Context Protocol](https://modelcontextprotocol.io) server at `https://api.rfabric.io/mcp`. On first use your agent opens the browser for you to sign in to rFabric with OAuth and authorize it. Register it with your agent, e.g. `claude mcp add --transport http rfabric https://api.rfabric.io/mcp`.

Its three tools - `search_operations`, `describe_operation` and `call_operation` - reach every rFabric API operation.

Agent skills in [`skills/`](skills) teach an agent a workflow with the CLI and the MCP tools:

- [`sim-asset-build`](skills/sim-asset-build/SKILL.md) - sim asset builds: from a prompt and a robot to reviewed, qualified simulation assets.

## Documentation

- Full CLI reference: <https://docs.rfabric.io/cli>
- Platform docs: <https://docs.rfabric.io>

## Issues & support

Report bugs and request features in this repo's [issue tracker](https://github.com/rfabric/cli/issues).
