# Docker deployment

Standalone API stack for `exar-api`.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the Go API binary |
| `docker-compose.yml` | `postgres` + `api` on external network `exar-net` |
| `.armin/docker-scripts/run-on-docker-local.ps1` | Local Docker daemon deploy (YAML-only) |
| `.armin/docker-scripts/run-on-docker-local.yaml` | Local stack settings |
| `.armin/docker-scripts/run-on-docker-server.ps1` | Remote SSH deploy (YAML-only) |
| `.armin/docker-scripts/run-on-docker-server.yaml` | Remote settings (`ssh` / `volume_dir` placeholders) |
| `.docker/stack.manifest.json` | `apiImageTag`, container name, ports |
| `run-on-docker.ps1` | Legacy root deploy script (prefer `.armin/docker-scripts/`) |

## Services

| Service | Container | Host port | Notes |
|---------|-----------|-----------|-------|
| `postgres` | `exar-postgres` | — | PostgreSQL 16; volume `exar-postgres-data` |
| `api` | `exar` | optional | Connects via `DATABASE_URL` to `postgres` |

Requires external Docker network `exar-net` (scripts create it if missing).

## Deploy

```powershell
# Local
.\.armin\docker-scripts\run-on-docker-local.ps1

# Remote (fill ssh + volume_dir in YAML first)
.\.armin\docker-scripts\run-on-docker-server.ps1
```

Local script sets `API_PUBLISH_PORT` empty so host `:8080` is not claimed when another stack uses it; the API stays on `exar-net` as `exar:8080`. Reach it via [exar-web](../exar-web) (e.g. `http://localhost:3082`) or a temporary host publish.

Compose override env vars used by the scripts: `API_IMAGE_TAG`, `API_PUBLISH_PORT`, `DOCKER_NETWORK`.
