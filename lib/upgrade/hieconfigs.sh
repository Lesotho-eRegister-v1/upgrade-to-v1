# shellcheck shell=bash
# =============================================================================
# lib/upgrade/hieconfigs.sh — the HIE (MPI) client credentials in the EMR's
# openmrs-runtime.properties.
#
# WHO LOADS THIS
#   ./catch-up.sh only, through catchup_hie_configs in lib/upgrade/catchup.sh,
#   and only does anything when asked: --hie-configs (or EREGISTER_HIE_CONFIGS=1).
#
# WHAT IT DOES
#   Asks for the site's facility code (or takes EREGISTER_HIE_FACILITY_CODE) and
#   writes, into HIE_PROPERTIES inside the EMR service's container:
#
#     registrationcore.mpi.username=pixclient_<facility code, lowercase>
#     registrationcore.mpi.password=pixpdq<First letter, uppercase>@2019#Cli3nt
#
#   An existing line is replaced in place, a missing one is appended. When both
#   already hold those values nothing is written. Otherwise the file is copied to
#   <file>.bak-<timestamp> in the container first.
#
#   OpenMRS reads runtime properties only at startup, so this runs BEFORE the
#   EMR reload at the end of catch-up; with --no-recreate the new values wait
#   for the next restart.
#
# Depends on: logging, prompt (confirm), privilege (as_root), concepts.sh
#             (_concepts_resolve_compose).
# Uses config: HIE_*, EMR_SERVICE, RESTORE_DIR, DOCKER_COMPOSE, ASSUME_YES.
# =============================================================================

# _hie_exec <cmd...> — run a command inside the EMR service's container.
_hie_exec() {
  # shellcheck disable=SC2086  # $DOCKER_COMPOSE may be two words
  ( cd "$RESTORE_DIR" && as_root $DOCKER_COMPOSE exec -T "$EMR_SERVICE" "$@" )
}

# _hie_get <key> — the current value of <key> in HIE_PROPERTIES (empty if unset).
_hie_get() {
  _hie_exec sh -c 'grep -m1 "^$1=" "$2" | cut -d= -f2-' _ "$1" "$HIE_PROPERTIES" 2>/dev/null
}

# _hie_read_facility_code — HIE_FACILITY_CODE from the env, else from /dev/tty
# (stdin is the script itself when piped into bash). Returns 1 when there is no
# way to ask.
_hie_read_facility_code() {
  [ -n "${HIE_FACILITY_CODE:-}" ] && return 0
  if [ "$ASSUME_YES" = "1" ] || [ ! -r /dev/tty ]; then
    return 1
  fi
  while [ -z "${HIE_FACILITY_CODE:-}" ]; do
    printf '%sEnter facility code: %s' "$C_WARN" "$C_RESET" >/dev/tty
    read -r HIE_FACILITY_CODE </dev/tty || { printf '\n' >/dev/tty; return 1; }
    [ -n "$HIE_FACILITY_CODE" ] || warn "Facility code cannot be empty."
  done
}

# -----------------------------------------------------------------------------
# set_hie_configs — the step itself.
#
# Sets, for the caller to report on:
#   HIE_STATUS  one of: fixed | already | disabled | declined | no-code |
#                       no-emr | failed
#   HIE_DETAIL  a one-line explanation of that status
#
# Returns non-zero only when a write was attempted and failed.
# -----------------------------------------------------------------------------
set_hie_configs() {
  step "HIE client credentials (${HIE_PROPERTIES})"

  HIE_STATUS=""; HIE_DETAIL=""

  if [ "${HIE_CONFIGS:-0}" != "1" ]; then
    info "Not requested; pass --hie-configs to set the MPI client credentials."
    HIE_STATUS="disabled"; HIE_DETAIL="not requested (--hie-configs)"
    return 0
  fi

  if ! _concepts_resolve_compose >/dev/null 2>&1 || [ -z "${DOCKER_COMPOSE:-}" ]; then
    HIE_STATUS="no-emr"; HIE_DETAIL="docker compose not available on this host"
    return 0
  fi
  if [ ! -d "$RESTORE_DIR" ]; then
    HIE_STATUS="no-emr"; HIE_DETAIL="no stack directory at ${RESTORE_DIR}"
    return 0
  fi
  if ! _hie_exec test -f "$HIE_PROPERTIES" >/dev/null 2>&1; then
    HIE_STATUS="no-emr"
    HIE_DETAIL="'${EMR_SERVICE}' is not running or has no ${HIE_PROPERTIES}"
    return 0
  fi

  if ! _hie_read_facility_code; then
    HIE_STATUS="no-code"
    HIE_DETAIL="no facility code — set EREGISTER_HIE_FACILITY_CODE for a non-interactive run"
    return 0
  fi
  # It ends up in a sed expression and a properties file: keep it to what a
  # facility code actually looks like.
  if ! [[ "$HIE_FACILITY_CODE" =~ ^[A-Za-z0-9_-]+$ ]]; then
    error "Facility code '${HIE_FACILITY_CODE}' may only contain letters, digits, '_' and '-'."
    HIE_STATUS="no-code"; HIE_DETAIL="invalid facility code '${HIE_FACILITY_CODE}'"
    return 0
  fi

  local code first user pass cur_user cur_pass
  code="$(printf '%s' "$HIE_FACILITY_CODE" | tr '[:upper:]' '[:lower:]')"
  first="$(printf '%s' "${code:0:1}" | tr '[:lower:]' '[:upper:]')"
  user="pixclient_${code}"
  pass="pixpdq${first}@2019#Cli3nt"

  cur_user="$(_hie_get registrationcore.mpi.username)"
  cur_pass="$(_hie_get registrationcore.mpi.password)"
  if [ "$cur_user" = "$user" ] && [ "$cur_pass" = "$pass" ]; then
    info "Already set for facility '${code}'."
    HIE_STATUS="already"; HIE_DETAIL="MPI client '${user}' already configured"
    return 0
  fi

  info "registrationcore.mpi.username: '${cur_user:-<unset>}' -> '${user}'"
  info "registrationcore.mpi.password: $([ "$cur_pass" = "$pass" ] && echo unchanged || echo will be updated)"
  if ! confirm "Write the MPI client credentials for facility '${code}' into ${HIE_PROPERTIES}?"; then
    warn "HIE client credentials skipped by user."
    HIE_STATUS="declined"; HIE_DETAIL="declined — MPI credentials left as they were"
    return 0
  fi

  # The values travel as arguments, never spliced into the script text.
  if ! _hie_exec sh -c '
      f="$1"; cp -p "$f" "$f.bak-$(date +%Y%m%d_%H%M%S)" || exit 1
      shift
      while [ "$#" -gt 0 ]; do
        k="$1"; v="$2"; shift 2
        if grep -q "^$k=" "$f"; then
          sed -i "s|^$k=.*|$k=$v|" "$f" || exit 1
        else
          printf "%s=%s\n" "$k" "$v" >>"$f" || exit 1
        fi
      done' _ "$HIE_PROPERTIES" \
        registrationcore.mpi.username "$user" \
        registrationcore.mpi.password "$pass"
  then
    error "Could not update ${HIE_PROPERTIES} in '${EMR_SERVICE}'."
    HIE_STATUS="failed"; HIE_DETAIL="write to ${HIE_PROPERTIES} failed"
    return 1
  fi

  # Read it back rather than trusting the exit status.
  if [ "$(_hie_get registrationcore.mpi.username)" != "$user" ] \
     || [ "$(_hie_get registrationcore.mpi.password)" != "$pass" ]; then
    error "Wrote ${HIE_PROPERTIES} but the values did not stick."
    HIE_STATUS="failed"; HIE_DETAIL="values not present after the write"
    return 1
  fi

  info "Updated configuration:"
  _hie_exec grep -E '^registrationcore\.mpi\.(username|password)=' "$HIE_PROPERTIES" >&2 || true
  success "MPI client credentials set for facility '${code}'. The EMR reads them at its next start."
  HIE_STATUS="fixed"; HIE_DETAIL="set to '${user}' (backup ${HIE_PROPERTIES}.bak-* in the container)"
  return 0
}
