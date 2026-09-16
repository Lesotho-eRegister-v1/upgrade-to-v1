# shellcheck shell=bash
# =============================================================================
# lib/upgrade/idgen.sh — retire the disused identifier source.
#
# WHO LOADS THIS
#   ./catch-up.sh only, through catchup_idgen in lib/upgrade/catchup.sh. It
#   reuses the database plumbing in concepts.sh (_concepts_mysql,
#   _concepts_resolve_compose, _concepts_db_ready), so that module must be
#   sourced first.
#
# WHAT IT DOES
#   Marks one row of idgen_identifier_source retired in the 'openmrs' database
#   of the openmrsdb service:
#
#       UPDATE idgen_identifier_source
#       SET retired = 1, retired_by = 1, date_retired = NOW(),
#           retire_reason = 'No longer in use'
#       WHERE id = 14 AND retired = 0;
#
#   OpenMRS retires rather than deletes: the source stays on file, stops being
#   offered, and the identifiers it already issued keep resolving. So this is
#   reversible — the report prints the statement that undoes it.
#
# WHY `AND retired = 0` IS NOT IN THE STATEMENT AS HANDED OVER
#   Without it the UPDATE matches every time and rewrites date_retired = NOW()
#   on every run, so the site loses the date it was actually retired and the
#   catch-up report claims a change it did not really make. With it, the second
#   and every later run match zero rows and the step is a true no-op. The
#   database is then its own state file: nothing extra to keep in sync, and a
#   site restored from a backup taken before the change gets it applied again.
#
#   The flip side, and it is deliberate: this RE-ASSERTS. An operator who
#   un-retires that source by hand will find the next catch-up retiring it
#   again. Pass --no-idgen (or EREGISTER_IDGEN_RETIRE=0) on a site where that
#   source is wanted back.
#
# WHY IT IS A WRITE CATCH-UP PERFORMS ITSELF
#   Same reasoning as the report definitions: one row of one table, no patient
#   data, reversible in a single statement, and nothing else on the site is ever
#   going to do it. Reporting it as a gap would leave the gap open forever.
#
# Depends on: logging, prompt (confirm), concepts.sh (the DB plumbing).
# Uses config: IDGEN_*, DB_NAME, DB_SERVICE, RESTORE_DIR, DOCKER_COMPOSE.
# =============================================================================

# -----------------------------------------------------------------------------
# _idgen_row — the row as it stands, as "<name>\t<uuid>\t<retired>" on stdout;
# empty when there is no such id. -N drops the column headers.
# -----------------------------------------------------------------------------
_idgen_row() {
  printf 'SELECT name, uuid, retired FROM idgen_identifier_source WHERE id = %s;\n' \
    "$IDGEN_RETIRE_ID" | _concepts_mysql -N 2>/dev/null
}

# -----------------------------------------------------------------------------
# retire_idgen_source — the step itself.
#
# Sets, for the caller to report on:
#   IDGEN_STATUS  one of: retired | already | disabled | declined | no-row |
#                         no-db | failed
#   IDGEN_DETAIL  a one-line explanation of that status
#
# Returns non-zero only when the update was attempted and failed. "Nothing to
# do", "no such row" and "the operator said no" are successes: the database is
# unchanged either way and the step can be retried on the next run.
# -----------------------------------------------------------------------------
retire_idgen_source() {
  step "Identifier source (idgen)"

  IDGEN_STATUS=""; IDGEN_DETAIL=""

  if [ "${IDGEN_RETIRE:-1}" != "1" ]; then
    info "Identifier source retirement disabled (--no-idgen / EREGISTER_IDGEN_RETIRE=0); skipping."
    IDGEN_STATUS="disabled"; IDGEN_DETAIL="left alone (--no-idgen)"
    return 0
  fi

  _concepts_resolve_compose >/dev/null 2>&1 || {
    IDGEN_STATUS="no-db"; IDGEN_DETAIL="docker compose not available on this host"
    return 0
  }
  if [ ! -d "$RESTORE_DIR" ]; then
    IDGEN_STATUS="no-db"; IDGEN_DETAIL="no stack directory at ${RESTORE_DIR}"
    return 0
  fi
  # One probe, no polling — same reasoning as the concept and report imports: a
  # database that is still booting should cost one question, not a hang.
  if ! _concepts_db_ready; then
    warn "${DB_SERVICE}:${DB_NAME} is not accepting connections right now."
    warn "A freshly started v1 stack needs 30+ minutes before its database answers,"
    warn "so this is expected straight after an upgrade — it is not an error."
    IDGEN_STATUS="no-db"
    IDGEN_DETAIL="${DB_SERVICE}:${DB_NAME} not reachable — re-run catch-up once the stack is up"
    return 0
  fi

  # Look before writing: the report should name what was retired, not just the
  # id, and an id that means something else on this site is worth seeing.
  local row name uuid retired
  row="$(_idgen_row)" || row=""
  if [ -z "$row" ]; then
    warn "No idgen_identifier_source row with id ${IDGEN_RETIRE_ID} in '${DB_NAME}'."
    warn "Nothing was changed. Check the id against this site's own table:"
    warn "  SELECT id, name, retired FROM idgen_identifier_source;"
    IDGEN_STATUS="no-row"
    IDGEN_DETAIL="no source with id ${IDGEN_RETIRE_ID} in ${DB_NAME} — nothing retired (set EREGISTER_IDGEN_RETIRE_ID, or --no-idgen)"
    return 0
  fi
  IFS=$'\t' read -r name uuid retired <<<"$row"

  if [ "$retired" = "1" ]; then
    success "Identifier source ${IDGEN_RETIRE_ID} ('${name}') is already retired; nothing to do."
    IDGEN_STATUS="already"
    IDGEN_DETAIL="'${name}' already retired"
    return 0
  fi

  info "Identifier source ${IDGEN_RETIRE_ID}: '${name}' (uuid ${uuid}), currently in use."
  warn "Retiring it stops it being offered for new identifiers. The identifiers it"
  warn "has already issued are NOT touched, and the row is kept — this is reversible."
  if ! confirm "Retire identifier source ${IDGEN_RETIRE_ID} ('${name}') now?"; then
    warn "Identifier source retirement skipped by user."
    IDGEN_STATUS="declined"
    IDGEN_DETAIL="declined — '${name}' left in use"
    return 0
  fi

  # Doubled, because the reason is interpolated into a single-quoted SQL string.
  local reason="${IDGEN_RETIRE_REASON//\'/\'\'}"
  if ! printf 'UPDATE idgen_identifier_source
SET retired = 1,
    retired_by = %s,
    date_retired = NOW(),
    retire_reason = '\''%s'\''
WHERE id = %s
  AND retired = 0;\n' "$IDGEN_RETIRE_BY" "$reason" "$IDGEN_RETIRE_ID" | _concepts_mysql
  then
    error "Could not retire identifier source ${IDGEN_RETIRE_ID} ('${name}')."
    IDGEN_STATUS="failed"
    IDGEN_DETAIL="UPDATE failed for id ${IDGEN_RETIRE_ID} ('${name}')"
    return 1
  fi

  # Read it back rather than trusting the exit status: mysql is perfectly happy
  # to report success for an UPDATE that matched nothing.
  row="$(_idgen_row)" || row=""
  IFS=$'\t' read -r name uuid retired <<<"$row"
  if [ "$retired" != "1" ]; then
    error "The UPDATE ran but id ${IDGEN_RETIRE_ID} is still not retired."
    IDGEN_STATUS="failed"
    IDGEN_DETAIL="id ${IDGEN_RETIRE_ID} ('${name}') is still in use after the UPDATE"
    return 1
  fi

  success "Identifier source ${IDGEN_RETIRE_ID} ('${name}') retired."
  info "Undo it with:"
  info "  UPDATE idgen_identifier_source SET retired = 0, retired_by = NULL,"
  info "         date_retired = NULL, retire_reason = NULL WHERE id = ${IDGEN_RETIRE_ID};"
  IDGEN_STATUS="retired"
  IDGEN_DETAIL="'${name}' retired (reason: ${IDGEN_RETIRE_REASON})"
}
