---
ticket_id: OMN-10089
---

# Slim omnibase Makefile to Pass-Through (PR #2 Update)

> **For Claude:** small one-file change updating an existing PR.

**Goal:** Slim the `seed-keycloak` Makefile target in [`harsh-omni/omnibase#2`](https://github.com/harsh-omni/omnibase/pull/2) to a thin pass-through that calls `bash $(REPOS_DIR)/omnibase_infra/scripts/seed-keycloak.sh`. Revert the `--profile auth` additions on `docker-up`/`docker-down` since keycloak is now default-on after [`OmniNode-ai/omnibase_infra#1500`](https://github.com/OmniNode-ai/omnibase_infra/pull/1500). Result: zero Docker/Keycloak knowledge in the top-level distribution Makefile.

**Why:** Reviewer (jonahgabriel) flagged that the top-level `omnibase` repo is the user-facing distribution point and cannot assume Docker. All Docker-specific logic (`--profile auth`, `localhost:28080` polling, container names, `uv run` invocations, `--reset-bootstrap-admin` gating) belongs in `omnibase_infra`. The infra-side fix landed in PR #1500. This PR updates the omnibase side to consume it.

**Depends on:** `OmniNode-ai/omnibase_infra#1500` merging first.

## Files

- **Modify:** `Makefile` — replace ~40-line `seed-keycloak` recipe with a 6-line pass-through; revert `--profile auth` additions on `docker-up` and `docker-down`. Drop the `KC_URL` and `OMNIBASE_ENV_FILE` Make vars (callers can still set them as environment variables; the shell script reads them).

## Acceptance criteria

- `make seed-keycloak` invokes `bash repos/omnibase_infra/scripts/seed-keycloak.sh` and reports the script's exit code unchanged.
- Running `make seed-keycloak` when `omnibase_infra` is not cloned (or pre-PR-1500) produces a clear error pointing at `make update`.
- `make docker-up` no longer mentions `--profile auth`; keycloak still starts because of the omnibase_infra PR's compose change.
- The Makefile diff against `main` is significantly smaller than the current PR diff (the substantive logic moved out, not added).

## Out of scope

- OMN-10264 (CI mirror) — tracked separately. Reviewer accepted deferral with a tracking ticket.
- Adding `dod_evidence` block to PR body (separate item; needs a clean-clone transcript captured manually).
- Linking the PR body to the merged `OmniNode-ai/omnibase_infra#1500` SHA — done as part of this PR's body update, not a code change.

## Test plan

- [ ] `make seed-keycloak` against a running, freshly-started Keycloak — exit 0 + `op` JSON lines.
- [ ] `make seed-keycloak` re-run — all `op=unchanged`.
- [ ] `make docker-up && make docker-down` — verify keycloak starts (default-on per infra PR) and stops cleanly.
- [ ] `rm -rf repos/omnibase_infra && make seed-keycloak` — verify clear error pointing at `make update`.
