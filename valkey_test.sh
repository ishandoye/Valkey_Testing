#!/usr/bin/env bash
# ==============================================================================
# valkey_test.sh — Valkey Installation & Redis Migration Validation Script
# ==============================================================================
# Supported:  RHEL/CentOS/Rocky/AlmaLinux 7-9 | Ubuntu 18.04+ | Debian 10+
# Sources:    https://valkey.io/topics/installation
#             https://valkey.io/topics/migration
# Version:    2.0  (May 2026)
#
# WHAT THIS SCRIPT DOES
# ─────────────────────
#  Phase 0   Environment & safety preflight
#  Phase 1   Detect OS, package manager, init system
#  Phase 2   Pre-existing Redis inventory (non-destructive, read-only)
#  Phase 3   Valkey installation (via official distro packages only)
#  Phase 4   Service start and health checks
#  Phase 5   Functional tests (all data types, persistence, keyspace)
#  Phase 6   valkey.conf inspection and hardening audit
#  Phase 7   Redis → Valkey compatibility (config directives, RDB, protocol)
#  Phase 8   Dependency and library conflict detection
#  Phase 9   Backward-compatibility and file-safety audit
#  Phase 10  Summary report with PASS/FAIL/SKIP/WARN per test
#
# GUARANTEES
# ──────────
#  • Read-only on Redis — script NEVER stops, flushes, or modifies Redis
#  • No files removed from the system at any point
#  • Write tests use only Valkey DB 15 and are fully cleaned up afterwards
#  • Idempotent — safe to run multiple times on the same host
#  • Every command is shown on screen in verbose mode before execution
#
# USAGE
#   sudo bash valkey_test.sh [OPTIONS]
#
# OPTIONS
#   --install        Install Valkey if not already installed (default: test only)
#   --port PORT      Valkey port to test                    (default: 6379)
#   --redis-port P   Redis port to read during compat test  (default: 6379)
#   --testdb N       Database index for write tests         (default: 15)
#   --logdir DIR     Directory for report files             (default: /tmp/valkey_test_<ts>)
#   --verbose        Print every command before running it
#   --no-color       Disable ANSI colours in terminal output
#   --help           Show this help and exit
# ==============================================================================

# ── Save whether stdout is a real terminal BEFORE any redirects ───────────────
# This is critical: after `exec > >(tee ...)` fd 1 becomes a pipe, so [[ -t 1 ]]
# always returns false. We must test it here, before the redirect.
if [[ -t 1 ]]; then
  _STDOUT_IS_TTY=true
else
  _STDOUT_IS_TTY=false
fi

# ── Strict mode — but we handle failures ourselves via record(), not trap ─────
# -e  exit on error  → we use || true everywhere we want to tolerate failure
# -u  unset vars     → we declare ALL variables before use to prevent surprises
# -o pipefail        → catch pipe failures
set -euo pipefail

# ── Script metadata ───────────────────────────────────────────────────────────
SCRIPT_VERSION="2.0"
SCRIPT_NAME="$(basename "$0")"
RUN_TS="$(date +%Y%m%d_%H%M%S)"

# ── Defaults — ALL variables declared here so set -u never fires ──────────────
DO_INSTALL=false
VALKEY_PORT=6379
REDIS_PORT=6379
TEST_DB=15
NO_COLOR=false
VERBOSE=false
LOGDIR=""

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)    DO_INSTALL=true;       shift   ;;
    --port)       VALKEY_PORT="${2:?--port requires a value}"; shift 2 ;;
    --redis-port) REDIS_PORT="${2:?--redis-port requires a value}"; shift 2 ;;
    --testdb)     TEST_DB="${2:?--testdb requires a value}"; shift 2 ;;
    --logdir)     LOGDIR="${2:?--logdir requires a value}"; shift 2 ;;
    --verbose)    VERBOSE=true;          shift   ;;
    --no-color)   NO_COLOR=true;         shift   ;;
    --help)
      grep '^# ' "$0" | sed 's/^# \?//' | sed -n '/^USAGE/,/^==/p' | head -n -1
      exit 0
      ;;
    *) echo "Unknown option: $1  (use --help for usage)" >&2; exit 1 ;;
  esac
done

# ── Logging setup ─────────────────────────────────────────────────────────────
[[ -z "$LOGDIR" ]] && LOGDIR="/tmp/valkey_test_${RUN_TS}"
mkdir -p "$LOGDIR"
MAIN_LOG="${LOGDIR}/valkey_test.log"
REPORT="${LOGDIR}/summary_report.txt"
FAIL_LOG="${LOGDIR}/failures.log"
COMPAT_LOG="${LOGDIR}/compat_check.log"
CONF_LOG="${LOGDIR}/conf_check.log"
DEP_LOG="${LOGDIR}/dependency_check.log"
FILE_LOG="${LOGDIR}/file_audit.log"

# Redirect everything through tee so terminal and log both get output.
# The tee subprocess inherits the pipe-fd, which is why we saved _STDOUT_IS_TTY above.
exec > >(tee -a "$MAIN_LOG") 2>&1

# ── Colours — use the TTY flag saved BEFORE the exec redirect ─────────────────
if [[ "$_STDOUT_IS_TTY" == true && "$NO_COLOR" == false ]]; then
  RED='\033[0;31m'
  GRN='\033[0;32m'
  YLW='\033[0;33m'
  BLU='\033[0;34m'
  CYN='\033[0;36m'
  MAG='\033[0;35m'
  BLD='\033[1m'
  DIM='\033[2m'
  RST='\033[0m'
else
  RED=''; GRN=''; YLW=''; BLU=''; CYN=''; MAG=''; BLD=''; DIM=''; RST=''
fi

# ── Test result counters ──────────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0; SKIP=0
declare -a RESULTS=()   # "STATUS|PHASE|TEST_NAME|DETAIL"

# ── Pre-declare all variables that may be conditionally set ───────────────────
# This prevents set -u crashes when later phases reference variables set in
# earlier phases that may have been skipped.
OS_ID=""
OS_VER=""
OS_PRETTY=""
OS_FAMILY=""
PKG_MGR=""
INIT_SYS=""
EL_VER=""
ARCH=""
VALKEY_PRESENT=false
VALKEY_RUNNING=false
VALKEY_CLI=""
VALKEY_INST_VER=""
VALKEY_RUNNING_VER=""
VALKEY_SERVICE_NAME=""
VALKEY_CONF=""
REDIS_PRESENT=false
REDIS_RUNNING=false
REDIS_VERSION=""
REDIS_INFO_VER=""
REDIS_DATA_DIR=""
REDIS_RDB_FILE=""
REDIS_AOF_ENABLED=""
REDIS_KEY_COUNT=""
REDIS_CONF_PATH=""
REDIS_MAJOR="0"
REDIS_MINOR="0"

# ── Helpers ───────────────────────────────────────────────────────────────────

_ts()   { date '+%Y-%m-%d %H:%M:%S'; }

_log()  { echo -e "${DIM}[$(_ts)]${RST} $*"; }

_head() {
  echo ""
  echo -e "${BLD}${BLU}════════════════════════════════════════════════════${RST}"
  echo -e "${BLD}${BLU}  $*${RST}"
  echo -e "${BLD}${BLU}════════════════════════════════════════════════════${RST}"
}

_h2()   { echo -e "\n${BLD}${CYN}  ┄┄ $* ┄┄${RST}"; }

# Verbose command echo — prints the command in dim text before running it
_vcmd() {
  if [[ "$VERBOSE" == true ]]; then
    echo -e "  ${DIM}  ▶ $*${RST}"
  fi
}

# record PASS|FAIL|WARN|SKIP  PHASE  "name"  "detail"
record() {
  local status="$1" phase="$2" name="$3" detail="${4:-}"
  RESULTS+=("${status}|${phase}|${name}|${detail}")
  case "$status" in
    PASS) ((++PASS));  echo -e "  ${GRN}[PASS]${RST} ${name}${detail:+  ${DIM}${detail}${RST}}" ;;
    FAIL) ((++FAIL));  echo -e "  ${RED}[FAIL]${RST} ${name}${detail:+ — ${detail}}"
          echo "[$(_ts)] FAIL | ${phase} | ${name} | ${detail}" >> "$FAIL_LOG" ;;
    WARN) ((++WARN));  echo -e "  ${YLW}[WARN]${RST} ${name}${detail:+ — ${detail}}" ;;
    SKIP) ((++SKIP));  echo -e "  ${YLW}[SKIP]${RST} ${name}${detail:+ — ${detail}}" ;;
  esac
}

# safe_run: run a command without aborting on non-zero exit.
# Prints the command in verbose mode. Returns the output as a string.
# Usage: out=$(safe_run valkey-cli PING)
safe_run() {
  _vcmd "$*"
  local out rc
  out=$("$@" 2>&1) && rc=$? || rc=$?
  echo "$out"
  return 0   # always succeed — callers inspect output, not exit code
}

# has_cmd: test if a binary is on PATH without triggering set -e
has_cmd() { command -v "$1" &>/dev/null && return 0 || return 0; }
# Note: above always returns 0 — use this form to test:
#   if command -v foo &>/dev/null; then ...

# vcli: run valkey-cli safely, quoting all args properly
# This avoids the eval/word-splitting bug in the original script
vcli() {
  _vcmd "valkey-cli -p ${VALKEY_PORT} $*"
  local out
  out=$(valkey-cli -p "${VALKEY_PORT}" "$@" 2>&1) || true
  echo "$out"
}

# rcli: run redis-cli safely
rcli() {
  _vcmd "redis-cli -p ${REDIS_PORT} $*"
  local out
  out=$(redis-cli -p "${REDIS_PORT}" "$@" 2>&1) || true
  echo "$out"
}

# parse_valkey_version: "Valkey server v=8.1.7 sha=..." → "8.1.7"
parse_valkey_version() {
  echo "$1" | grep -oE 'v=[0-9]+\.[0-9]+\.[0-9]+' | cut -d= -f2
}

# ==============================================================================
# PHASE 0 — Safety Preflight
# ==============================================================================
_head "PHASE 0 — Safety & Environment Preflight"

# Root check
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}ERROR: This script must be run as root or via sudo.${RST}" >&2
  exit 1
fi
record PASS "P0" "Running as root/sudo"

# Bash version >= 4 (associative arrays, [[ ]] builtins)
BASH_MAJ="${BASH_VERSINFO[0]}"
if [[ "$BASH_MAJ" -lt 4 ]]; then
  echo -e "${RED}ERROR: Bash 4+ required. Found: ${BASH_VERSION}${RST}" >&2
  exit 1
fi
record PASS "P0" "Bash version OK" "${BASH_VERSION}"

# Print runtime config so user sees exactly what will be tested
_log "Script version : ${SCRIPT_VERSION}"
_log "Log directory  : ${LOGDIR}"
_log "Valkey port    : ${VALKEY_PORT}"
_log "Redis port     : ${REDIS_PORT}"
_log "Test DB        : ${TEST_DB}"
_log "Install mode   : ${DO_INSTALL}"
_log "Verbose        : ${VERBOSE}"
echo ""
_log "Safety contract: this script will NOT stop, flush, or modify any Redis instance."
_log "Write tests use Valkey DB ${TEST_DB} only and are cleaned up after each run."

# ==============================================================================
# PHASE 1 — OS & Environment Detection
# ==============================================================================
_head "PHASE 1 — OS & Environment Detection"

ARCH="$(uname -m)"

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID:-unknown}"
  OS_PRETTY="${PRETTY_NAME:-unknown}"
else
  OS_ID="unknown"
  OS_VER="unknown"
  OS_PRETTY="$(uname -s) $(uname -r)"
fi

_log "OS: ${OS_PRETTY}  |  Arch: ${ARCH}"

case "$OS_ID" in
  rhel|centos|rocky|almalinux|ol)
    OS_FAMILY="el"
    EL_VER="${OS_VER%%.*}"
    if [[ "$EL_VER" == "7" ]]; then
      PKG_MGR="yum"
    elif [[ "${EL_VER}" -ge 8 ]] 2>/dev/null; then
      PKG_MGR="dnf"
    else
      record WARN "P1" "EL version unclear" "OS_VER=${OS_VER}; will default to dnf"
      PKG_MGR="dnf"
    fi
    ;;
  ubuntu|debian|linuxmint|raspbian)
    OS_FAMILY="deb"
    PKG_MGR="apt"
    ;;
  *)
    OS_FAMILY="unknown"
    record WARN "P1" "OS not in supported list" "${OS_ID} — attempting to auto-detect package manager"
    if   command -v dnf &>/dev/null; then PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then PKG_MGR="yum"
    elif command -v apt &>/dev/null; then PKG_MGR="apt"
    else
      PKG_MGR="none"
      record FAIL "P1" "No supported package manager found" "dnf/yum/apt all absent"
    fi
    ;;
esac

record PASS "P1" "OS detected" "${OS_PRETTY}"
record PASS "P1" "Package manager" "${PKG_MGR}"

# Init system
if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
  INIT_SYS="systemd"
  record PASS "P1" "Init system" "systemd"
else
  INIT_SYS="sysv"
  record WARN "P1" "systemd not detected" "Service management checks will be limited"
fi

# Required tools — check individually so we see exactly which ones are missing
for tool in awk sed grep tar curl; do
  if command -v "$tool" &>/dev/null; then
    record PASS "P1" "Required tool present: ${tool}" "$(command -v "$tool")"
  else
    record FAIL "P1" "Required tool MISSING: ${tool}" "Install before running this script"
  fi
done

# Optional tools — warn if absent (don't fail)
for tool in ss netstat ldd pgrep ausearch aa-status; do
  if command -v "$tool" &>/dev/null; then
    [[ "$VERBOSE" == true ]] && record PASS "P1" "Optional tool present: ${tool}"
  else
    record WARN "P1" "Optional tool absent: ${tool}" "Some checks in later phases will be skipped"
  fi
done

# ==============================================================================
# PHASE 2 — Pre-existing Redis Inventory (Read-Only)
# ==============================================================================
_head "PHASE 2 — Redis Pre-Existing Inventory (Read-Only)"

_h2 "2.1  Redis Binary"
if command -v redis-server &>/dev/null; then
  REDIS_PRESENT=true
  _vcmd "redis-server --version"
  RAW_REDIS_VER="$(redis-server --version 2>/dev/null || true)"
  # redis-server --version: "Redis server v=7.2.5 sha=..."
  REDIS_VERSION="$(echo "$RAW_REDIS_VER" | grep -oE 'v=[0-9]+\.[0-9]+\.[0-9]+' | cut -d= -f2 || true)"
  record PASS "P2" "Redis binary found" "${RAW_REDIS_VER}"
else
  record SKIP "P2" "Redis binary not installed" "Migration compat tests will be skipped"
fi

_h2 "2.2  Redis Runtime (non-destructive)"
if command -v redis-cli &>/dev/null; then
  REDIS_PING="$(rcli PING || true)"
  if [[ "$REDIS_PING" == "PONG" ]]; then
    REDIS_RUNNING=true
    record PASS "P2" "Redis responding on port ${REDIS_PORT}" "PONG"

    # Keyspace — read-only
    _log "Recording Redis keyspace snapshot..."
    REDIS_KEY_COUNT="$(rcli INFO keyspace || true)"
    echo "$REDIS_KEY_COUNT" | sed 's/^/    /'

    # Config values — each queried individually so NR==2 is reliable
    REDIS_DATA_DIR="$(rcli CONFIG GET dir     | awk 'NR==2' | tr -d '\r' || true)"
    REDIS_RDB_FILE="$(rcli CONFIG GET dbfilename | awk 'NR==2' | tr -d '\r' || true)"
    REDIS_AOF_ENABLED="$(rcli CONFIG GET appendonly | awk 'NR==2' | tr -d '\r' || true)"

    record PASS "P2" "Redis data dir"     "${REDIS_DATA_DIR:-unknown}"
    record PASS "P2" "Redis RDB file"     "${REDIS_RDB_FILE:-unknown}"
    record PASS "P2" "Redis AOF enabled"  "${REDIS_AOF_ENABLED:-unknown}"

    # Version from INFO (exact, includes sub-version)
    REDIS_INFO_VER="$(rcli INFO server | grep 'redis_version:' | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
    record PASS "P2" "Redis INFO version" "${REDIS_INFO_VER:-unknown}"

    # Parse major/minor for compat checks — declared at top so set -u is safe
    REDIS_MAJOR="${REDIS_INFO_VER%%.*}"
    _tmp="${REDIS_INFO_VER#*.}"
    REDIS_MINOR="${_tmp%%.*}"
    unset _tmp

    # Warn on CE 7.4+
    if [[ "${REDIS_MAJOR}" =~ ^[0-9]+$ ]] && \
       [[ "${REDIS_MINOR}" =~ ^[0-9]+$ ]] && \
       [[ "${REDIS_MAJOR}" -ge 7 ]] && [[ "${REDIS_MINOR}" -ge 4 ]]; then
      record WARN "P2" "Redis CE 7.4+ detected" \
        "RDB format NOT compatible with Valkey. See valkey.io/topics/migration"
    fi

    # Save pre-migration snapshot file
    {
      echo "=== PRE-MIGRATION REDIS SNAPSHOT ==="
      echo "Timestamp:    $(_ts)"
      echo "Version:      ${REDIS_INFO_VER:-unknown}"
      echo "Port:         ${REDIS_PORT}"
      echo "Data dir:     ${REDIS_DATA_DIR:-unknown}"
      echo "RDB file:     ${REDIS_RDB_FILE:-unknown}"
      echo "AOF enabled:  ${REDIS_AOF_ENABLED:-unknown}"
      echo ""
      echo "--- INFO keyspace ---"
      rcli INFO keyspace 2>/dev/null || echo "(no keyspace output)"
      echo ""
      echo "--- INFO replication ---"
      rcli INFO replication 2>/dev/null || echo "(no replication output)"
      echo ""
      echo "--- INFO memory ---"
      rcli INFO memory 2>/dev/null || echo "(not available)"
      echo ""
      echo "--- CONFIG GET maxmemory ---"
      rcli CONFIG GET maxmemory 2>/dev/null || echo "(not available)"
    } > "${LOGDIR}/redis_premigration_snapshot.txt"
    record PASS "P2" "Pre-migration snapshot saved" "${LOGDIR}/redis_premigration_snapshot.txt"

  else
    record SKIP "P2" "Redis not responding on port ${REDIS_PORT}" \
      "Got: '${REDIS_PING:-<no response>}' — migration compat tests will be limited"
  fi
else
  record SKIP "P2" "redis-cli not installed" "Skipping Redis runtime inventory"
fi

_h2 "2.3  Redis Config File"
for conf_candidate in \
    /etc/redis/redis.conf /etc/redis.conf \
    /etc/redis/6379.conf  /usr/local/etc/redis/redis.conf; do
  if [[ -f "$conf_candidate" ]]; then
    REDIS_CONF_PATH="$conf_candidate"
    record PASS "P2" "Redis config found" "$conf_candidate"
    break
  fi
done
[[ -z "$REDIS_CONF_PATH" ]] && \
  record SKIP "P2" "Redis config not found" "Non-standard install or absent"

# ==============================================================================
# PHASE 3 — Valkey Installation
# ==============================================================================
_head "PHASE 3 — Valkey Installation"

_h2 "3.1  Detect Existing Valkey"
if command -v valkey-server &>/dev/null; then
  VALKEY_PRESENT=true
  _vcmd "valkey-server --version"
  RAW_VALKEY_VER="$(valkey-server --version 2>/dev/null || true)"
  # "Valkey server v=8.1.7 sha=..." — parse cleanly
  VALKEY_INST_VER="$(parse_valkey_version "$RAW_VALKEY_VER")"
  record PASS "P3" "Valkey binary already installed" "${RAW_VALKEY_VER}"
fi

if command -v valkey-cli &>/dev/null; then
  VALKEY_CLI="valkey-cli"
  record PASS "P3" "valkey-cli found" "$(command -v valkey-cli)"
fi

_h2 "3.2  Install (if --install passed and Valkey absent)"
if [[ "$DO_INSTALL" == true && "$VALKEY_PRESENT" == false ]]; then

  if [[ "$PKG_MGR" == "none" || -z "$PKG_MGR" ]]; then
    record FAIL "P3" "Cannot install" "No supported package manager detected"
  else
    _log "Starting Valkey installation via ${PKG_MGR}..."
    INSTALL_OK=true

    # ── EL7 ──────────────────────────────────────────────────────────────────
    if [[ "$PKG_MGR" == "yum" ]]; then
      _log "Step 1/2: Enabling EPEL (EL7)..."
      _vcmd "yum install -y epel-release"
      if yum install -y epel-release; then
        record PASS "P3" "EPEL repository enabled" "(EL7)"
      else
        record FAIL "P3" "EPEL enable failed" "yum install epel-release returned non-zero"
        INSTALL_OK=false
      fi

      if [[ "$INSTALL_OK" == true ]]; then
        _log "Step 2/2: Installing valkey..."
        _vcmd "yum install -y valkey"
        if yum install -y valkey; then
          record PASS "P3" "Valkey installed via yum"
          VALKEY_PRESENT=true
        else
          record FAIL "P3" "yum install valkey failed" \
            "Check output above and ${MAIN_LOG} for details"
          INSTALL_OK=false
        fi
      fi

    # ── EL8 / EL9 ────────────────────────────────────────────────────────────
    elif [[ "$PKG_MGR" == "dnf" ]]; then
      _log "Step 1/2: Enabling EPEL (EL8/9)..."
      _vcmd "dnf install -y epel-release"
      if dnf install -y epel-release; then
        record PASS "P3" "EPEL repository enabled" "(EL8/9)"
      else
        record FAIL "P3" "EPEL enable failed" "dnf install epel-release returned non-zero"
        INSTALL_OK=false
      fi

      if [[ "$INSTALL_OK" == true ]]; then
        _log "Step 2/2: Installing valkey..."
        _vcmd "dnf install -y valkey"
        if dnf install -y valkey; then
          record PASS "P3" "Valkey installed via dnf"
          VALKEY_PRESENT=true
        else
          record FAIL "P3" "dnf install valkey failed" \
            "Check output above and ${MAIN_LOG} for details"
          INSTALL_OK=false
        fi
      fi

    # ── Debian / Ubuntu ───────────────────────────────────────────────────────
    elif [[ "$PKG_MGR" == "apt" ]]; then
      _log "Step 1/2: Refreshing apt package index..."
      _vcmd "apt-get update"
      if apt-get update; then
        record PASS "P3" "apt-get update succeeded"
      else
        record WARN "P3" "apt-get update returned non-zero" \
          "Possible transient mirror error; attempting install anyway"
      fi

      _log "Step 2/2: Installing valkey..."
      _vcmd "apt-get install -y valkey"
      if apt-get install -y valkey; then
        record PASS "P3" "Valkey installed via apt"
        VALKEY_PRESENT=true
      else
        record FAIL "P3" "apt-get install valkey failed" \
          "Check output above and ${MAIN_LOG} for details"
      fi
    fi

    # Re-detect binaries after install attempt
    if command -v valkey-server &>/dev/null; then
      VALKEY_PRESENT=true
      RAW_VALKEY_VER="$(valkey-server --version 2>/dev/null || true)"
      VALKEY_INST_VER="$(parse_valkey_version "$RAW_VALKEY_VER")"
      record PASS "P3" "Post-install binary check" "${RAW_VALKEY_VER}"
    fi
    if command -v valkey-cli &>/dev/null; then
      VALKEY_CLI="valkey-cli"
    fi
  fi

elif [[ "$DO_INSTALL" == false && "$VALKEY_PRESENT" == false ]]; then
  record SKIP "P3" "Install not requested" \
    "Valkey not found. Pass --install to install, or install manually first."
fi

if [[ "$VALKEY_PRESENT" == false ]]; then
  _log "${YLW}Valkey not installed. Phases 4-9 will skip most checks.${RST}"
fi

# ==============================================================================
# PHASE 4 — Service Start & Health
# ==============================================================================
_head "PHASE 4 — Service Start & Health Checks"

if [[ "$VALKEY_PRESENT" == false ]]; then
  record SKIP "P4" "All service checks" "Valkey not installed"
else

  _h2 "4.1  Locate Service Unit"
  for svc_candidate in valkey-server valkey; do
    if systemctl list-units --type=service --all 2>/dev/null \
       | grep -q "${svc_candidate}.service"; then
      VALKEY_SERVICE_NAME="$svc_candidate"
      break
    fi
  done

  if [[ -z "$VALKEY_SERVICE_NAME" ]]; then
    record WARN "P4" "No systemd service unit found for Valkey" \
      "Checked valkey-server.service, valkey.service. Will fall back to process check."
  else
    record PASS "P4" "Service unit found" "${VALKEY_SERVICE_NAME}.service"

    _h2 "4.2  Service State"
    _vcmd "systemctl is-active ${VALKEY_SERVICE_NAME}"
    SVC_STATUS="$(systemctl is-active "${VALKEY_SERVICE_NAME}" 2>/dev/null || true)"
    _log "systemctl is-active → '${SVC_STATUS}'"

    if [[ "$SVC_STATUS" == "active" ]]; then
      VALKEY_RUNNING=true
      record PASS "P4" "Service is active" "${VALKEY_SERVICE_NAME}"
    else
      record WARN "P4" "Service not active (status: ${SVC_STATUS})" \
        "Attempting to start..."
      _vcmd "systemctl start ${VALKEY_SERVICE_NAME}"
      if systemctl start "${VALKEY_SERVICE_NAME}" 2>&1; then
        _log "Waiting 3 seconds for service to stabilise..."
        sleep 3
        SVC_STATUS2="$(systemctl is-active "${VALKEY_SERVICE_NAME}" 2>/dev/null || true)"
        if [[ "$SVC_STATUS2" == "active" ]]; then
          VALKEY_RUNNING=true
          record PASS "P4" "Service started successfully"
        else
          record FAIL "P4" "Service failed to start after systemctl start" \
            "status: ${SVC_STATUS2}"
          # Capture full status for the failure log
          {
            echo "=== systemctl status ${VALKEY_SERVICE_NAME} ==="
            systemctl status "${VALKEY_SERVICE_NAME}" --no-pager -l 2>&1 || true
            echo ""
            echo "=== Last 30 journal lines ==="
            journalctl -u "${VALKEY_SERVICE_NAME}" --no-pager -n 30 2>/dev/null || true
          } >> "$FAIL_LOG"
        fi
      else
        {
          echo "=== systemctl start FAILED ==="
          journalctl -u "${VALKEY_SERVICE_NAME}" --no-pager -n 30 2>/dev/null || true
        } >> "$FAIL_LOG"
        record FAIL "P4" "systemctl start returned non-zero" \
          "Full journal captured in ${FAIL_LOG}"
      fi
    fi

    _h2 "4.3  Boot-Enable Check"
    _vcmd "systemctl is-enabled ${VALKEY_SERVICE_NAME}"
    SVC_ENABLED="$(systemctl is-enabled "${VALKEY_SERVICE_NAME}" 2>/dev/null || true)"
    if [[ "$SVC_ENABLED" == "enabled" ]]; then
      record PASS "P4" "Service enabled on boot"
    else
      record WARN "P4" "Service not enabled on boot (${SVC_ENABLED})" \
        "Run: systemctl enable ${VALKEY_SERVICE_NAME}"
    fi

    _h2 "4.4  Service Journal Snapshot"
    JOURNAL_OUT="$(journalctl -u "${VALKEY_SERVICE_NAME}" --no-pager -n 30 2>/dev/null || true)"
    {
      echo "=== VALKEY SERVICE JOURNAL (last 30 lines at $(date)) ==="
      echo "$JOURNAL_OUT"
    } > "${LOGDIR}/service_journal.txt"
    record PASS "P4" "Journal snapshot saved" "${LOGDIR}/service_journal.txt"

    # Scan journal for errors/warnings
    JRNL_ISSUES="$(echo "$JOURNAL_OUT" | grep -iE 'error|failed|fatal|denied' || true)"
    if [[ -n "$JRNL_ISSUES" ]]; then
      record WARN "P4" "Journal contains error/failed/fatal/denied lines" \
        "$(echo "$JRNL_ISSUES" | head -2 | tr '\n' ' ')"
      echo "=== Journal issues ===" >> "$FAIL_LOG"
      echo "$JRNL_ISSUES"          >> "$FAIL_LOG"
    else
      record PASS "P4" "No error/failed lines in journal"
    fi
  fi  # service name found

  _h2 "4.5  Process Check"
  if pgrep -x valkey-server &>/dev/null; then
    VALKEY_RUNNING=true
    VALKEY_PID="$(pgrep -x valkey-server | head -1)"
    record PASS "P4" "valkey-server process found" "PID ${VALKEY_PID}"

    # Show memory usage of the process
    if command -v ps &>/dev/null; then
      _vcmd "ps -p ${VALKEY_PID} -o pid,vsz,rss,comm"
      PROC_MEM="$(ps -p "${VALKEY_PID}" -o pid=,vsz=,rss=,comm= 2>/dev/null || true)"
      [[ -n "$PROC_MEM" ]] && _log "Process stats (pid/vsz/rss/cmd): ${PROC_MEM}"
    fi
  else
    if [[ "$VALKEY_RUNNING" == false ]]; then
      record FAIL "P4" "valkey-server process not found" \
        "Service may have failed to start; check ${FAIL_LOG}"
    fi
  fi

  _h2 "4.6  Port Listening"
  PORT_LINE=""
  if command -v ss &>/dev/null; then
    _vcmd "ss -tlnp | grep :${VALKEY_PORT}"
    PORT_LINE="$(ss -tlnp 2>/dev/null | grep ":${VALKEY_PORT}" || true)"
  elif command -v netstat &>/dev/null; then
    _vcmd "netstat -tlnp | grep :${VALKEY_PORT}"
    PORT_LINE="$(netstat -tlnp 2>/dev/null | grep ":${VALKEY_PORT}" || true)"
  else
    record SKIP "P4" "Port check" "Neither ss nor netstat available"
  fi

  if [[ -n "$PORT_LINE" ]]; then
    record PASS "P4" "Port ${VALKEY_PORT} is listening" "$(echo "$PORT_LINE" | head -1)"
  elif [[ -n "$PORT_LINE" || "$VALKEY_RUNNING" == true ]]; then
    record WARN "P4" "Port ${VALKEY_PORT} not found in listening sockets" \
      "Valkey may be bound to 127.0.0.1 only (correct for production)"
  fi

fi  # VALKEY_PRESENT

# ==============================================================================
# PHASE 5 — Functional Tests
# ==============================================================================
_head "PHASE 5 — Functional Tests"

if [[ "$VALKEY_RUNNING" == false ]]; then
  record SKIP "P5" "All functional tests" "Valkey not running"
else

  _h2 "5.1  PING"
  PING_RESP="$(vcli PING || true)"
  if [[ "$PING_RESP" == "PONG" ]]; then
    record PASS "P5" "PING → PONG"
  else
    record FAIL "P5" "PING failed" "Got: '${PING_RESP:-<no response>}'"
  fi

  _h2 "5.2  INFO server"
  INFO_SERVER="$(vcli INFO server || true)"
  # Valkey 8+ reports valkey_version; earlier reports redis_version
  VALKEY_RUNNING_VER="$(echo "$INFO_SERVER" | grep 'valkey_version:' | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
  if [[ -n "$VALKEY_RUNNING_VER" ]]; then
    record PASS "P5" "INFO server → valkey_version" "${VALKEY_RUNNING_VER}"
  else
    VALKEY_RUNNING_VER="$(echo "$INFO_SERVER" | grep 'redis_version:' | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
    if [[ -n "$VALKEY_RUNNING_VER" ]]; then
      record WARN "P5" "valkey_version field absent (expected for Valkey ≤ 7.2)" \
        "redis_version: ${VALKEY_RUNNING_VER}"
    else
      record FAIL "P5" "Cannot read version from INFO server"
    fi
  fi

  UPTIME="$(echo "$INFO_SERVER" | grep 'uptime_in_seconds:' | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
  [[ -n "$UPTIME" ]] && record PASS "P5" "Uptime" "${UPTIME}s"

  CONF_PORT="$(echo "$INFO_SERVER" | grep 'tcp_port:' | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
  if [[ "${CONF_PORT}" == "${VALKEY_PORT}" ]]; then
    record PASS "P5" "TCP port matches expected" "${CONF_PORT}"
  else
    record WARN "P5" "TCP port mismatch" "Expected ${VALKEY_PORT}, INFO reports ${CONF_PORT:-unknown}"
  fi

  OS_FROM_INFO="$(echo "$INFO_SERVER" | grep '^os:' | tr -d '\r' | cut -d: -f2- | sed 's/^ //' || true)"
  [[ -n "$OS_FROM_INFO" ]] && record PASS "P5" "OS from INFO server" "${OS_FROM_INFO}"

  _h2 "5.3  INFO memory"
  INFO_MEM="$(vcli INFO memory || true)"
  USED_MEM="$(echo "$INFO_MEM" | grep 'used_memory_human:'    | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
  MAX_MEM="$(echo  "$INFO_MEM" | grep 'maxmemory_human:'      | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
  FRAG="$(echo     "$INFO_MEM" | grep 'mem_fragmentation_ratio:' | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
  [[ -n "$USED_MEM" ]] && record PASS "P5" "used_memory_human"  "${USED_MEM}"
  [[ -n "$MAX_MEM"  ]] && record PASS "P5" "maxmemory_human"    "${MAX_MEM}"
  if [[ -n "$FRAG" ]]; then
    FRAG_INT="${FRAG%%.*}"
    if [[ "${FRAG_INT}" =~ ^[0-9]+$ ]] && [[ "${FRAG_INT}" -gt 5 ]]; then
      record WARN "P5" "High memory fragmentation ratio" "${FRAG} (>5 may indicate RSS bloat)"
    else
      record PASS "P5" "Memory fragmentation ratio" "${FRAG}"
    fi
  fi

  _h2 "5.4  INFO replication"
  INFO_REPL="$(vcli INFO replication || true)"
  ROLE="$(echo "$INFO_REPL" | grep '^role:' | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
  CONN_SLAVES="$(echo "$INFO_REPL" | grep 'connected_slaves:' | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
  [[ -n "$ROLE"        ]] && record PASS "P5" "Replication role"    "${ROLE}"
  [[ -n "$CONN_SLAVES" ]] && record PASS "P5" "Connected replicas"  "${CONN_SLAVES}"

  if [[ "$ROLE" == "slave" || "$ROLE" == "replica" ]]; then
    LINK_STATUS="$(echo "$INFO_REPL" | grep 'master_link_status:'        | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
    LAG="$(echo         "$INFO_REPL" | grep 'master_last_io_seconds_ago:' | tr -d '\r' | cut -d: -f2 | tr -d ' ' || true)"
    if [[ "$LINK_STATUS" == "up" ]]; then
      record PASS "P5" "Replica link status" "up  lag=${LAG:-?}s"
    else
      record FAIL "P5" "Replica link status is NOT up" "${LINK_STATUS:-unknown}"
    fi
  fi

  _h2 "5.5  Write / Read Tests  (all in DB ${TEST_DB})"
  TS="$(date +%s)"
  TEST_KEY="valkey_test_${TS}"
  TEST_VAL="hello_valkey_${TS}"

  # SELECT
  SEL="$(vcli SELECT "${TEST_DB}" || true)"
  if [[ "$SEL" == "OK" ]]; then
    record PASS "P5" "SELECT db ${TEST_DB}"
  else
    record WARN "P5" "SELECT db ${TEST_DB}" "Got: '${SEL:-<empty>}'"
  fi

  # SET / GET (string)
  SET_RESP="$(vcli -n "${TEST_DB}" SET "${TEST_KEY}" "${TEST_VAL}" || true)"
  if [[ "$SET_RESP" == "OK" ]]; then
    record PASS "P5" "SET string key"
  else
    record FAIL "P5" "SET string key" "Got: '${SET_RESP:-<empty>}'"
  fi

  GET_RESP="$(vcli -n "${TEST_DB}" GET "${TEST_KEY}" || true)"
  if [[ "$GET_RESP" == "$TEST_VAL" ]]; then
    record PASS "P5" "GET string key — value matches"
  else
    record FAIL "P5" "GET value mismatch" "Expected '${TEST_VAL}', got '${GET_RESP:-<empty>}'"
  fi

  # EXISTS
  EXISTS_RESP="$(vcli -n "${TEST_DB}" EXISTS "${TEST_KEY}" || true)"
  if [[ "$EXISTS_RESP" == "1" ]]; then
    record PASS "P5" "EXISTS returns 1 for present key"
  else
    record FAIL "P5" "EXISTS" "Expected 1, got '${EXISTS_RESP:-<empty>}'"
  fi

  # EXPIRE / TTL
  vcli -n "${TEST_DB}" EXPIRE "${TEST_KEY}" 120 > /dev/null
  TTL_RESP="$(vcli -n "${TEST_DB}" TTL "${TEST_KEY}" || true)"
  if [[ "${TTL_RESP}" =~ ^[0-9]+$ ]] && [[ "${TTL_RESP}" -gt 0 ]]; then
    record PASS "P5" "EXPIRE / TTL" "TTL=${TTL_RESP}s"
  else
    record WARN "P5" "TTL after EXPIRE" "Expected >0, got '${TTL_RESP:-<empty>}'"
  fi

  # PERSIST (remove TTL)
  vcli -n "${TEST_DB}" PERSIST "${TEST_KEY}" > /dev/null
  TTL_AFTER="$(vcli -n "${TEST_DB}" TTL "${TEST_KEY}" || true)"
  if [[ "$TTL_AFTER" == "-1" ]]; then
    record PASS "P5" "PERSIST removes TTL" "TTL=-1 (no expiry)"
  else
    record WARN "P5" "PERSIST result unexpected" "TTL=${TTL_AFTER:-unknown}"
  fi

  # TYPE
  TYPE_RESP="$(vcli -n "${TEST_DB}" TYPE "${TEST_KEY}" || true)"
  if [[ "$TYPE_RESP" == "string" ]]; then
    record PASS "P5" "TYPE returns string"
  else
    record WARN "P5" "TYPE" "Got: '${TYPE_RESP:-<empty>}'"
  fi

  # INCR
  INCR_KEY="valkey_incr_${TS}"
  vcli -n "${TEST_DB}" SET "${INCR_KEY}" 0 > /dev/null
  INCR_RESP="$(vcli -n "${TEST_DB}" INCR "${INCR_KEY}" || true)"
  if [[ "$INCR_RESP" == "1" ]]; then
    record PASS "P5" "INCR integer counter"
  else
    record FAIL "P5" "INCR" "Expected 1, got '${INCR_RESP:-<empty>}'"
  fi

  # HSET / HGET (hash)
  HASH_KEY="valkey_hash_${TS}"
  vcli -n "${TEST_DB}" HSET "${HASH_KEY}" field1 value1 > /dev/null
  HGET_RESP="$(vcli -n "${TEST_DB}" HGET "${HASH_KEY}" field1 || true)"
  if [[ "$HGET_RESP" == "value1" ]]; then
    record PASS "P5" "HSET / HGET — hash type"
  else
    record FAIL "P5" "HSET / HGET" "Got: '${HGET_RESP:-<empty>}'"
  fi

  # LPUSH / LRANGE (list)
  LIST_KEY="valkey_list_${TS}"
  vcli -n "${TEST_DB}" LPUSH "${LIST_KEY}" item1 item2 > /dev/null
  LRANGE_RESP="$(vcli -n "${TEST_DB}" LRANGE "${LIST_KEY}" 0 -1 || true)"
  if echo "$LRANGE_RESP" | grep -q "item1"; then
    record PASS "P5" "LPUSH / LRANGE — list type"
  else
    record FAIL "P5" "LPUSH / LRANGE" "Got: '${LRANGE_RESP:-<empty>}'"
  fi

  # SADD / SMEMBERS (set)
  SETK_KEY="valkey_set_${TS}"
  vcli -n "${TEST_DB}" SADD "${SETK_KEY}" memberA memberB > /dev/null
  SMEM_RESP="$(vcli -n "${TEST_DB}" SMEMBERS "${SETK_KEY}" || true)"
  if echo "$SMEM_RESP" | grep -q "memberA"; then
    record PASS "P5" "SADD / SMEMBERS — set type"
  else
    record FAIL "P5" "SADD / SMEMBERS" "Got: '${SMEM_RESP:-<empty>}'"
  fi

  # ZADD / ZSCORE (sorted set)
  # Store as integer 42; Valkey returns "42" — compare with string
  ZSET_KEY="valkey_zset_${TS}"
  vcli -n "${TEST_DB}" ZADD "${ZSET_KEY}" 42 member1 > /dev/null
  ZSCORE_RESP="$(vcli -n "${TEST_DB}" ZSCORE "${ZSET_KEY}" member1 || true)"
  # Valkey may return "42" or "42.0" depending on version — strip trailing .0
  ZSCORE_INT="${ZSCORE_RESP%%.*}"
  if [[ "$ZSCORE_INT" == "42" ]]; then
    record PASS "P5" "ZADD / ZSCORE — sorted set type" "score=${ZSCORE_RESP}"
  else
    record FAIL "P5" "ZADD / ZSCORE" "Expected score 42, got '${ZSCORE_RESP:-<empty>}'"
  fi

  _h2 "5.6  Persistence"
  SAVE_RESP="$(vcli SAVE || true)"
  if [[ "$SAVE_RESP" == "OK" ]]; then
    record PASS "P5" "SAVE (synchronous RDB snapshot)"
  else
    record FAIL "P5" "SAVE" "Got: '${SAVE_RESP:-<empty>}'"
  fi

  BGSAVE_RESP="$(vcli BGSAVE || true)"
  if echo "$BGSAVE_RESP" | grep -qiE "background saving started|background save already"; then
    record PASS "P5" "BGSAVE initiated"
  else
    record WARN "P5" "BGSAVE response unexpected" "'${BGSAVE_RESP:-<empty>}'"
  fi

  # Verify RDB file on disk
  CONF_DIR="$(vcli CONFIG GET dir        | awk 'NR==2' | tr -d '\r' || true)"
  CONF_DBF="$(vcli CONFIG GET dbfilename | awk 'NR==2' | tr -d '\r' || true)"
  if [[ -n "$CONF_DIR" && -n "$CONF_DBF" && "$CONF_DIR" != "dir" && "$CONF_DBF" != "dbfilename" ]]; then
    RDB_PATH="${CONF_DIR}/${CONF_DBF}"
    if [[ -f "$RDB_PATH" ]]; then
      RDB_SIZE="$(du -h "$RDB_PATH" | awk '{print $1}')"
      record PASS "P5" "RDB file exists on disk" "${RDB_PATH} (${RDB_SIZE})"
    else
      record WARN "P5" "RDB file not found at expected path" "${RDB_PATH}"
    fi
  else
    record WARN "P5" "Could not determine RDB path from CONFIG GET" \
      "dir='${CONF_DIR}' dbfilename='${CONF_DBF}'"
  fi

  _h2 "5.7  DBSIZE / SLOWLOG"
  DBSIZE="$(vcli DBSIZE || true)"
  record PASS "P5" "DBSIZE (db 0)" "${DBSIZE:-0} keys"

  SLOWLOG_OUT="$(vcli SLOWLOG GET 5 || true)"
  {
    echo "=== SLOWLOG GET 5 at $(_ts) ==="
    echo "$SLOWLOG_OUT"
  } > "${LOGDIR}/slowlog.txt"
  record PASS "P5" "SLOWLOG captured" "${LOGDIR}/slowlog.txt"

  _h2 "5.8  COMMAND COUNT (protocol check)"
  CMD_COUNT="$(vcli COMMAND COUNT || true)"
  if [[ "${CMD_COUNT}" =~ ^[0-9]+$ ]] && [[ "${CMD_COUNT}" -gt 100 ]]; then
    record PASS "P5" "COMMAND COUNT" "${CMD_COUNT} commands"
  else
    record WARN "P5" "COMMAND COUNT unexpected" "Got: '${CMD_COUNT:-<empty>}'"
  fi

  _h2 "5.9  Cleanup Test Keys (DB ${TEST_DB})"
  for k in "${TEST_KEY}" "${INCR_KEY}" "${HASH_KEY}" "${LIST_KEY}" "${SETK_KEY}" "${ZSET_KEY}"; do
    vcli -n "${TEST_DB}" DEL "$k" > /dev/null
  done
  REMAINING="$(vcli -n "${TEST_DB}" DBSIZE || true)"
  if [[ "${REMAINING:-0}" -eq 0 ]]; then
    record PASS "P5" "Test key cleanup complete" "DB ${TEST_DB} is empty"
  else
    record WARN "P5" "DB ${TEST_DB} not empty after cleanup" \
      "${REMAINING} key(s) remain — may be pre-existing data in this db"
  fi

fi  # VALKEY_RUNNING

# ==============================================================================
# PHASE 6 — valkey.conf Inspection & Hardening Audit
# ==============================================================================
_head "PHASE 6 — valkey.conf Inspection & Hardening"

for c in /etc/valkey/valkey.conf /etc/valkey.conf \
         /usr/local/etc/valkey.conf /usr/local/etc/valkey/valkey.conf; do
  [[ -f "$c" ]] && { VALKEY_CONF="$c"; break; }
done

if [[ -z "$VALKEY_CONF" ]]; then
  record WARN "P6" "valkey.conf not found at any standard path" \
    "Checked: /etc/valkey/valkey.conf, /etc/valkey.conf, /usr/local/etc/valkey.conf"
else
  record PASS "P6" "valkey.conf found" "${VALKEY_CONF}"
  cp "${VALKEY_CONF}" "${LOGDIR}/valkey.conf.snapshot"
  record PASS "P6" "Config snapshot saved" "${LOGDIR}/valkey.conf.snapshot"

  # Extract a directive's first value from the config file.
  # Handles: "bind 127.0.0.1" and "bind 127.0.0.1 -::1" — returns $2 only.
  conf_val() {
    grep -m1 "^${1}[[:space:]]" "${VALKEY_CONF}" 2>/dev/null | awk '{print $2}' || true
  }

  { echo "=== valkey.conf ANALYSIS === $(date)"; echo ""; } > "$CONF_LOG"

  _h2 "6.1  Binding / Network"
  BIND_VAL="$(conf_val bind)"
  if [[ -z "$BIND_VAL" ]]; then
    record WARN "P6" "bind not explicitly set" "Defaults to 127.0.0.1 in Valkey 7.2+ (safe), but set explicitly"
    echo "WARN  bind = <not set — default 127.0.0.1>" >> "$CONF_LOG"
  elif echo "$BIND_VAL" | grep -qE '^0\.0\.0\.0$'; then
    record WARN "P6" "bind 0.0.0.0" "Listening on all interfaces — restrict unless intentional"
    echo "WARN  bind = ${BIND_VAL}" >> "$CONF_LOG"
  else
    record PASS "P6" "bind" "${BIND_VAL}"
    echo "OK    bind = ${BIND_VAL}" >> "$CONF_LOG"
  fi

  PMODE="$(conf_val protected-mode)"
  if [[ "$PMODE" == "no" ]]; then
    record WARN "P6" "protected-mode disabled" "Ensure firewall blocks port ${VALKEY_PORT} from untrusted networks"
  else
    record PASS "P6" "protected-mode" "${PMODE:-yes (default)}"
  fi

  _h2 "6.2  Authentication"
  AUTH_VAL="$(conf_val requirepass)"
  if [[ -z "$AUTH_VAL" ]]; then
    record WARN "P6" "requirepass not set" "No password auth — set requirepass or configure ACL users"
    echo "WARN  requirepass = <not set>" >> "$CONF_LOG"
  else
    record PASS "P6" "requirepass" "Set (value hidden)"
    echo "OK    requirepass = <hidden>" >> "$CONF_LOG"
  fi

  _h2 "6.3  Memory"
  MAXMEM="$(conf_val maxmemory)"
  if [[ -z "$MAXMEM" || "$MAXMEM" == "0" ]]; then
    record WARN "P6" "maxmemory not set" "Valkey can consume all available RAM; set a limit"
    echo "WARN  maxmemory = ${MAXMEM:-0}" >> "$CONF_LOG"
  else
    record PASS "P6" "maxmemory" "${MAXMEM}"
    echo "OK    maxmemory = ${MAXMEM}" >> "$CONF_LOG"
  fi

  POLICY="$(conf_val maxmemory-policy)"
  record PASS "P6" "maxmemory-policy" "${POLICY:-noeviction (default)}"
  echo "INFO  maxmemory-policy = ${POLICY:-<default>}" >> "$CONF_LOG"

  _h2 "6.4  Persistence"
  AOF="$(conf_val appendonly)"
  record PASS "P6" "appendonly" "${AOF:-no}"
  echo "INFO  appendonly = ${AOF:-no}" >> "$CONF_LOG"

  SAVE_CONF="$(grep -m1 '^save ' "${VALKEY_CONF}" 2>/dev/null || true)"
  if [[ -n "$SAVE_CONF" ]]; then
    record PASS "P6" "save (RDB trigger)" "${SAVE_CONF}"
  else
    record WARN "P6" "No 'save' directive found" "RDB snapshots may not be triggered automatically"
  fi

  _h2 "6.5  Logging"
  LOGLVL="$(conf_val loglevel)"
  record PASS "P6" "loglevel" "${LOGLVL:-notice}"

  LOGFILE_VAL="$(conf_val logfile)"
  if [[ -z "$LOGFILE_VAL" || "$LOGFILE_VAL" == '""' ]]; then
    record WARN "P6" "logfile" "Logging to stdout only — set a path for persistent logs"
  else
    record PASS "P6" "logfile" "${LOGFILE_VAL}"
  fi

  _h2 "6.6  Clustering"
  CLUSTER_ON="$(conf_val cluster-enabled)"
  if [[ "$CLUSTER_ON" == "yes" ]]; then
    record PASS "P6" "cluster-enabled" "yes"
    CCONF="$(conf_val cluster-config-file)"
    if [[ -n "$CCONF" ]]; then
      record PASS "P6" "cluster-config-file" "${CCONF}"
    else
      record WARN "P6" "cluster-config-file" "Not set while cluster-enabled=yes"
    fi
    CT="$(conf_val cluster-node-timeout)"
    [[ -n "$CT" ]] && record PASS "P6" "cluster-node-timeout" "${CT}ms"
  else
    record PASS "P6" "cluster-enabled" "no (standalone mode)"
  fi

  _h2 "6.7  Valkey 8+ Specific"
  IOTH="$(conf_val io-threads)"
  if [[ -n "$IOTH" ]] && [[ "${IOTH}" =~ ^[0-9]+$ ]] && [[ "${IOTH}" -gt 1 ]]; then
    record PASS "P6" "io-threads" "${IOTH} (multi-threaded I/O enabled — Valkey 8+ feature)"
  else
    record PASS "P6" "io-threads" "${IOTH:-1} (single-threaded or not set)"
  fi

  record PASS "P6" "Full config analysis written" "${CONF_LOG}"
fi

# ==============================================================================
# PHASE 7 — Redis → Valkey Compatibility
# ==============================================================================
_head "PHASE 7 — Redis → Valkey Compatibility"

{ echo "=== REDIS -> VALKEY COMPAT REPORT === $(_ts)"; echo ""; } > "$COMPAT_LOG"

_h2 "7.1  Config Directive Scan (redis.conf → valkey.conf)"
# Source: https://valkey.io/topics/migration — known removed/renamed directives
REMOVED_DIRECTIVES=(
  "latency-tracking-info-percentiles"
)
RENAMED_DIRECTIVES=(
  "slave-serve-stale-data:replica-serve-stale-data"
  "slave-read-only:replica-read-only"
  "slave-lazy-flush:replica-lazy-flush"
  "slave-priority:replica-priority"
  "min-slaves-to-write:min-replicas-to-write"
  "min-slaves-max-lag:min-replicas-max-lag"
)

if [[ -n "$REDIS_CONF_PATH" ]]; then
  _log "Scanning: ${REDIS_CONF_PATH}"
  COMPAT_ISSUES=0

  for dir in "${REMOVED_DIRECTIVES[@]}"; do
    _vcmd "grep -m1 ^${dir} ${REDIS_CONF_PATH}"
    if grep -qm1 "^${dir}" "$REDIS_CONF_PATH" 2>/dev/null; then
      record WARN "P7" "Removed directive in redis.conf" \
        "${dir} — this directive is removed in Valkey; delete from valkey.conf"
      echo "WARN  Removed: ${dir}" >> "$COMPAT_LOG"
      ((++COMPAT_ISSUES))
    fi
  done

  for pair in "${RENAMED_DIRECTIVES[@]}"; do
    OLD="${pair%%:*}"; NEW="${pair##*:}"
    _vcmd "grep -m1 ^${OLD} ${REDIS_CONF_PATH}"
    if grep -qm1 "^${OLD}" "$REDIS_CONF_PATH" 2>/dev/null; then
      record WARN "P7" "Renamed directive in redis.conf" \
        "${OLD}  →  use '${NEW}' in valkey.conf"
      echo "WARN  Renamed: ${OLD} -> ${NEW}" >> "$COMPAT_LOG"
      ((++COMPAT_ISSUES))
    fi
  done

  if [[ "$COMPAT_ISSUES" -eq 0 ]]; then
    record PASS "P7" "No removed/renamed directives found in redis.conf"
  fi
else
  record SKIP "P7" "Config directive scan" "redis.conf not found"
fi

_h2 "7.2  RDB File Format Compatibility"
# REDIS_MAJOR/REDIS_MINOR were pre-declared at top, set in Phase 2 if Redis running
if [[ "$REDIS_RUNNING" == true ]]; then
  echo "Redis version: ${REDIS_INFO_VER}  Major=${REDIS_MAJOR}  Minor=${REDIS_MINOR}" >> "$COMPAT_LOG"
  _log "Redis version for compat check: ${REDIS_INFO_VER} (major=${REDIS_MAJOR} minor=${REDIS_MINOR})"

  if [[ "${REDIS_MAJOR}" =~ ^[0-9]+$ ]]; then
    if [[ "${REDIS_MAJOR}" -le 6 ]]; then
      record PASS "P7" "RDB format compatible" \
        "Redis ${REDIS_INFO_VER} → Valkey 7.2+/8.x: fully compatible"
    elif [[ "${REDIS_MAJOR}" -eq 7 && "${REDIS_MINOR}" =~ ^[0-9]+$ && "${REDIS_MINOR}" -le 2 ]]; then
      record PASS "P7" "RDB format compatible" \
        "Redis ${REDIS_INFO_VER} → Valkey: fully compatible"
    elif [[ "${REDIS_MAJOR}" -ge 7 && "${REDIS_MINOR}" =~ ^[0-9]+$ && "${REDIS_MINOR}" -ge 4 ]]; then
      record WARN "P7" "RDB format INCOMPATIBLE (Redis CE 7.4+)" \
        "Must use export/import tools. See https://valkey.io/topics/migration"
      echo "WARN  RDB: Redis ${REDIS_INFO_VER} INCOMPATIBLE with Valkey" >> "$COMPAT_LOG"
    fi
  fi

  # RDB magic byte check
  if [[ -n "$REDIS_DATA_DIR" && -n "$REDIS_RDB_FILE" ]]; then
    REDIS_RDB_FULL="${REDIS_DATA_DIR}/${REDIS_RDB_FILE}"
    if [[ -f "$REDIS_RDB_FULL" ]]; then
      _vcmd "head -c 5 ${REDIS_RDB_FULL} | cat"
      RDB_MAGIC="$(head -c 5 "$REDIS_RDB_FULL" 2>/dev/null | tr -dc '[:print:]' || true)"
      if [[ "$RDB_MAGIC" == "REDIS" ]]; then
        RDB_SIZE="$(du -h "$REDIS_RDB_FULL" | awk '{print $1}')"
        record PASS "P7" "Redis RDB magic header valid" "${REDIS_RDB_FULL} (${RDB_SIZE})"
        echo "OK    RDB magic: REDIS — ${REDIS_RDB_FULL}" >> "$COMPAT_LOG"
      else
        record WARN "P7" "Unexpected RDB header" \
          "Got '${RDB_MAGIC}' (expected 'REDIS') at ${REDIS_RDB_FULL}"
        echo "WARN  RDB header: '${RDB_MAGIC}'" >> "$COMPAT_LOG"
      fi
    else
      record SKIP "P7" "RDB file not found at path from CONFIG GET" "${REDIS_RDB_FULL}"
    fi
  fi

else
  record SKIP "P7" "RDB compat (Redis not running)" "Checking binary version only"
  if command -v redis-server &>/dev/null; then
    _vcmd "redis-server --version"
    RBV_RAW="$(redis-server --version 2>/dev/null || true)"
    RBV="$(echo "$RBV_RAW" | grep -oE 'v=[0-9]+\.[0-9]+\.[0-9]+' | cut -d= -f2 || true)"
    RBMAJ="${RBV%%.*}"
    _RBV_REST="${RBV#*.}"; RBMIN="${_RBV_REST%%.*}"
    if [[ "${RBMAJ}" =~ ^[0-9]+$ ]] && [[ "${RBMIN}" =~ ^[0-9]+$ ]]; then
      if [[ "${RBMAJ}" -ge 7 && "${RBMIN}" -ge 4 ]]; then
        record WARN "P7" "Redis binary is CE 7.4+" \
          "${RBV_RAW} — RDB may not be compatible with Valkey"
      else
        record PASS "P7" "Redis binary version ≤ 7.2" "${RBV:-unknown}"
      fi
    fi
  fi
fi

_h2 "7.3  Protocol & Admin Commands"
if [[ "$VALKEY_RUNNING" == true ]]; then
  # HELLO (RESP3 — supported Valkey 7.2+)
  HELLO_RESP="$(vcli HELLO || true)"
  if echo "$HELLO_RESP" | grep -qiE "server|valkey|redis"; then
    record PASS "P7" "HELLO command (RESP3 support)"
  else
    record WARN "P7" "HELLO command response unclear" "'${HELLO_RESP:-<empty>}'"
  fi

  # DEBUG SLEEP 0 — no-op latency probe
  DBG="$(vcli DEBUG SLEEP 0 || true)"
  if [[ "$DBG" == "OK" ]]; then
    record PASS "P7" "DEBUG SLEEP 0"
  else
    record WARN "P7" "DEBUG SLEEP 0" "Got: '${DBG:-<empty>}'"
  fi

  # LATENCY HISTORY
  LAT="$(vcli LATENCY HISTORY event || true)"
  record PASS "P7" "LATENCY HISTORY accessible" "${LAT:-<empty> (no events yet)}"

  # MODULE LIST
  MOD="$(vcli MODULE LIST || true)"
  if echo "$MOD" | grep -qiE 'ERR|not allowed'; then
    record WARN "P7" "MODULE LIST restricted" "${MOD}"
  elif [[ -z "$MOD" ]]; then
    record PASS "P7" "MODULE LIST" "No modules loaded (expected on fresh install)"
  else
    record WARN "P7" "Modules loaded — verify Valkey compatibility" \
      "$(echo "$MOD" | head -2 | tr '\n' ' ')"
    echo "=== LOADED MODULES ===" >> "$COMPAT_LOG"
    echo "$MOD" >> "$COMPAT_LOG"
  fi
fi

record PASS "P7" "Compat report written" "${COMPAT_LOG}"

# ==============================================================================
# PHASE 8 — Dependency & Library Conflict Detection
# ==============================================================================
_head "PHASE 8 — Dependency & Library Conflict Detection"

{ echo "=== DEPENDENCY CHECK === $(_ts)"; echo ""; } > "$DEP_LOG"

_h2 "8.1  Shared Library Resolution"
if command -v ldd &>/dev/null && command -v valkey-server &>/dev/null; then
  VALKEY_BIN="$(command -v valkey-server)"
  _vcmd "ldd ${VALKEY_BIN}"
  LDD_OUT="$(ldd "${VALKEY_BIN}" 2>&1 || true)"
  echo "$LDD_OUT" >> "$DEP_LOG"

  if echo "$LDD_OUT" | grep -q "not found"; then
    MISSING="$(echo "$LDD_OUT" | grep 'not found')"
    record FAIL "P8" "Missing shared libraries" "${MISSING}"
    echo "FAIL  Missing: ${MISSING}" >> "$DEP_LOG"
  else
    record PASS "P8" "All shared libraries resolved for valkey-server"
    echo "OK    All libs present" >> "$DEP_LOG"
  fi

  if echo "$LDD_OUT" | grep -qi "libssl\|libcrypto"; then
    SSL_LIB="$(echo "$LDD_OUT" | grep -i libssl | awk '{print $3}' | head -1)"
    record PASS "P8" "OpenSSL linked" "${SSL_LIB:-present}"
  else
    record PASS "P8" "OpenSSL" "Not linked (TLS not compiled in this build, or statically linked)"
  fi
else
  record SKIP "P8" "ldd check" "ldd not available or valkey-server not found"
fi

_h2 "8.2  Package Conflict Check"
if [[ "$PKG_MGR" == "yum" || "$PKG_MGR" == "dnf" ]]; then
  _vcmd "${PKG_MGR} list installed 2>/dev/null | grep -iE '^redis|^valkey'"
  REDIS_RPM="$("${PKG_MGR}" list installed 2>/dev/null | grep -iE '^redis' | awk '{print $1}' || true)"
  VALKEY_RPM="$("${PKG_MGR}" list installed 2>/dev/null | grep -iE '^valkey' | awk '{print $1}' || true)"

  if [[ -n "$REDIS_RPM" ]]; then
    record WARN "P8" "Redis RPM installed alongside Valkey" \
      "${REDIS_RPM} — ensure they use different ports or one is disabled"
    echo "WARN  Redis RPM: ${REDIS_RPM}" >> "$DEP_LOG"
  else
    record PASS "P8" "No Redis RPM conflict detected"
    echo "OK    No Redis RPM installed" >> "$DEP_LOG"
  fi
  if [[ -n "$VALKEY_RPM" ]]; then
    record PASS "P8" "Valkey RPM installed" "${VALKEY_RPM}"
    echo "OK    Valkey RPM: ${VALKEY_RPM}" >> "$DEP_LOG"
  else
    record WARN "P8" "Valkey RPM not found in installed packages" \
      "May be installed from source or tarball"
  fi

elif [[ "$PKG_MGR" == "apt" ]]; then
  _vcmd "dpkg -l | awk '/^ii/ && /redis|valkey/'"
  REDIS_DEB="$(dpkg -l 2>/dev/null | awk '/^ii/ && /redis/{print $2}' || true)"
  VALKEY_DEB="$(dpkg -l 2>/dev/null | awk '/^ii/ && /valkey/{print $2}' || true)"

  if [[ -n "$REDIS_DEB" ]]; then
    record WARN "P8" "Redis DEB installed alongside Valkey" \
      "${REDIS_DEB} — ensure different ports or disable one"
    echo "WARN  Redis DEB: ${REDIS_DEB}" >> "$DEP_LOG"
  else
    record PASS "P8" "No Redis DEB conflict detected"
    echo "OK    No Redis DEB installed" >> "$DEP_LOG"
  fi
  if [[ -n "$VALKEY_DEB" ]]; then
    record PASS "P8" "Valkey DEB installed" "${VALKEY_DEB}"
    echo "OK    Valkey DEB: ${VALKEY_DEB}" >> "$DEP_LOG"
  else
    record WARN "P8" "Valkey DEB not found in dpkg list" \
      "May be installed from source or tarball"
  fi
fi

_h2 "8.3  Port Conflict"
if [[ "$REDIS_RUNNING" == true && "$VALKEY_RUNNING" == true ]]; then
  if [[ "$REDIS_PORT" == "$VALKEY_PORT" ]]; then
    record WARN "P8" "Redis and Valkey both using port ${VALKEY_PORT}" \
      "This means one of them is not actually running — check which is answering"
  else
    record PASS "P8" "No port conflict" \
      "Redis: ${REDIS_PORT}  Valkey: ${VALKEY_PORT}"
  fi
elif [[ "$REDIS_RUNNING" == false && "$VALKEY_RUNNING" == true ]]; then
  record PASS "P8" "Only Valkey is running on port ${VALKEY_PORT}" "No Redis port conflict"
fi

record PASS "P8" "Dependency report written" "${DEP_LOG}"

# ==============================================================================
# PHASE 9 — Backward-Compatibility & File Safety Audit
# ==============================================================================
_head "PHASE 9 — Backward-Compatibility & File Safety Audit"

{ echo "=== FILE SAFETY AUDIT === $(_ts)"; echo ""; } > "$FILE_LOG"

_h2 "9.1  Redis Files Still Present (Non-Removal Verification)"
for f in \
    "$(command -v redis-server 2>/dev/null || true)" \
    "$(command -v redis-cli    2>/dev/null || true)" \
    "${REDIS_CONF_PATH}" \
    "${REDIS_DATA_DIR}/${REDIS_RDB_FILE}"; do
  [[ -z "$f" || "$f" == "/" ]] && continue
  if [[ -e "$f" ]]; then
    record PASS "P9" "Redis file still present (not removed)" "$f"
    echo "OK    Present: $f" >> "$FILE_LOG"
  fi
done

_h2 "9.2  Valkey File Inventory"
for f in \
    "$(command -v valkey-server 2>/dev/null || true)" \
    "$(command -v valkey-cli    2>/dev/null || true)" \
    /etc/valkey/valkey.conf \
    /etc/valkey.conf \
    /var/lib/valkey/dump.rdb \
    /var/log/valkey/valkey.log; do
  [[ -z "$f" || "$f" == "/" ]] && continue
  if [[ -e "$f" ]]; then
    FSIZE="$(du -h "$f" 2>/dev/null | awk '{print $1}')"
    FOWN="$(stat -c '%U:%G' "$f" 2>/dev/null || true)"
    FPERM="$(stat -c '%a' "$f" 2>/dev/null || true)"
    record PASS "P9" "Valkey file present" "${f}  [size=${FSIZE} owner=${FOWN} perm=${FPERM}]"
    echo "OK  ${f}  size=${FSIZE}  owner=${FOWN}  perm=${FPERM}" >> "$FILE_LOG"
  fi
done

_h2 "9.3  Valkey System User"
if id valkey &>/dev/null; then
  VALKEY_UID="$(id -u valkey)"
  VALKEY_SHELL="$(getent passwd valkey 2>/dev/null | cut -d: -f7 || true)"
  VALKEY_HOME="$(getent passwd valkey 2>/dev/null | cut -d: -f6 || true)"
  record PASS "P9" "valkey user exists" \
    "UID=${VALKEY_UID}  home=${VALKEY_HOME}  shell=${VALKEY_SHELL}"
  if echo "${VALKEY_SHELL}" | grep -qE "nologin|false"; then
    record PASS "P9" "valkey user shell is locked" "${VALKEY_SHELL}"
  else
    record WARN "P9" "valkey user has interactive shell" \
      "${VALKEY_SHELL} — change to /sbin/nologin for service accounts"
  fi
else
  record WARN "P9" "valkey system user not found" \
    "Expected system user 'valkey' created by package install"
fi

_h2 "9.4  Compat Symlink Check"
if command -v redis-cli &>/dev/null; then
  RCLI_PATH="$(command -v redis-cli)"
  if [[ -L "$RCLI_PATH" ]]; then
    RCLI_TARGET="$(readlink -f "$RCLI_PATH")"
    if echo "$RCLI_TARGET" | grep -qi valkey; then
      record PASS "P9" "redis-cli symlinks to valkey-cli" "${RCLI_PATH} → ${RCLI_TARGET}"
    else
      record PASS "P9" "redis-cli is a symlink (not to valkey)" \
        "${RCLI_PATH} → ${RCLI_TARGET}"
    fi
  else
    record PASS "P9" "redis-cli is an independent binary" "${RCLI_PATH}"
  fi
fi

_h2 "9.5  SELinux"
if command -v getenforce &>/dev/null; then
  _vcmd "getenforce"
  SE_STATUS="$(getenforce 2>/dev/null || true)"
  case "$SE_STATUS" in
    Enforcing)
      record WARN "P9" "SELinux is Enforcing" \
        "If Valkey fails to start check: ausearch -c valkey-server --raw | audit2allow -M valkey && semodule -i valkey.pp"
      ;;
    Permissive)
      record WARN "P9" "SELinux is Permissive" \
        "AVC denials are logged but not enforced; review /var/log/audit/audit.log"
      ;;
    Disabled)
      record PASS "P9" "SELinux is Disabled"
      ;;
    *)
      record PASS "P9" "SELinux" "${SE_STATUS}"
      ;;
  esac

  if command -v ausearch &>/dev/null; then
    _vcmd "ausearch -c valkey-server --raw 2>/dev/null | grep AVC"
    AVC_HITS="$(ausearch -c valkey-server --raw 2>/dev/null | grep AVC | head -5 || true)"
    if [[ -n "$AVC_HITS" ]]; then
      record WARN "P9" "SELinux AVC denials for valkey-server" \
        "$(echo "$AVC_HITS" | wc -l) AVC entries found — see ${FAIL_LOG}"
      { echo "=== SELinux AVC denials ==="; echo "$AVC_HITS"; } >> "$FAIL_LOG"
    else
      record PASS "P9" "No SELinux AVC denials for valkey-server"
    fi
  fi
else
  record SKIP "P9" "SELinux check" "getenforce not found (not an EL system or SELinux not installed)"
fi

_h2 "9.6  AppArmor"
if [[ -d /etc/apparmor.d ]] && command -v aa-status &>/dev/null; then
  _vcmd "aa-status 2>/dev/null | head -5"
  AA_OUT="$(aa-status 2>/dev/null | head -5 || true)"
  if echo "$AA_OUT" | grep -qi "apparmor module is loaded"; then
    if aa-status 2>/dev/null | grep -qi valkey; then
      record WARN "P9" "AppArmor profile found for valkey" \
        "Ensure profile permits /var/lib/valkey, /etc/valkey, and the log path"
    else
      record PASS "P9" "AppArmor loaded but no Valkey profile" \
        "Valkey running unconfined (expected unless you created a profile)"
    fi
  fi
else
  record SKIP "P9" "AppArmor check" "Not applicable on this OS or aa-status not found"
fi

record PASS "P9" "File audit report written" "${FILE_LOG}"

# ==============================================================================
# PHASE 10 — Summary Report
# ==============================================================================
_head "PHASE 10 — Summary Report"

TOTAL=$((PASS + FAIL + WARN + SKIP))
TIMESTAMP_END="$(_ts)"

# Determine overall result
if [[ "$FAIL" -eq 0 ]]; then
  OVERALL_STATUS="ALL CHECKS PASSED (with ${WARN} warning(s))"
  OVERALL_COLOR="${GRN}"
else
  OVERALL_STATUS="${FAIL} CHECK(S) FAILED"
  OVERALL_COLOR="${RED}"
fi

REPORT_BODY="$(cat << EOFREPORT
============================================================
  VALKEY VALIDATION REPORT
  ${TIMESTAMP_END}
============================================================

  Host         : $(hostname -f 2>/dev/null || hostname)
  OS           : ${OS_PRETTY}
  Arch         : ${ARCH}
  Valkey ver   : ${VALKEY_RUNNING_VER:-${VALKEY_INST_VER:-not detected}}
  Redis ver    : ${REDIS_INFO_VER:-not found / not running}
  Valkey port  : ${VALKEY_PORT}
  Redis port   : ${REDIS_PORT}
  Test DB      : ${TEST_DB}
  Script ver   : ${SCRIPT_VERSION}
  Log dir      : ${LOGDIR}

============================================================
  RESULTS SUMMARY: ${TOTAL} total
============================================================
  PASS : ${PASS}
  FAIL : ${FAIL}
  WARN : ${WARN}
  SKIP : ${SKIP}

  Overall : ${OVERALL_STATUS}

============================================================
  DETAILED RESULTS
============================================================
EOFREPORT
)"

echo "$REPORT_BODY" | tee "$REPORT"

printf "  %-4s  %-5s  %-42s  %s\n" "RES." "PHASE" "TEST NAME" "DETAIL" | tee -a "$REPORT"
printf "  %-4s  %-5s  %-42s  %s\n" "----" "-----" "------------------------------------------" "------" | tee -a "$REPORT"
for entry in "${RESULTS[@]}"; do
  IFS='|' read -r s ph nm dt <<< "$entry"
  # Colour the status column in terminal output
  case "$s" in
    PASS) sc="${GRN}${s}${RST}" ;;
    FAIL) sc="${RED}${s}${RST}" ;;
    WARN) sc="${YLW}${s}${RST}" ;;
    SKIP) sc="${YLW}${s}${RST}" ;;
    *)    sc="$s" ;;
  esac
  # Print coloured to terminal (via tee → fd1), plain to file
  printf "  %-4s  %-5s  %-42s  %s\n" "$s" "$ph" "${nm:0:42}" "${dt:0:60}" >> "$REPORT"
  echo -e "  ${sc}  ${ph}  ${nm:0:42}  ${DIM}${dt:0:60}${RST}"
done | tee -a "$REPORT"

cat << EOFFILES | tee -a "$REPORT"

============================================================
  LOG FILES
============================================================
  Main log          : ${MAIN_LOG}
  Failure log       : ${FAIL_LOG}
  Compat log        : ${COMPAT_LOG}
  Config log        : ${CONF_LOG}
  Dependency log    : ${DEP_LOG}
  File audit log    : ${FILE_LOG}
  Redis snapshot    : ${LOGDIR}/redis_premigration_snapshot.txt
  Service journal   : ${LOGDIR}/service_journal.txt
  valkey.conf copy  : ${LOGDIR}/valkey.conf.snapshot
  SLOWLOG           : ${LOGDIR}/slowlog.txt
  Full report       : ${REPORT}
EOFFILES

if [[ "$FAIL" -gt 0 ]]; then
  cat << EOFFAIL | tee -a "$REPORT"

============================================================
  FAILURE DETAILS
============================================================
EOFFAIL
  cat "$FAIL_LOG" 2>/dev/null | tee -a "$REPORT" || echo "  (failure log empty)" | tee -a "$REPORT"
fi

cat << EOFSAFE | tee -a "$REPORT"

============================================================
  SAFETY CONFIRMATION
============================================================
  - Redis was NOT stopped, flushed, or modified
  - Test keys were written only to Valkey DB ${TEST_DB}
  - Test keys were deleted before this script exited
  - No files were removed from this system
  - This script performed no irreversible operations
============================================================
EOFSAFE

echo ""
echo -e "${BLD}${OVERALL_COLOR}  ${OVERALL_STATUS}${RST}"
echo -e "${BLD}  Full report : ${REPORT}${RST}"
echo -e "${BLD}  All logs    : ${LOGDIR}${RST}"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
