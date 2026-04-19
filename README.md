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

# Any POSIX (curl)
curl -fsSL https://raw.githubusercontent.com/rfabric/cli/main/install.sh | sh

# Debian / Ubuntu (apt)
curl -1sLf https://dl.cloudsmith.io/public/rfabric/release/setup.deb.sh | sudo -E bash
sudo apt install rfabric

# RHEL / Fedora (yum / dnf)
curl -1sLf https://dl.cloudsmith.io/public/rfabric/release/setup.rpm.sh | sudo -E bash
sudo yum install rfabric

# Node.js ecosystem
npm install -g @rfabric/cli
```

Pre-release builds are available via `@next` on npm and the `rfabric/rc` channel on Cloudsmith.

## Quick start

```bash
rfabric config init     # writes ~/.config/rfabric/config.yaml with local/dev/staging/production profiles
rfabric auth login      # OAuth device flow
rfabric data ls         # list datasets
rfabric --help          # full command tree
```

Every command supports `--help`, `--output {json,yaml,table,tsv,value}`, and `--profile {local,dev,staging,production}`.

## Documentation

- Full CLI reference: <https://docs.rfabric.io/cli>
- Platform docs: <https://docs.rfabric.io>

## Issues & support

Report bugs and request features in this repo's [issue tracker](https://github.com/rfabric/cli/issues).
