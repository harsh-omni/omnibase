# ONEX Platform (omnibase)

One command to install the full ONEX node-based platform.

## Quick Start

```bash
git clone https://github.com/OmniNode-ai/omnibase.git
cd omnibase
make install
```

This clones all ONEX repositories, builds Python environments, installs Node
dependencies, and makes the `onex` CLI available. **No Docker required for
the install path** — Docker is only needed if you want to run local
infrastructure services (see "Optional: run local infra" below).

## What's Included

| Repository | Purpose |
|-----------|---------|
| omnibase_core | Core models, contracts, validators, CLI |
| omnibase_infra | Infrastructure services, Kafka, Postgres |
| omnibase_spi | Service provider interface protocols |
| omniclaude | Claude Code agent plugin, hooks, skills |
| omnidash | Next.js analytics dashboard |
| omniintelligence | Intelligence nodes: intent, drift, review |
| omnimemory | Document ingestion + semantic retrieval |
| omninode_infra | API service, k8s manifests |
| omniweb | Landing page |
| onex_change_control | Drift detection + governance |
| omnibase_compat | Shared structural package |

## Requirements

- Python 3.12+
- Node.js 20+
- [uv](https://docs.astral.sh/uv/) (Python package manager)
- Git

**Optional** (only if you plan to run local infra services):

- Docker + Docker Compose

## Usage

```bash
# Install everything (clone repos, build envs, install deps).
# Does NOT touch Docker.
make install

# Create .env from template (idempotent; safe to skip if you already have one).
make setup

# Start development servers (omnidash, onex CLI).
make dev

# Run tests across all Python repos.
make test

# Update all repos to latest main.
make update

# Show cloned repo versions.
make status

# (destructive) Remove all cloned repos.
make clean
```

## Optional: run local infra

Local infrastructure services (Postgres, Redpanda, Valkey, Keycloak,
Infisical, etc.) live in `repos/omnibase_infra/`. Docker is required to run
them. After `make install` completes, `cd` into that repo and use its
Makefile:

```bash
cd repos/omnibase_infra

make up              # core: postgres, redpanda, valkey, infisical
make up-auth         # add Keycloak (depends on core)
make seed-keycloak   # reconcile Keycloak clients
make status          # show running containers
make down            # stop core
```

The `repos/omnibase_infra/Makefile` detects a missing or stopped Docker
daemon and emits an actionable error rather than failing with a stack trace.

## Project Structure

```
omnibase/
├── README.md              # This file
├── Makefile               # All automation targets (no Docker)
├── install.sh             # One-command installer (no Docker)
├── .env.example           # Template environment file
├── repos.yaml             # Repository registry with metadata
└── docs/
    └── GETTING_STARTED.md # Detailed setup guide
```

## Environment Configuration

After installation, copy the example environment file and fill in your values:

```bash
cp .env.example .env
# Edit .env with your configuration
```

See [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) for detailed
configuration instructions.

## License

Proprietary - OmniNode AI
