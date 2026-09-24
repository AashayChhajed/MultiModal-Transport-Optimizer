#!/usr/bin/env bash
# =============================================================================
# start-all.sh - start the whole Multi-Modal Transportation Optimizer stack
# =============================================================================
#
# Starts the ML prediction service, the Spring Boot backend and the Next.js
# frontend together, with one shared, validated environment.
#
# Usage (run from anywhere, Git Bash on Windows):
#
#   ./scripts/start-all.sh              # start everything and follow the logs
#   ./scripts/start-all.sh --detach     # start in the background and exit
#   ./scripts/start-all.sh check        # pre-flight only: validate env + tools
#   ./scripts/start-all.sh db           # test the database credentials only
#   ./scripts/start-all.sh sql "..."    # run SQL against the database (see below)
#   ./scripts/start-all.sh status       # what is running / reachable
#   ./scripts/start-all.sh stop         # stop everything this script started
#   ./scripts/start-all.sh restart      # stop, then start again
#
# The `sql` command executes whatever SQL you pass it, inside one transaction
# (rolled back if anything fails). Treat it like psql: point it at the database
# you actually intend to change.
#
# Flags:
#   --detach         Leave services running in the background
#   --skip-install   Do not run npm ci / pip install, even if deps look stale
#   --no-follow      Same as --detach
#   -h, --help       Show this help
#
# Environment resolution (first match wins, real shell env always wins):
#   1. variables already exported in your shell
#   2. ./.env                (single source of truth for the whole stack)
#   3. ./backend/.env        (also auto-loaded by Spring itself)
#   4. ./frontend/.env.local (Next.js local overrides)
#
# Anything still missing gets a safe local default, so a missing or partially
# filled env file cannot break the build. Only real DB credentials are required,
# and the script tells you exactly what to fix before it starts anything.
#
# Logs:  logs/<service>.log     PIDs: logs/pids/<service>.pid   (both gitignored)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ML_DIR="$ROOT_DIR/ml"
BACKEND_DIR="$ROOT_DIR/backend"
FRONTEND_DIR="$ROOT_DIR/frontend"

RUN_DIR="$ROOT_DIR/logs"
PID_DIR="$RUN_DIR/pids"
ML_VENV="$ML_DIR/.venv"

ROOT_ENV="$ROOT_DIR/.env"
BACKEND_ENV="$BACKEND_DIR/.env"
FRONTEND_ENV="$FRONTEND_DIR/.env.local"

SERVICES=(ml backend frontend)

# --- output helpers ----------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'
  C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'
else
  C_RESET=; C_INFO=; C_OK=; C_WARN=; C_ERR=; C_BOLD=
fi

log()   { printf '%s[stack]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()    { printf '%s  [ok]%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn()  { printf '%s  [!!]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()   { printf '%s  [xx]%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }
title() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# Print the comment block at the top of this file until the first code line.
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

# --- argument parsing --------------------------------------------------------
COMMAND="start"
DETACH=0
SKIP_INSTALL=0
SQL_ARGS=()
AFTER_SQL=0

for arg in "$@"; do
  if [ "$AFTER_SQL" = 1 ]; then
    SQL_ARGS+=("$arg")
    continue
  fi
  case "$arg" in
    sql)                             COMMAND="sql"; AFTER_SQL=1 ;;
    start|stop|restart|status|check|db) COMMAND="$arg" ;;
    --detach|--no-follow)            DETACH=1 ;;
    --skip-install)                  SKIP_INSTALL=1 ;;
    -h|--help)                       usage; exit 0 ;;
    *) die "unknown argument '$arg' (try --help)" ;;
  esac
done

# --- platform detection ------------------------------------------------------
IS_WINDOWS=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

# Pick the Maven executable once, so every command reports it the same way.
resolve_maven() {
  if have mvn; then
    MVN_CMD=(mvn)
  elif [ -x "$BACKEND_DIR/mvnw" ]; then
    MVN_CMD=("$BACKEND_DIR/mvnw")
  else
    die "neither 'mvn' nor backend/mvnw is available"
  fi
}

# Newest PostgreSQL driver jar in the local Maven repository (the backend
# downloads it on the first build - no extra dependency needed).
find_pg_driver() {
  local repo="${MAVEN_REPO:-${HOME:-}/.m2}/repository/org/postgresql/postgresql"
  [ -d "$repo" ] || { printf '%s' ""; return 0; }
  ls -1 "$repo"/*/postgresql-[0-9]*.jar 2>/dev/null |
    grep -v -- '-sources\|-javadoc' | sort -V | tail -1
}

# Resolve that jar into PG_JAR, converting to a Windows path when needed
# (java.exe cannot read /e/... paths) and downloading dependencies if absent.
resolve_pg_jar() {
  local jar
  jar="$(find_pg_driver)"
  if [ -z "$jar" ]; then
    resolve_maven
    log "PostgreSQL driver not in ~/.m2 yet - fetching backend dependencies"
    (cd "$BACKEND_DIR" && "${MVN_CMD[@]}" -q dependency:resolve) || die "could not fetch backend dependencies"
    jar="$(find_pg_driver)"
    [ -n "$jar" ] || die "PostgreSQL driver still not found after resolving dependencies"
  fi
  [ -f "$jar" ] || die "PostgreSQL driver jar not found: $jar"

  PG_JAR="$jar"
  if [ "$IS_WINDOWS" = 1 ] && have cygpath; then
    PG_JAR="$(cygpath -w "$jar")"
  fi
}

# --- env file loading --------------------------------------------------------
# Parsed line by line instead of `source`d: values like
# "jdbc:...&channelBinding=require" contain characters bash would re-interpret
# (and CRLF line endings from Windows editors would leak into every value).
load_env_file() {
  local file="$1" line key val
  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                                   # tolerate CRLF
    case "$line" in ''|'#'*) continue ;; esac               # blank / comment
    case "$line" in *=*) ;; *) continue ;; esac             # not KEY=VALUE
    key="${line%%=*}"
    val="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    case "$key" in [A-Za-z_][A-Za-z0-9_]*) ;; *) continue ;; esac
    case "$val" in                                          # strip quotes
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    case "$val" in *[![:space:]]*) ;; *) continue ;; esac   # skip empty values
    [ -n "${!key:-}" ] && continue                          # real env wins
    export "$key=$val"
  done < "$file"
}

ensure_env_files() {
  if [ ! -f "$ROOT_ENV" ] && [ ! -f "$BACKEND_ENV" ]; then
    cp "$BACKEND_DIR/.env.example" "$BACKEND_ENV" 2>/dev/null &&
      log "created backend/.env from backend/.env.example"
  fi
  if [ ! -f "$FRONTEND_ENV" ] && [ -f "$FRONTEND_DIR/.env.local.example" ]; then
    cp "$FRONTEND_DIR/.env.local.example" "$FRONTEND_ENV" 2>/dev/null &&
      log "created frontend/.env.local from frontend/.env.local.example"
  fi
}

load_env() {
  load_env_file "$ROOT_ENV"
  load_env_file "$BACKEND_ENV"
  load_env_file "$FRONTEND_ENV"
}

# --- resolved configuration (fill gaps so nothing has to guess) --------------
resolve_config() {
  ML_PORT="${ML_SERVICE_PORT:-5000}"
  BACKEND_PORT="${SERVER_PORT:-8080}"
  FRONTEND_PORT="${FRONTEND_PORT:-3000}"

  export ML_SERVICE_PORT="$ML_PORT"
  export ML_SERVICE_URL="${ML_SERVICE_URL:-http://localhost:$ML_PORT}"
  export ML_SERVICE_TIMEOUT="${ML_SERVICE_TIMEOUT:-5000}"
  export CORS_ALLOWED_ORIGINS="${CORS_ALLOWED_ORIGINS:-http://localhost:$FRONTEND_PORT}"
  # A production origin in .env would make the local frontend's API calls fail
  # CORS, so always allow the local frontend origin as well.
  case ",$CORS_ALLOWED_ORIGINS," in
    *",http://localhost:$FRONTEND_PORT,"*) ;;
    *)
      export CORS_ALLOWED_ORIGINS="$CORS_ALLOWED_ORIGINS,http://localhost:$FRONTEND_PORT"
      log "added http://localhost:$FRONTEND_PORT to CORS_ALLOWED_ORIGINS for local development"
      ;;
  esac
  export APP_SEED_ENABLED="${APP_SEED_ENABLED:-true}"
  export NEXT_PUBLIC_BACKEND_URL="${NEXT_PUBLIC_BACKEND_URL:-http://localhost:$BACKEND_PORT}"

  # A docker-compose style host name cannot resolve from the local machine.
  case "$ML_SERVICE_URL" in
    *ml-service*)
      warn "ML_SERVICE_URL='$ML_SERVICE_URL' looks like a Docker host name;"
      warn "using http://localhost:$ML_PORT for local runs instead"
      export ML_SERVICE_URL="http://localhost:$ML_PORT"
      ;;
  esac
}

# --- validation --------------------------------------------------------------
validate_env() {
  local missing="" v
  for v in DB_URL DB_USERNAME DB_PASSWORD; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done

  if [ -n "$missing" ]; then
    printf '\n' >&2
    warn "database settings are missing:$missing"
    warn "Add them to backend/.env (or .env at the project root), for example:"
    warn "  DB_URL=jdbc:postgresql://your-host/neondb?sslmode=require"
    warn "  DB_USERNAME=your_db_user"
    warn "  DB_PASSWORD=your_db_password"
    die "refusing to start the backend without database credentials"
  fi

  # The exact mistake that produced "'url' must start with \"jdbc\"".
  case "$DB_URL" in
    jdbc:*) ;;
    *) die "DB_URL must start with 'jdbc:' - got '${DB_URL%%:*}...'. Include the jdbc: prefix, e.g. jdbc:postgresql://host/db?sslmode=require" ;;
  esac

  case "$DB_USERNAME" in
    your_user|your_db_username) die "DB_USERNAME is still the placeholder value - set the real NeonDB user in backend/.env" ;;
  esac
  case "$DB_PASSWORD" in
    ""|your_password|your_db_password) die "DB_PASSWORD is still the placeholder value - set the real NeonDB password in backend/.env" ;;
  esac

  # Credentials in both places drift apart; that is a silent-failure trap.
  case "$DB_URL" in
    *user=*|*password=*)
      warn "DB_URL contains inline user=/password= parameters."
      warn "Those are easy to leave stale, and Spring's DB_USERNAME/DB_PASSWORD"
      warn "take precedence over them. Remove them from DB_URL and keep the"
      warn "credentials only in DB_USERNAME / DB_PASSWORD."
      ;;
  esac
}

# --- prerequisites -----------------------------------------------------------
check_prereqs() {
  title "Checking prerequisites"
  local problems=0

  if have java; then
    local jv major
    jv="$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')"
    major="${jv:-0}"
    case "$major" in ''|*[!0-9]*) major=0 ;; esac
    if [ "$major" -ge 21 ] 2>/dev/null; then
      ok "java $jv"
    else
      warn "java 21+ required, found '${jv:-unknown}'"; problems=$((problems + 1))
    fi
  else
    warn "java not found on PATH"; problems=$((problems + 1))
  fi

  if have mvn; then
    MVN_CMD=(mvn)
    ok "maven $(mvn -v 2>/dev/null | head -1 | awk '{print $3}')"
  elif [ -x "$BACKEND_DIR/mvnw" ]; then
    MVN_CMD=("$BACKEND_DIR/mvnw")
    ok "maven wrapper (mvnw)"
  else
    warn "neither 'mvn' nor backend/mvnw is available"; problems=$((problems + 1))
  fi

  if have node && have npm; then
    ok "node $(node --version), npm $(npm --version)"
  else
    warn "node/npm not found on PATH"; problems=$((problems + 1))
  fi

  if have python3; then
    PYTHON_BOOT=python3
  elif have python; then
    PYTHON_BOOT=python
  else
    PYTHON_BOOT=""
  fi
  if [ -n "$PYTHON_BOOT" ] && "$PYTHON_BOOT" -c 'import sys' >/dev/null 2>&1; then
    ok "$("$PYTHON_BOOT" --version 2>&1)"
  else
    PYTHON_BOOT=""
    warn "a working python 3 interpreter was not found on PATH"; problems=$((problems + 1))
  fi

  if have curl; then
    ok "curl available"
  else
    warn "curl not found - health checks will be skipped"; problems=$((problems + 1))
  fi

  [ "$problems" -eq 0 ] || die "$problems prerequisite(s) missing - fix the items above first"
}

# --- dependency installation -------------------------------------------------
hash_files() {
  if have sha256sum; then cat "$@" | sha256sum | cut -d' ' -f1
  elif have shasum; then cat "$@" | shasum -a 256 | cut -d' ' -f1
  else date +%s
  fi
}

venv_python() {
  if [ -x "$ML_VENV/Scripts/python.exe" ]; then printf '%s' "$ML_VENV/Scripts/python.exe"
  elif [ -x "$ML_VENV/bin/python" ]; then printf '%s' "$ML_VENV/bin/python"
  else printf '%s' ""; fi
}

install_deps() {
  title "Preparing dependencies"

  # Frontend: only when node_modules is missing or the lockfile changed.
  if [ ! -d "$FRONTEND_DIR/node_modules" ]; then
    log "installing frontend dependencies (this can take a minute)"
    if [ -f "$FRONTEND_DIR/package-lock.json" ]; then
      (cd "$FRONTEND_DIR" && npm ci --no-audit --no-fund) || die "npm ci failed"
    else
      (cd "$FRONTEND_DIR" && npm install --no-audit --no-fund) || die "npm install failed"
    fi
    ok "frontend dependencies installed"
  else
    ok "frontend node_modules present"
  fi

  # ML: dedicated venv so the global interpreter is never touched.
  if [ -z "$(venv_python)" ]; then
    log "creating Python venv at ml/.venv"
    "$PYTHON_BOOT" -m venv "$ML_VENV" || die "failed to create the Python venv (is the venv module available?)"
  fi
  local py stamp want have_stamp
  py="$(venv_python)"
  [ -n "$py" ] || die "could not locate the venv python"

  stamp="$ML_VENV/.requirements.sha256"
  want="$(hash_files "$ML_DIR/requirements.txt" "$ML_DIR/service/requirements.txt")"
  have_stamp="$(cat "$stamp" 2>/dev/null || true)"

  if [ "$want" != "$have_stamp" ]; then
    log "installing ML dependencies (this can take a few minutes the first time)"
    "$py" -m pip install --disable-pip-version-check -q --upgrade pip >/dev/null 2>&1 || true
    "$py" -m pip install --disable-pip-version-check -q -r "$ML_DIR/service/requirements.txt" ||
      die "pip install failed for ml/service/requirements.txt"
    printf '%s' "$want" > "$stamp"
    ok "ML dependencies installed"
  else
    ok "ML dependencies up to date"
  fi

  [ -f "$ML_DIR/models/eta_model.joblib" ] ||
    warn "ml/models/eta_model.joblib is missing - the ML service will fail to start"

  # Backend: maven resolves the rest, but a warm build catches errors here
  # rather than 40 lines into the startup log.
  if [ ! -d "$BACKEND_DIR/target/classes" ]; then
    log "compiling backend (mvn -q test-compile)"
    (cd "$BACKEND_DIR" && "${MVN_CMD[@]}" -q test-compile) || die "backend compilation failed - see the output above"
    ok "backend compiled"
  else
    ok "backend target/classes present"
  fi
}

# --- process helpers ---------------------------------------------------------
log_file() { printf '%s/%s.log' "$RUN_DIR" "$1"; }
pid_file() { printf '%s/%s.pid' "$PID_DIR" "$1"; }

read_pid() {
  local pf; pf="$(pid_file "$1")"
  [ -f "$pf" ] || return 1
  local pid; pid="$(cat "$pf" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  printf '%s' "$pid"
}

is_running() {
  local pid; pid="$(read_pid "$1")" || return 1
  kill -0 "$pid" 2>/dev/null
}

port_of() {
  case "$1" in
    ml) printf '%s' "${ML_PORT:-5000}" ;;
    backend) printf '%s' "${BACKEND_PORT:-8080}" ;;
    frontend) printf '%s' "${FRONTEND_PORT:-3000}" ;;
  esac
}

# Git Bash pids are its own ids, not Windows pids: passing one straight to
# taskkill would target an unrelated Windows process. `ps` reports the real
# Windows pid in the WINPID column.
winpid_of() {
  ps -p "$1" 2>/dev/null | awk 'NR == 2 { print $4 }' | tr -d '[:space:]'
}

kill_tree() {
  local pid="$1" wp
  [ -n "$pid" ] || return 0
  if [ "$IS_WINDOWS" = 1 ]; then
    wp="$(winpid_of "$pid")"
    case "$wp" in ''|*[!0-9]*) wp="" ;; esac
    # /T also stops the java/node/python children of mvn and npm
    if [ -n "$wp" ]; then
      taskkill //F //T //PID "$wp" >/dev/null 2>&1 || true
    fi
    kill -9 "$pid" >/dev/null 2>&1 || true   # fall back to the Git Bash pid
  else
    pkill -TERM -P "$pid" >/dev/null 2>&1 || true
    kill -TERM "$pid" >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || return 0
      sleep 1
    done
    pkill -KILL -P "$pid" >/dev/null 2>&1 || true
    kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
}

# 0 = something is listening, 1 = nothing is (connection refused / DNS fail)
# A timeout means we connected but the app did not answer in time - the port is
# still taken, which is exactly what this check needs to report.
port_busy() {
  local rc=0
  curl -s -o /dev/null --max-time 3 "http://localhost:$1" 2>/dev/null || rc=$?
  case "$rc" in
    6|7) return 1 ;;   # could not resolve host, or nothing is listening
    *)   return 0 ;;   # answered, or connected and was still busy
  esac
}

check_ports() {
  title "Checking ports"
  local pair name port pid
  for pair in "ml:$ML_PORT" "backend:$BACKEND_PORT" "frontend:$FRONTEND_PORT"; do
    name="${pair%%:*}"; port="${pair#*:}"
    if is_running "$name"; then
      warn "$name is already running (pid $(read_pid "$name")) - run './scripts/start-all.sh restart'"
      die "refusing to start a second copy"
    fi
    if port_busy "$port"; then
      die "port $port is already in use by another process - free it or run './scripts/start-all.sh stop'"
    fi
    ok "port $port free"
  done
}

start_service() {
  local name="$1" dir="$2"; shift 2
  local lf pf
  lf="$(log_file "$name")"
  pf="$(pid_file "$name")"

  : > "$lf"
  ( cd "$dir" && exec "$@" ) >> "$lf" 2>&1 &
  local pid=$!
  printf '%s' "$pid" > "$pf"
  log "started $name (pid $pid) - logs: logs/$name.log"
}

# Maps known startup failures to the actual cause, because Maven's summary
# message ("Process terminated with exit code: 1") hides it.
diagnose_log() {
  local name="$1" lf; lf="$(log_file "$name")"
  [ -f "$lf" ] || return 0

  if grep -q "password authentication failed" "$lf" 2>/dev/null; then
    warn "$name: the database rejected the credentials for user '${DB_USERNAME:-?}'."
    warn "Reset the password in the Neon console, update DB_PASSWORD in backend/.env,"
    warn "then verify with './scripts/start-all.sh db' before starting the stack again."
    return 0
  fi
  if grep -q "must start with \"jdbc\"" "$lf" 2>/dev/null; then
    warn "$name: spring.datasource.url was not a JDBC URL - check the jdbc: prefix in DB_URL."
    return 0
  fi
  if grep -q "Process terminated with exit code" "$lf" 2>/dev/null; then
    warn "$name: the JVM reported a fatal error. Relevant lines:"
    grep -aE "Caused by:|ERROR:" "$lf" | head -5 >&2 || true
    return 0
  fi
  if grep -q "Could not resolve placeholder" "$lf" 2>/dev/null; then
    warn "$name: a required environment variable is unset:"
    grep -o "Could not resolve placeholder '[^']*'" "$lf" | tail -3 >&2 || true
    return 0
  fi
  if grep -q "Address already in use" "$lf" 2>/dev/null; then
    warn "$name: its port was already taken."
    return 0
  fi
  if grep -q "ModuleNotFoundError\|ImportError" "$lf" 2>/dev/null; then
    warn "$name: a Python dependency is missing - rerun with --skip-install removed."
    return 0
  fi
}

# A service can start fine and still have a broken database connection (the
# backend only warns about that). Report it without pretending startup failed.
note_runtime_issues() {
  local name="$1" lf; lf="$(log_file "$name")"
  [ -f "$lf" ] || return 0
  if grep -q "password authentication failed" "$lf" 2>/dev/null; then
    warn "$name is up, but the database rejected its credentials for '${DB_USERNAME:-?}'"
    warn "data endpoints (shipments, optimization, dashboard) will fail until you"
    warn "update DB_PASSWORD with a fresh Neon password and restart"
  elif grep -q "Connection refused\|UnknownHostException" "$lf" 2>/dev/null; then
    warn "$name is up, but the database host is unreachable - check DB_URL"
  fi
}

# 0 = ready, 1 = process died, 2 = timed out
# The per-request timeout must comfortably exceed the slowest page render: the
# Next.js dashboard takes ~2s to render (it calls the backend), so a probe that
# gives up at 2s can lose the race against a request that then succeeds anyway.
wait_for_url() {
  local name="$1" url="$2" timeout="$3"
  local pid start; pid="$(read_pid "$name")" || return 1
  start=$SECONDS

  while :; do
    if curl -s -o /dev/null --max-time 20 "$url" 2>/dev/null; then return 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then return 1; fi
    if [ $((SECONDS - start)) -ge "$timeout" ]; then return 2; fi
    sleep 1
  done
}
show_failure() {
  local name="$1" reason="$2" lf; lf="$(log_file "$name")"
  printf '\n' >&2
  warn "$name $reason"
  diagnose_log "$name"
  warn "last lines of logs/$name.log:"
  printf '%s\n' "------------------------------------------------------------------" >&2
  tail -n 30 "$lf" >&2 2>/dev/null || true
  printf '%s\n' "------------------------------------------------------------------" >&2
  cleanup            # do not leave half a stack running behind a failure
  die "stack startup aborted"
}

# Wait for a service and hard-fail (with diagnosis) if it is not usable.
await_service() {
  local name="$1" url="$2" timeout="$3" label="$4" rc
  wait_for_url "$name" "$url" "$timeout"
  rc=$?
  case "$rc" in
    0) ok "$name ready -> $label" ;;
    1) show_failure "$name" "exited during startup" ;;
    2) show_failure "$name" "did not answer on $label within ${timeout}s" ;;
    *) show_failure "$name" "could not be checked (unexpected state $rc)" ;;
  esac
}

# --- commands ----------------------------------------------------------------
cmd_check() {
  ensure_env_files
  load_env
  resolve_config
  validate_env
  check_prereqs
  title "Configuration"
  ok "DB_URL      -> $(printf '%s' "${DB_URL%%\?*}")"
  ok "DB_USERNAME -> $DB_USERNAME"
  ok "backend     -> http://localhost:$BACKEND_PORT  (cors: $CORS_ALLOWED_ORIGINS)"
  ok "frontend    -> http://localhost:$FRONTEND_PORT (api: $NEXT_PUBLIC_BACKEND_URL)"
  ok "ml service  -> http://localhost:$ML_PORT       (url used by backend: $ML_SERVICE_URL)"
  ok "seeding     -> $APP_SEED_ENABLED $( [ "$APP_SEED_ENABLED" = "false" ] || printf '(set APP_SEED_ENABLED=false in .env to skip)' )"
  if [ "$SKIP_INSTALL" -eq 0 ]; then
    install_deps
  fi
  printf '\n'
  ok "pre-flight passed - './scripts/start-all.sh' should start cleanly"
}

cmd_db() {
  ensure_env_files
  load_env
  resolve_config
  validate_env

  have java || die "java not found on PATH - it is needed to run the database check"
  resolve_pg_jar

  title "Checking database credentials"
  if java -cp "$PG_JAR" "$ROOT_DIR/scripts/CheckDb.java"; then
    printf '\n'
    ok "database is reachable - './scripts/start-all.sh' should start the backend"
  else
    printf '\n'
    die "database check failed - fix backend/.env, then re-run './scripts/start-all.sh db'"
  fi
}

# Runs every argument as one SQL statement inside a single transaction.
cmd_sql() {
  [ ${#SQL_ARGS[@]} -gt 0 ] ||
    die "no SQL given - usage: ./scripts/start-all.sh sql \"SELECT * FROM city\""

  ensure_env_files
  load_env
  resolve_config
  validate_env

  have java || die "java not found on PATH - it is needed to run SQL"
  resolve_pg_jar

  title "Running SQL against the database configured in backend/.env"
  if java -cp "$PG_JAR" "$ROOT_DIR/scripts/DbSql.java" "${SQL_ARGS[@]}"; then
    ok "done"
  else
    die "SQL failed (nothing was changed - the transaction was rolled back)"
  fi
}

# A service can pass its readiness check and then die a second later - for
# example the backend boots, then its startup seeder fails against a stale
# database schema. Catch that before declaring success.
verify_stack() {
  local name code
  log "confirming all three services are still up"
  sleep 5

  for name in "${SERVICES[@]}"; do
    is_running "$name" || show_failure "$name" "exited right after startup"
  done

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        "http://localhost:$BACKEND_PORT/cities" 2>/dev/null)"
  case "$code" in
    200) ok "backend serving data (GET /cities -> 200)" ;;
    000) show_failure backend "stopped answering after startup" ;;
    *)
      show_failure backend "cannot read from the database (GET /cities -> HTTP $code)" ;;
  esac
}

cmd_start() {
  ensure_env_files
  load_env
  resolve_config
  validate_env
  check_prereqs
  check_ports
  [ "$SKIP_INSTALL" -eq 1 ] || install_deps

  mkdir -p "$RUN_DIR" "$PID_DIR"

  title "Starting services"

  ML_PYTHON="$(venv_python)"
  [ -n "$ML_PYTHON" ] || die "ml/.venv is missing - run without --skip-install to create it"
  start_service ml "$ML_DIR" "$ML_PYTHON" service/app.py
  await_service ml "http://localhost:$ML_PORT/health" 90 "http://localhost:$ML_PORT/health"

  start_service backend "$BACKEND_DIR" "${MVN_CMD[@]}" -q spring-boot:run
  await_service backend "http://localhost:$BACKEND_PORT/" 240 "http://localhost:$BACKEND_PORT"
  note_runtime_issues backend

  start_service frontend "$FRONTEND_DIR" npm run dev -- --port "$FRONTEND_PORT"
  await_service frontend "http://localhost:$FRONTEND_PORT/" 180 "http://localhost:$FRONTEND_PORT"

  verify_stack

  title "Stack is up"
  printf '  frontend   http://localhost:%s\n' "$FRONTEND_PORT"
  printf '  backend    http://localhost:%s\n' "$BACKEND_PORT"
  printf '  ml service http://localhost:%s/health\n' "$ML_PORT"
  printf '  logs       %s/*.log\n' "$RUN_DIR"

  if [ "$DETACH" -eq 1 ]; then
    printf '\n  running in the background - stop with: ./scripts/start-all.sh stop\n\n'
    return 0
  fi
  printf '\n  following logs - press Ctrl+C to stop everything\n'
  follow_logs
}

TAIL_PIDS=()
CLEANED_UP=0
stop_all() {
  title "Stopping services"
  local name pid port i
  for name in frontend backend ml; do
    port="$(port_of "$name")"
    if is_running "$name"; then
      pid="$(read_pid "$name")"
      kill_tree "$pid"
      rm -f "$(pid_file "$name")"
      # give the port a moment to be released before reporting success
      for i in 1 2 3 4 5 6 7 8 9 10; do
        port_busy "$port" || break
        sleep 1
      done
      if port_busy "$port"; then
        warn "$name stopped (pid $pid) but port $port is still answering"
      else
        ok "stopped $name (pid $pid)"
      fi
    else
      rm -f "$(pid_file "$name")"
      log "$name: not running"
    fi
  done
}

cleanup() {
  [ "$CLEANED_UP" -eq 1 ] && return 0
  CLEANED_UP=1
  local tp
  for tp in ${TAIL_PIDS[@]+"${TAIL_PIDS[@]}"}; do
    kill "$tp" >/dev/null 2>&1 || true
  done
  stop_all
}

follow_logs() {
  local name lf prefix
  for name in "${SERVICES[@]}"; do
    lf="$(log_file "$name")"
    printf -v prefix '%-10s' "[$name]"
    tail -n +1 -f "$lf" 2>/dev/null | sed -u "s/^/$prefix /" &
    TAIL_PIDS+=($!)
  done

  trap 'printf "\n"; cleanup; exit 0' INT TERM
  trap 'cleanup' EXIT

  local pid
  while :; do
    for name in "${SERVICES[@]}"; do
      pid="$(read_pid "$name")" || continue
      if ! kill -0 "$pid" 2>/dev/null; then
        printf '\n' >&2
        warn "$name exited unexpectedly"
        diagnose_log "$name"
        warn "last lines of logs/$name.log:"
        tail -n 20 "$(log_file "$name")" >&2 2>/dev/null || true
        exit 1
      fi
    done
    sleep 2
  done
}

cmd_stop() {
  load_env
  resolve_config
  stop_all
  local name port
  for name in "${SERVICES[@]}"; do
    port="$(port_of "$name")"
    if port_busy "$port"; then
      warn "something is still answering on port $port (started outside this script?)"
    fi
  done
  ok "done"
}

cmd_status() {
  load_env
  resolve_config
  title "Status"
  local name url port pid
  for name in "${SERVICES[@]}"; do
    case "$name" in
      ml)       port="$ML_PORT";       url="http://localhost:$ML_PORT/health" ;;
      backend)  port="$BACKEND_PORT";  url="http://localhost:$BACKEND_PORT/" ;;
      frontend) port="$FRONTEND_PORT"; url="http://localhost:$FRONTEND_PORT/" ;;
    esac
    pid="$(read_pid "$name" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      if curl -s -o /dev/null --max-time 20 "$url" 2>/dev/null; then
        ok "$name: running (pid $pid), reachable on port $port"
      else
        warn "$name: process alive (pid $pid) but not answering on port $port yet"
      fi
    elif port_busy "$port"; then
      warn "$name: not started by this script, but port $port is in use"
    else
      warn "$name: not running"
    fi
  done
}

case "$COMMAND" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_stop; rm -f "$PID_DIR"/*.pid 2>/dev/null; cmd_start ;;
  status)  cmd_status ;;
  check)   cmd_check ;;
  db)      cmd_db ;;
  sql)     cmd_sql ;;
esac
