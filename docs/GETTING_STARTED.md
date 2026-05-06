# Getting Started with ONEX Platform

This guide walks through setting up the full ONEX platform from scratch.

## Prerequisites

Install the following before proceeding:

| Tool | Minimum Version | Install |
|------|----------------|---------|
| Python | 3.12+ | [python.org](https://www.python.org/downloads/) |
| Node.js | 20+ | [nodejs.org](https://nodejs.org/) |
| uv | Latest | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Git | Latest | [git-scm.com](https://git-scm.com/) |

**Optional** (only if you plan to run local infra services):

| Tool | Install |
|------|---------|
| Docker + Docker Compose | [docker.com](https://docs.docker.com/get-docker/) |

The top-level `omnibase` installer never invokes Docker. Local
infrastructure services (Postgres, Redpanda, Valkey, Keycloak, Infisical)
are owned by `repos/omnibase_infra/` and are opt-in — see
[Step 4: (optional) Start local infra](#step-4-optional-start-local-infra).

## Step 1: Clone and Install

```bash
git clone https://github.com/OmniNode-ai/omnibase.git
cd omnibase
make install
```

This will:
- Clone all ONEX repositories into `repos/`
- Run `uv sync` for each Python repo (creates virtual environments, installs dependencies)
- Run `npm install` for the omnidash dashboard
- Create a `.env` file from the template

Docker is **not required** for any step above. If you only want the `onex`
CLI and to run unit tests, you can stop after Step 1.

## Step 2: Configure Environment

Edit `.env` with your configuration (only needed if you'll run infra
services in Step 4):

```bash
# At minimum, set a Postgres password
POSTGRES_PASSWORD=your-secure-password
```

## Step 3: Start Development

```bash
make dev
```

This starts the omnidash Next.js development server on port 3000 and shows
available `onex` CLI commands. (Without local infra running, the dashboard
will not have a backend to talk to — see Step 4 to bring those up.)

## Step 4: (optional) Start local infra

Local infrastructure services live in `repos/omnibase_infra/` and are run
from there:

```bash
cd repos/omnibase_infra

make up              # core: Postgres (5436), Redpanda (19092), Valkey (16379), Infisical
make up-auth         # add Keycloak
make seed-keycloak   # reconcile Keycloak clients (requires ~/.omnibase/.env)
make status          # show running containers
```

The `repos/omnibase_infra/Makefile` detects a missing or stopped Docker
daemon and emits an actionable error rather than failing with a stack
trace. See `repos/omnibase_infra/docs/getting-started/full-platform.md` for
the full bootstrap sequence including Infisical seeding.

## Verifying the Installation

```bash
# Check cloned repo versions
make status

# Run the test suite
make test
```

`make test` works without Docker — only repos that need infra (e.g.,
integration tests in `omninode_infra` that probe Postgres) are gated
behind `@pytest.mark.skipif(not _pg_reachable(), ...)` and skip cleanly.

## Common Operations

### Updating to Latest

```bash
make update
```

Runs `git pull --ff-only` across all repos.

### Stopping Local Infra

```bash
cd repos/omnibase_infra && make down
```

### Running Tests

```bash
# All repos
make test

# Single repo
cd repos/omnibase_core && uv run pytest tests/ -v
```

### Using the onex CLI

```bash
cd repos/omnibase_core
uv run onex --help
```

## Architecture Overview

The ONEX platform is a distributed node-based system:

- **omnibase_core** provides the core contract model, node execution engine, and CLI
- **omnibase_infra** owns local infrastructure (Postgres, Redpanda, Valkey, Keycloak) and runtime services — also the only place Docker / Compose lives
- **omnibase_spi** defines the service provider interface that nodes implement
- **omniclaude** integrates Claude Code as an autonomous agent with hooks and skills
- **omnidash** is the real-time analytics dashboard (Next.js)
- **omniintelligence** provides AI-powered analysis nodes (intent detection, drift, review)
- **omnimemory** handles document ingestion and semantic search
- **onex_change_control** enforces governance and drift detection

## Troubleshooting

### Local infra containers won't start

Run from the `omnibase_infra` repo and let its Makefile diagnose:

```bash
cd repos/omnibase_infra && make status
```

If `make up` reports `ERROR: docker daemon is not running`, follow the
remediation it prints (Docker Desktop on macOS, `systemctl start docker`
on Linux). If containers come up but ports collide, check what else is on
the same ports:

```bash
lsof -i :5436    # Postgres
lsof -i :19092   # Redpanda
lsof -i :16379   # Valkey
lsof -i :28080   # Keycloak
```

### uv sync fails

Ensure Python 3.12+ is installed and accessible:

```bash
python3 --version
uv --version
```

### npm install fails for omnidash

Ensure Node.js 20+ is installed:

```bash
node --version
npm --version
```
