# exar-api

Go REST API for the shared expense tracker. Users authenticate with JWT, manage shops and item names, and record expenses with Persian calendar dates stored as Gregorian in PostgreSQL.

## Tech stack

- Go 1.22, Gin, pgx
- PostgreSQL 16
- Docker Compose for local and remote deploy via `run-on-docker.ps1`

## Run locally

```bash
go mod tidy
go run ./cmd/server
```

Set `DATABASE_URL` if PostgreSQL is not at the default connection string.

## Run with Docker

```powershell
.\run-on-docker.ps1
docker compose up --build
```

API base URL: `http://localhost:8080/exar/api/v1`

## Related repo

Frontend lives in [exar-web](../exar-web). The web container proxies `/api/*` to this API on the shared Docker network `exar-net`.
