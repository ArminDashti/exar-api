# Docker deployment

Standalone API stack for `exar-api`.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the Go API binary |
| `docker-compose.yml` | `postgres` + `api` on external network `exar-net` |
| `run-on-docker.ps1` | Local or SSH deploy script |
| `.docker/stack.manifest.json` | Image tag, container name, ports |

## Services

| Service | Container | Host port | Notes |
|---------|-----------|-----------|-------|
| `postgres` | `exar-postgres` | — | PostgreSQL 16; volume `exar-postgres-data` |
| `api` | `exar` | 8080 | Connects via `DATABASE_URL` to `postgres` |

Run the web UI from the separate `exar-web` repo on the same Docker network so nginx can proxy `/api/*` to `exar:8080`.
