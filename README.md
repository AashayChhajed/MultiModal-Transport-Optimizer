# Multi-Modal Transportation Cost & Delivery Optimizer

A full-stack logistics optimization platform that computes the most cost-effective, time-efficient, and eco-friendly delivery routes using multiple transportation modes (road, rail, air, sea).

Built with Next.js + Spring Boot + PostgreSQL + Python ML Service.

---

## Tech Stack

Frontend
- Next.js 16 (React 19)
- Tailwind CSS
- shadcn/ui

Backend
- Spring Boot 4.0.2 (Java 21)
- Spring Data JPA / Hibernate
- Maven

Database
- PostgreSQL (NeonDB in production)

ML Service
- Python 3.11
- Flask
- XGBoost
- scikit-learn

---

## Architecture

```
Frontend (Next.js)          :3000
       ↓
Spring Boot Backend (Java)  :8080
       ↓
Python ML Service (Flask)   :5000
       ↓
XGBoost ETA Model
```

The backend remains the primary application server. The Python ML service is a lightweight sidecar responsible only for ETA predictions using a trained XGBoost model.

---

## Project Structure

```
multimodal-transport-optimizer/
├── backend/                    # Spring Boot backend
│   ├── src/main/java/com/optimizer/backend/
│   │   ├── Controller/         # REST controllers
│   │   ├── Service/            # business logic, cost calculator
│   │   ├── graph/              # Dijkstra / A* pathfinders
│   │   ├── ml/                 # ML integration (client, service, DTOs)
│   │   ├── Configuration/      # CORS + data seeding
│   │   └── ...
│   ├── src/main/resources/application.properties
│   ├── .env.example            # backend env template
│   └── Dockerfile
├── frontend/                   # Next.js frontend
│   ├── app/                    # pages (dashboard, shipments, optimization, routes)
│   ├── lib/api.ts              # backend API client
│   ├── .env.local.example      # frontend env template
│   └── package.json
├── ml/                         # Python ML pipeline & service
│   ├── service/                # Flask inference service (+ its own requirements.txt)
│   ├── models/                 # trained XGBoost model (eta_model.joblib)
│   ├── tests/                  # Python test suite
│   ├── eta_pipeline.py         # training pipeline
│   └── Dockerfile
├── scripts/
│   └── start-all.sh            # start / stop the whole stack with one command
├── docker-compose.yml          # backend + ml service containers
├── .env.example                # root env template (docker compose + scripts)
├── DEPLOYMENT_GUIDE.md         # production / Render deployment
└── README.md
```

---

## Prerequisites

Required:

| Tool | Version | Notes |
|------|---------|-------|
| Java JDK | 21 | `java -version` must report 21+ |
| Maven | 3.9+ | or use the bundled `backend/mvnw` wrapper |
| Node.js | **20.9+** | required by Next.js 16 (`npm --version` also needed) |
| Python | 3.11+ | on Windows the command is `python` (there is no `python3`) |
| Git | any | |
| curl | any | used for the health checks in `scripts/start-all.sh` |

Optional:
- Docker & Docker Compose (containerized backend + ML service)
- A PostgreSQL/NeonDB database you can reach

On Windows, run the shell script from **Git Bash** (or WSL). The script relies on
POSIX shell behaviour and works from Windows, macOS, and Linux.

---

## Quick Start

### 1. Clone the repository

```bash
git clone <repository-url>
cd multimodal-transport-optimizer
```

### 2. Create the environment files

Copy the templates; the start script also does this for you if they are missing.

```bash
cp .env.example backend/.env                       # backend/database settings
cp frontend/.env.local.example frontend/.env.local # frontend API URL
```

Edit `backend/.env` (or a root `.env`) and fill in your database credentials:

```dotenv
DB_URL=jdbc:postgresql://your-host/neondb?sslmode=require
DB_USERNAME=your_db_user
DB_PASSWORD=your_db_password
CORS_ALLOWED_ORIGINS=http://localhost:3000
```

`DB_URL` **must** start with `jdbc:` — see [Troubleshooting](#troubleshooting).

### 3. Validate the setup

```bash
./scripts/start-all.sh check
```

This verifies the tools, parses and validates the env files, and installs
dependencies only when they are missing or stale. It starts nothing.

### 4. Start the whole stack

```bash
./scripts/start-all.sh
```

The script starts the ML service, then the backend, then the frontend — waiting
for each one to answer before starting the next — and then follows the combined
logs. Press **Ctrl+C** to stop everything.

| URL | Service |
|-----|---------|
| http://localhost:3000 | Frontend |
| http://localhost:8080 | Backend API |
| http://localhost:5000/health | ML service |

### 5. Verify

```bash
curl http://localhost:5000/health          # {"model_loaded":true,"status":"UP"}
curl http://localhost:8080/cities          # seeded city list
curl -I http://localhost:3000              # HTTP 200
```

Open http://localhost:3000 and create a shipment to exercise the full
frontend → backend → ML flow.

---

## Environment Configuration

### Where configuration is read from

| File | Used by | Committed? |
|------|---------|-----------|
| `.env` (project root) | `docker compose`, `scripts/start-all.sh` | no — gitignored |
| `backend/.env` | Spring Boot (auto-loaded), `scripts/start-all.sh` | no — gitignored |
| `frontend/.env.local` | Next.js dev/build (auto-loaded) | no — gitignored |
| `*.env.example` | templates to copy from | yes |

Resolution order for the start script (**first match wins**):

1. variables already exported in your shell
2. `.env` (project root)
3. `backend/.env`
4. `frontend/.env.local`

Values that are still missing get a safe local default, so a partially filled env
file cannot break startup. Real environment variables (Render, Docker) always
take precedence over file values.

### Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `DB_URL` | PostgreSQL JDBC URL — must start with `jdbc:` | — (required) |
| `DB_USERNAME` | Database username | — (required) |
| `DB_PASSWORD` | Database password | — (required) |
| `CORS_ALLOWED_ORIGINS` | Comma-separated allowed origins | `http://localhost:3000` |
| `APP_SEED_ENABLED` | Seed cities, transport modes and routes on startup | `true` |
| `NEXT_PUBLIC_BACKEND_URL` | Backend base URL used by the frontend | `http://localhost:8080` |
| `NEXT_PUBLIC_API_URL` | Alias for the above (older setups) | falls back to `localhost:8080` |
| `ML_SERVICE_URL` | ML service URL used by the backend | `http://localhost:5000` |
| `ML_SERVICE_TIMEOUT` | ML request timeout (ms) | `5000` |
| `ML_SERVICE_PORT` | Port the Flask service binds | `5000` |
| `ML_SERVICE_DEBUG` | Flask debug mode | `false` |
| `SERVER_PORT` | Backend HTTP port | `8080` |
| `FRONTEND_PORT` | Frontend port used by `start-all.sh` | `3000` |

Notes:

- The start script **appends `http://localhost:3000`** to `CORS_ALLOWED_ORIGINS`
  if it is missing, so a production-only origin in your env file cannot break
  local API calls.
- `NEXT_PUBLIC_*` variables are inlined by Next.js at build time; the API client
  also falls back to `http://localhost:8080`, so it never builds `undefined/...`
  URLs.
- Keep credentials in `DB_USERNAME` / `DB_PASSWORD` only. An inline
  `?user=...&password=...` in `DB_URL` is easily forgotten and silently drifts
  out of sync with the two variables above.
- Never commit `.env` files.

---

## Running the Services

### Option A — all services together (recommended)

```bash
./scripts/start-all.sh              # start everything, follow the logs (Ctrl+C stops all)
./scripts/start-all.sh --detach     # start in the background and return
./scripts/start-all.sh status       # show what is running and reachable
./scripts/start-all.sh stop         # stop everything the script started
./scripts/start-all.sh restart      # stop, then start again
./scripts/start-all.sh check        # pre-flight validation only
./scripts/start-all.sh db           # test the database credentials only
./scripts/start-all.sh sql "SELECT ..."  # run SQL against the database
./scripts/start-all.sh --skip-install   # never run npm ci / pip install
```

What the script handles for you:

- creates env files from the `.env.example` templates when they are missing
- validates `DB_URL` / `DB_USERNAME` / `DB_PASSWORD` before starting anything and
  refuses to continue with an actionable message if something is wrong
- creates `ml/.venv` and installs ML dependencies (only when missing or changed),
  and runs `npm ci` when `frontend/node_modules` is absent
- compiles the backend when `backend/target/classes` is absent
- waits for health before moving on, then re-checks a few seconds later that
  every service is still alive and that the backend can actually read data
  (`GET /cities`) — a service that passes its health check and dies right after
  (a failing startup seeder, for example) is caught instead of reported as up
- fails fast if port 3000 / 8080 / 5000 is already taken or a service is already
  running
- on failure surfaces the real cause from the log (Maven's "Process terminated
  with exit code: 1" hides it) and shuts down everything it started

The `db` and `sql` commands exist because most Windows setups have no `psql`:
they use the PostgreSQL driver jar Maven already downloaded and the credentials
in `backend/.env`. `db` connects twice — with your `DB_URL` as written, then
with any inline `user=`/`password=` removed — so it tells you *which* value is
wrong. `sql` runs every argument as one statement inside a single transaction
and rolls back on the first failure; treat it like psql and point it at the
intended database.

Logs: `logs/ml.log`, `logs/backend.log`, `logs/frontend.log`
PIDs: `logs/pids/<service>.pid` — both gitignored.

### Option B — start each service manually

**Backend**

```bash
cd backend
cp .env.example .env      # first time only, then fill in your DB credentials
mvn spring-boot:run
```

`mvn spring-boot:run` loads `backend/.env` automatically (via
`spring.config.import`). `./mvnw spring-boot:run` works too, unless the Maven
wrapper distribution cannot be written to `~/.m2` — in that case use the system
`mvn`. Backend: http://localhost:8080

**Frontend**

```bash
cd frontend
cp .env.local.example .env.local   # first time only
npm install
npm run dev
```

Frontend: http://localhost:3000

**ML service**

```bash
cd ml
python -m venv .venv
source .venv/Scripts/activate      # Git Bash on Windows
# source .venv/bin/activate        # macOS / Linux
pip install -r service/requirements.txt
python service/app.py              # must be run from the ml/ directory
```

ML service: http://localhost:5000 — the model is loaded once at startup, and the
service exits immediately if `models/eta_model.joblib` is missing or corrupted
rather than serving degraded predictions.

---

## Database Seeding

With `APP_SEED_ENABLED=true` (the default) the backend seeds on startup:

- 20 Indian cities with coordinates
- transport modes: `ROAD`, `RAIL`, `AIR` (with cost/km, speed, carbon per ton-km)
- routes for every ordered city pair and every mode (20 × 19 × 3 = 1140 routes,
  distance computed with the haversine formula)

Seeding is idempotent: cities, modes and routes are matched by name/key and only
missing ones are inserted, so restarting the backend does not duplicate data. The
seeder also removes the unused `SEA` mode and its routes. Set
`APP_SEED_ENABLED=false` to skip seeding entirely (useful for a database that is
already populated).

Because Hibernate runs with `spring.jpa.hibernate.ddl-auto=update`, the backend
needs a working database connection **at startup** — an invalid password will
abort the boot rather than warn and continue.

---

## API Overview

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/cities` | list all cities |
| GET | `/shipments` | list shipments |
| POST | `/shipments` | create a shipment |
| GET | `/shipments/{id}` | get one shipment |
| POST | `/shipments/{id}/optimize?optimizationType=CHEAPEST&algorithm=ASTAR` | optimize a shipment |
| GET | `/shipments/{id}/compare?optimizationType=CHEAPEST` | compare A* vs Dijkstra |
| GET | `/optimization/{shipmentId}` | stored optimization result |
| GET | `/dashboard/stats` | dashboard aggregates |

Frontend pages: `/` (dashboard), `/create-shipment`, `/route`, `/route/[shipmentId]`,
`/optimization`, `/optimization/[shipmentId]`.

---

## Testing

```bash
# Backend (JUnit, H2 in-memory — no database needed)
cd backend && mvn test

# Frontend typecheck / production build
cd frontend && npx tsc --noEmit
cd frontend && npm run build

# Python ML tests
cd ml && pip install pytest && python -m pytest tests/ -v
```

The backend suite covers the cost calculator, the Dijkstra/A* pathfinders, the
objective function, transfer-time calculations, ETA client/service behaviour and
end-to-end optimization (99 tests). Python tests run offline and do not need a
running service.

---

## ML Service

The ML service provides ETA (Estimated Time of Arrival) predictions using a trained XGBoost model.

### Model Details

- Model type: XGBoost Regressor
- Training data: Synthetic dataset (3,000 records)
- Features: 12 (7 numerical + 5 categorical)
- XGBoost test R² ≈ 0.959, Test MAE ≈ 1.86 hours (on synthetic evaluation data)

> **Important:** The model is trained on synthetic data. Its accuracy does NOT represent real-world ETA performance. The metrics above are results on synthetic evaluation data only.

### API Endpoints

**POST /predict-eta**

Request:
```json
{
  "distance_km": 500,
  "shipment_weight_kg": 500,
  "departure_hour": 10,
  "day_of_week": 2,
  "month": 8,
  "source_city": "Istanbul",
  "destination_city": "Ankara",
  "transport_mode": "ROAD",
  "traffic_level": "MEDIUM",
  "weather_condition": "CLEAR",
  "transfer_count": 1,
  "historical_delay_rate": 0.10
}
```

Response:
```json
{
  "predicted_eta_hours": 13.91,
  "model": "XGBoost",
  "model_version": "1.0"
}
```

**GET /health**

Response:
```json
{
  "status": "UP",
  "model_loaded": true
}
```

### Model Features

Numerical: distance_km, shipment_weight_kg, departure_hour, day_of_week, month, transfer_count, historical_delay_rate

Categorical: source_city, destination_city, transport_mode, traffic_level, weather_condition

### Fallback Behavior

If the ML service is unavailable:
- Route optimization continues normally
- `predictedEtaHours` is null
- `etaPredictionAvailable` is false
- No fabricated fallback predictions are returned

The prediction is saved with the result (`optimization_result.predicted_eta_hours`)
at optimize time, so reloading `/optimization/[shipmentId]` still shows the ETA.
If the page says the ML service is offline, the prediction was unavailable when
that result was computed — run optimization again to retry. Check the service
any time with `curl http://localhost:5000/health`.

---

## Docker Setup

`docker-compose.yml` builds the **backend** and the **ML service** only; the
frontend runs on the host (or separately). Compose reads the root `.env`.

```bash
cp .env.example .env     # first time only, then fill in DB credentials
docker compose build
docker compose up
```

- Backend: http://localhost:8080
- ML service: http://localhost:5000
- Frontend: run separately (`cd frontend && npm run dev`) → http://localhost:3000

Inside the compose network the backend reaches the ML service as
`http://ml-service:5000` (set automatically by compose), and the ML container is
started first with a health check.

---

## Troubleshooting

### `'url' must start with "jdbc"` / `Could not resolve placeholder 'DB_URL'`

Spring could not resolve `spring.datasource.url`. Either `DB_URL` is unset, or the
value is missing the `jdbc:` prefix. Run `./scripts/start-all.sh check` to see the
resolved configuration, and make sure the file you edited is actually being read
(`.env` at the root or `backend/.env`).

### `BUILD FAILURE ... Process terminated with exit code: 1`

Maven only reports the wrapper message — the real cause is further up the log.
Look at `logs/backend.log` (or the last lines printed by the start script); the
script maps the common causes to an explanation for you.

### Frontend requests fail / URLs look like `undefined/shipments`

`NEXT_PUBLIC_BACKEND_URL` was not set when the frontend started. Use the start
script (it injects the variable), or copy `frontend/.env.local.example` to
`frontend/.env.local`. Remember these values are baked in at build time —
restart the dev server after changing them.

### CORS errors in the browser console

Add your frontend origin to `CORS_ALLOWED_ORIGINS`, e.g.
`CORS_ALLOWED_ORIGINS=http://localhost:3000`. A production-only origin in the env
file is a common cause; the start script appends the local origin automatically.

### `password authentication failed for user 'neondb_owner'`

The database rejected the credentials. Run `./scripts/start-all.sh db` — it
connects twice (with `DB_URL` as written, then with its inline credentials
removed) and reports which value is stale:

- **both rejected** → reset the password in the Neon console and update
  `DB_PASSWORD`
- **only the full URL fails** → the `user=`/`password=` embedded in `DB_URL` is
  stale. pgjdbc gives those inline parameters priority over
  `DB_USERNAME`/`DB_PASSWORD`, so Spring keeps sending the old password no
  matter what `DB_PASSWORD` says. Delete them from `DB_URL` and keep the
  credentials only in `DB_USERNAME` / `DB_PASSWORD`.

Note the backend aborts during startup in this case, because `ddl-auto=update`
needs a connection.

### `column "..." of relation "..." contains null values`

Hibernate's schema update wants to add a column as `NOT NULL`, but existing
rows have no value for it, so the `ALTER` is rejected. Hibernate only warns —
the app then dies later when the startup seeder queries the column. Add the
column yourself, backfill it, then tighten the constraint (one transaction):

```bash
./scripts/start-all.sh sql \
  "ALTER TABLE transport_mode ADD COLUMN carbon_per_ton_km double precision" \
  "UPDATE transport_mode SET carbon_per_ton_km = CASE name WHEN 'ROAD' THEN 0.062 WHEN 'RAIL' THEN 0.022 WHEN 'AIR' THEN 0.602 ELSE 0.062 END WHERE carbon_per_ton_km IS NULL" \
  "ALTER TABLE transport_mode ALTER COLUMN carbon_per_ton_km SET NOT NULL"
```

To see what a table actually contains:

```bash
./scripts/start-all.sh sql "SELECT * FROM transport_mode"
./scripts/start-all.sh sql "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema='public' ORDER BY table_name"
```

### `port 8080 is already in use` / `refusing to start a second copy`

Something else is bound to that port, often a previous run. Use
`./scripts/start-all.sh stop`, or
`./scripts/start-all.sh restart` if the stack was started by the script.

### `mv: cannot move ... Permission denied` from `./mvnw`

The Maven wrapper cannot write its distribution into `~/.m2`. Use the system
`mvn` (the start script prefers `mvn` and only falls back to `mvnw`).

### `ModuleNotFoundError` in the ML service

The ML dependencies are not installed in the interpreter you are using. Install
`ml/service/requirements.txt` into a virtual environment and use
`ml/.venv/Scripts/python.exe` (Windows) or `ml/.venv/bin/python`. Running
`./scripts/start-all.sh check` sets this up.

### `scripts/start-all.sh: line N: $'\r': command not found`

The script was checked out with CRLF line endings. `.gitattributes` forces LF for
`*.sh`; re-checkout the file or convert it (`dos2unix scripts/start-all.sh`).

---

## Known Limitations

- The ML model is trained on synthetic data — real-world accuracy is unknown
- ML feature defaults: traffic_level=MEDIUM, weather_condition=CLEAR, historical_delay_rate=0.10 (no real-time data yet)
- City names in ML requests use IDs (feature mapping to city names not yet implemented)
- No real-time traffic or weather integration

---

## Deployment

See [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) for the production setup (NeonDB
migration, Render backend, frontend build, environment variables).

---

## License

See repository for license details.
