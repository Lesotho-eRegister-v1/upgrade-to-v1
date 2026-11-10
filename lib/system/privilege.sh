# shellcheck shell=bash
# =============================================================================
# lib/system/privilege.sh — root / sudo handling
# =============================================================================
detect_privilege() {
  # Determine whether we need elevation to write under INSTALL_BASE.
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    return 0
  fi
  if [ -w "$INSTALL_BASE" ] && [ -w "$(dirname "$INSTALL_BASE")" ]; then
    SUDO=""
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    info "Elevation required for ${INSTALL_BASE}; will use sudo."
    # Prime sudo so later steps don't stall mid-flow.
    if ! sudo -n true 2>/dev/null; then
      confirm "Authorize sudo now?" "quit — sudo is required to continue" \
        || { error "Aborted: sudo required."; exit 1; }
      sudo -v </dev/tty || { error "Could not obtain sudo."; exit 1; }
    fi
  else
    error "Root is required to write to ${INSTALL_BASE} but 'sudo' is not available."
    error "Re-run as root, or pass --install-dir to a writable location."
    exit 1
  fi
}

as_root() { if [ -n "$SUDO" ]; then "$SUDO" "$@"; else "$@"; fi; }

# =============================================================================
# v1 stack passwords — .env.secrets
#
# bahmni-docker-ls keeps every password out of Git: .env holds none, and the
# stack reads them from a sibling .env.secrets (shipped only as
# .env.secrets.example). Its docker-compose.yml uses ${VAR:?}, so ANY compose
# call in RESTORE_DIR — up, exec, even ps — fails without those values, and
# restore_bahmni_standard.sh / run-bahmni.sh refuse to start without the file.
# =============================================================================

# v1_compose <compose args…> — docker compose for the v1 stack, with the
# secrets loaded. Run it from inside RESTORE_DIR (every caller does
# `cd "$RESTORE_DIR" && v1_compose …`). Passing --env-file replaces compose's
# implicit .env, so .env is named again first. sudo resets the environment,
# which is why the values go in as files rather than exported variables.
# Legacy docker-compose (v1) honors only one --env-file, so it gets none and
# behaves as before.
v1_compose() {
  local -a envs=()
  if [ "$DOCKER_COMPOSE" = "docker compose" ] && [ -f .env.secrets ]; then
    envs=(--env-file .env --env-file .env.secrets)
  fi
  # shellcheck disable=SC2086  # DOCKER_COMPOSE is "docker compose" — two words
  as_root $DOCKER_COMPOSE ${envs[@]+"${envs[@]}"} "$@"
}

# Where each secret can be recovered from, and what pins it. One line per key:
#   KEY | service:VAR … (container env holding the same value) | pin
# pin is
#   vol:<a>,<b>  a database volume initialised from the value: if any of these
#                volumes exists, the value MUST be recovered — a new one would
#                lock that database out. Otherwise a random value is safe.
#   data         stored in the restored OpenMRS dump (atomfeed users): recover
#                it if at all possible; random only means those feeds stop
#                authenticating, so it is allowed with a warning.
#   optional     an external credential the site may not use: empty is fine.
#   derived      built from other keys: the example's line is kept verbatim.
V1_SECRET_SOURCES='
MYSQL_ROOT_PASSWORD|openmrsdb:MYSQL_ROOT_PASSWORD reportsdb:MYSQL_ROOT_PASSWORD|vol:openmrsdbdata,reportsdbdata
OPENMRS_DB_PASSWORD|openmrsdb:MYSQL_PASSWORD openmrs:OMRS_DB_PASSWORD reports:OPENMRS_DB_PASSWORD|vol:openmrsdbdata
REPORTS_DB_PASSWORD|reportsdb:MYSQL_PASSWORD reports:REPORTS_DB_PASSWORD|vol:reportsdbdata
OPENELIS_DB_PASSWORD|openelisdb:POSTGRES_PASSWORD|vol:openelisdbdata
ODOO_DB_PASSWORD|odoodb:POSTGRES_PASSWORD odoo-connect:ODOO_DB_PASSWORD|vol:odoodbdata
ODOO_10_DB_PASSWORD|odoo-10-db:POSTGRES_PASSWORD odoo-10-connect:ODOO_DB_PASSWORD|vol:odoo10dbdata
PACS_DB_ROOT_PASSWORD|pacsdb:POSTGRES_PASSWORD|vol:pacsdbdata
DCM4CHEE_DB_PASSWORD|pacsdb:DCM4CHEE_DB_PASSWORD dcm4chee:DB_PASSWORD|vol:pacsdbdata
PACS_INTEGRATION_DB_PASSWORD|pacsdb:PACS_INTEGRATION_DB_PASSWORD pacs-integration:DB_PASSWORD|vol:pacsdbdata
METABASE_DB_PASSWORD|metabasedb:POSTGRES_PASSWORD metabase:MB_DB_PASS|vol:metabasedbdata
MART_DB_PASSWORD|martdb:POSTGRES_PASSWORD mart:MART_DB_PASSWORD|vol:martdbdata
METABASE_ADMIN_PASSWORD|metabase:MB_ADMIN_PASSWORD|vol:metabasedbdata
SNOWSTORM_LITE_ADMIN_PASSWORD|load-snowstorm-lite-data:SNOWSTORM_LITE_ADMIN_PASSWORD|vol:
OPENMRS_ATOMFEED_PASSWORD|openelis:OPENMRS_ATOMFEED_PASSWORD odoo-connect:OPENMRS_ATOMFEED_PASSWORD pacs-integration:OPENMRS_ATOMFEED_PASSWORD|data
OPENELIS_ATOMFEED_PASSWORD|openmrs:OPENELIS_ATOMFEED_PASSWORD odoo-connect:OPENELIS_ATOMFEED_PASSWORD|data
ODOO_ATOMFEED_PASSWORD|odoo-connect:ODOO_ATOMFEED_PASSWORD|data
ODOO_10_ATOMFEED_PASSWORD|odoo-10-connect:ODOO_ATOMFEED_PASSWORD|data
MAIL_PASSWORD|openmrs:MAIL_PASSWORD|optional
SMS_TOKEN|sms-service:SMS_TOKEN|optional
SNOWSTORM_LITE_JAVA_SERVER_OPTS||derived
'

# Reads a fixed 512 bytes rather than `tr </dev/urandom | head`: that pipe ends
# on SIGPIPE, which pipefail + set -e would turn into an abort. 512 random bytes
# keep ~124 alphanumerics, far more than the 32 used.
_v1_random_secret() {
  local s
  s="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  printf '%s' "${s:0:32}"
}

# _v1_container_env <project> <service> <VAR> — VAR's value in that compose
# service's container (running or stopped). Fails when there is none.
_v1_container_env() {
  local project="$1" svc="$2" var="$3" id line
  id="$(as_root docker ps -aq \
          --filter "label=com.docker.compose.project=${project}" \
          --filter "label=com.docker.compose.service=${svc}" 2>/dev/null | head -n1)"
  [ -n "$id" ] || return 1
  while IFS= read -r line; do
    case "$line" in "${var}="*) printf '%s' "${line#*=}"; return 0 ;; esac
  done < <(as_root docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2>/dev/null)
  return 1
}

# _v1_dotenv <file> <KEY> — KEY's raw value in a dotenv file (unquoted for a
# plain "KEY=value" line; quotes are kept as written otherwise).
_v1_dotenv() {
  local line
  line="$(as_root grep -m1 "^${2}=" "$1" 2>/dev/null)" || return 1
  printf '%s' "${line#*=}"
}

# _v1_volume_exists <project> <name> — does the compose volume exist?
# Unknown (docker unreachable) counts as "yes": that is the answer that can
# never lead to a database being re-keyed under its data.
_v1_volume_exists() {
  local out
  out="$(as_root docker volume ls -q --filter "name=^${1}_${2}\$" 2>/dev/null)" || return 0
  [ -n "$out" ]
}

# ensure_env_secrets — create RESTORE_DIR/.env.secrets when it is missing.
# Idempotent: an existing file is never touched, and a checkout that predates
# the split (no .env.secrets.example) needs nothing.
#
# Upstream replaced every value with CHANGE_ME in BOTH .env and .env.dev when
# it split the secrets out (bahmni-docker-ls 919e8dd), so neither can seed this.
# Each value is instead recovered from what the site actually runs with:
#   0. EREGISTER_ENV_SECRETS_FILE — an operator-prepared file, copied as is;
#   1. the v1 stack's own containers (running or stopped);
#   2. the frozen 0.92 stack: its containers, then ${OLD_DOCKER_DIR}/.env;
#   3. failing that, by pin (see V1_SECRET_SOURCES): random when the database
#      it initialises has no volume yet, empty when optional, and an error when
#      a volume already holds data keyed to the lost value.
ensure_env_secrets() {
  local secrets="${RESTORE_DIR}/.env.secrets"
  local example="${RESTORE_DIR}/.env.secrets.example"
  local project old_project tmp line key spec sources pin src svc var val v found p vols vol pinned
  local -a randomised=() feeds_random=() blocked=()

  if as_root test -f "$secrets"; then
    info "Stack passwords: using existing ${secrets}"
    return 0
  fi
  [ -f "$example" ] || return 0

  if [ -n "${EREGISTER_ENV_SECRETS_FILE:-}" ]; then
    if [ ! -r "$EREGISTER_ENV_SECRETS_FILE" ]; then
      error "EREGISTER_ENV_SECRETS_FILE=${EREGISTER_ENV_SECRETS_FILE} is not readable."
      return 1
    fi
    as_root install -m 600 "$EREGISTER_ENV_SECRETS_FILE" "$secrets" || return 1
    success "Installed ${secrets} (mode 600) from ${EREGISTER_ENV_SECRETS_FILE}."
    return 0
  fi

  project="$(basename "$RESTORE_DIR")"
  old_project="$(_v1_dotenv "${OLD_DOCKER_DIR:-/nonexistent}/.env" COMPOSE_PROJECT_NAME \
                 || basename "${OLD_DOCKER_DIR:-bahmni_docker}")"
  old_project="${old_project//\"/}"

  info "Creating ${secrets} from the values this site runs with…"
  tmp="$(mktemp)" || return 1   # mktemp creates the file 0600
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      [A-Z_]*=*) ;;
      *) printf '%s\n' "$line" >>"$tmp"; continue ;;
    esac
    key="${line%%=*}"
    spec="$(printf '%s\n' "$V1_SECRET_SOURCES" | grep -m1 "^${key}|")" || spec="${key}||vol:"
    sources="${spec#*|}"; pin="${sources#*|}"; sources="${sources%%|*}"

    if [ "$pin" = "derived" ]; then
      printf '%s\n' "$line" >>"$tmp"; continue
    fi

    found=0
    for p in "$project" "$old_project"; do
      for src in $sources; do
        svc="${src%%:*}"; var="${src#*:}"
        if v="$(_v1_container_env "$p" "$svc" "$var")" && [ -n "$v" ]; then
          # Container env is raw, but the file is also `source`d by bash:
          # single quotes are literal to both bash and compose.
          case "$v" in *[!A-Za-z0-9_@%+=:,./-]*) [[ "$v" == *"'"* ]] || v="'${v}'" ;; esac
          val="$v"; found=1; break 2
        fi
      done
    done
    if [ "$found" = "0" ] && v="$(_v1_dotenv "${OLD_DOCKER_DIR:-/nonexistent}/.env" "$key")" \
         && [ -n "$v" ] && [ "$v" != "CHANGE_ME" ]; then
      val="$v"; found=1
    fi

    if [ "$found" = "0" ]; then
      case "$pin" in
        optional) val="" ;;
        data)     val="$(_v1_random_secret)"; feeds_random+=("$key") ;;
        vol:*)
          vols="${pin#vol:}"; pinned=""
          for vol in ${vols//,/ }; do
            _v1_volume_exists "$project" "$vol" && pinned="${pinned:+$pinned, }${project}_${vol}"
          done
          if [ -n "$pinned" ]; then
            blocked+=("${key} (volume ${pinned})"); val="CHANGE_ME"
          else
            val="$(_v1_random_secret)"; randomised+=("$key")
          fi
          ;;
      esac
    fi
    # Recovered values are written as found (they may already carry quotes);
    # generated ones are alphanumeric and need none.
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
  done <"$example"

  if [ "${#blocked[@]}" -gt 0 ]; then
    rm -f "$tmp"
    error "Cannot create ${secrets}: these passwords are already baked into existing"
    error "database volumes, and no container or 0.92 .env still holds them:"
    for v in "${blocked[@]}"; do error "    ${v}"; done
    error "A new value would lock those databases out. Either:"
    error "  * write the file yourself from ${example} (the values the volumes were"
    error "    created with), chmod 600, and re-run; or"
    error "  * point EREGISTER_ENV_SECRETS_FILE at a prepared copy and re-run."
    return 1
  fi

  if ! as_root install -m 600 "$tmp" "$secrets"; then
    rm -f "$tmp"; error "Could not write ${secrets}."; return 1
  fi
  rm -f "$tmp"
  success "Created ${secrets} (mode 600)."
  if [ "${#randomised[@]}" -gt 0 ]; then
    info "New random values (no database held the old ones): ${randomised[*]}"
  fi
  if [ "${#feeds_random[@]}" -gt 0 ]; then
    warn "Not recoverable, set at random: ${feeds_random[*]}."
    warn "These must match the atomfeed users in the OpenMRS data. Only matters if OpenELIS,"
    warn "Odoo or PACS integration run on this site; if so, put the real values in ${secrets}."
  fi
  info "MAIL_PASSWORD and SMS_TOKEN are empty unless recovered; set them in ${secrets} if mail/SMS are used."
}
