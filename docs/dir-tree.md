# Directory tree

```
exar-api/
├── db.md                      # PostgreSQL schema reference
├── Dockerfile                 # Go API image
├── docker-compose.yml         # postgres + API stack
├── run-on-docker.ps1          # Local or SSH deploy script
├── .docker/
│   └── stack.manifest.json    # Image tags, container names, ports
├── docs/
│   ├── description.md         # Project overview
│   ├── endpoints.md           # REST endpoint reference
│   ├── dir-tree.md            # This file
│   └── modules/
│       └── docker.md          # Docker deployment notes
├── cmd/server/main.go         # HTTP server entry point
└── internal/                  # handlers, auth, database, models, jalali
```
