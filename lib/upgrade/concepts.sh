# shellcheck shell=bash
# =============================================================================
# lib/upgrade/concepts.sh — import the v1 concept dictionary into the openmrs DB.
#
# The eregister_concepts_release_v1 repo (cloned to
# <base>/v1/eregister_concepts_release_v1 by fetch_repos) ships a mysqldump of
# the OpenMRS concept dictionary: omrs_concept_dictionary_v1.sql. This module
# feeds that dump into the 'openmrs' database inside the openmrsdb service —
# the scripted equivalent of the repo's manual "docker cp + mysql source" steps.
#
# WHAT THE DUMP DOES
#   It is a plain mysqldump (FOREIGN_KEY_CHECKS=0, DROP TABLE IF EXISTS +
#   CREATE TABLE + INSERTs) covering the concept_* / drug* tables. Importing it
#   therefore REPLACES those tables wholesale rather than merging into them.
#   Note that `drug_order` is among them, so any existing drug orders in the
#   target DB are replaced by the dump's. A pre-import dump of exactly the
#   tables the file touches is written to BACKUP_DIR first, so the import can be
#   undone by feeding that file back in the same way.
#
# Re-runnable: every run drops and recreates the same tables, so a second run
# simply lands the same content again (and picks up a newer dump after the
# auto-pull job refreshes the repo).
#
# Depends on: logging, prompt (confirm), as_root() (privilege).
# Uses config: CONCEPTS_DIR, CONCEPTS_SQL, RESTORE_DIR, BACKUP_DIR,
#              DOCKER_COMPOSE, DB_SERVICE, DB_NAME, DB_USER, DB_PASS,
#              CONCEPTS_DB_WAIT.
# =============================================================================

_concepts_resolve_compose() {
  # Populate DOCKER_COMPOSE if the caller (standalone script) hasn't already.
  [ -n "${DOCKER_COMPOSE:-}" ] && return 0
  if docker compose version >/dev/null 2>&1; then DOCKER_COMPOSE="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then DOCKER_COMPOSE="docker-compose"
  else error "docker compose not available."; return 1; fi
}

# -----------------------------------------------------------------------------
# _concepts_mysql — run mysql inside the DB service, reading SQL from stdin.
# The password comes from EREGISTER_DB_PASS when set, else the container's own
# MYSQL_ROOT_PASSWORD, so it never lands on a host process list. Extra args are
# appended to the mysql command line.
# -----------------------------------------------------------------------------
_concepts_mysql() {
  ( cd "$RESTORE_DIR" && as_root $DOCKER_COMPOSE exec -T "$DB_SERVICE" \
      sh -c 'pw="${3:-$MYSQL_ROOT_PASSWORD}"; user="$1"; db="$2"; shift 3
             exec mysql -u"$user" ${pw:+-p"$pw"} "$@" "$db"' \
         _ "$DB_USER" "$DB_NAME" "$DB_PASS" "$@" )
}

_concepts_db_ready() {
  # One connectivity probe: can we run a trivial query against DB_NAME?
  printf 'SELECT 1;\n' | _concepts_mysql -N >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# _concepts_wait_for_db — poll until the DB accepts queries, up to
# CONCEPTS_DB_WAIT seconds. The stack is usually still booting when this runs
# (openmrsdb comes up long before the EMR does), hence the wait.
# -----------------------------------------------------------------------------
_concepts_wait_for_db() {
  local waited=0 interval=5
  if _concepts_db_ready; then return 0; fi
  info "Waiting for ${DB_SERVICE}:${DB_NAME} to accept connections (up to ${CONCEPTS_DB_WAIT}s)…"
  while [ "$waited" -lt "$CONCEPTS_DB_WAIT" ]; do
    sleep "$interval"
    waited=$(( waited + interval ))
    if _concepts_db_ready; then
      success "Database reachable after ${waited}s."
      return 0
    fi
  done
  error "Database '${DB_NAME}' in service '${DB_SERVICE}' did not become reachable within ${CONCEPTS_DB_WAIT}s."
  return 1
}

# -----------------------------------------------------------------------------
# _concepts_tables — the tables the dump drops and recreates, read straight out
# of the .sql file so the backup below always matches the file being imported.
# -----------------------------------------------------------------------------
_concepts_tables() {
  as_root sed -n 's/^DROP TABLE IF EXISTS `\([A-Za-z0-9_]*\)`.*/\1/p' "$CONCEPTS_SQL" | sort -u
}

# -----------------------------------------------------------------------------
# _concepts_backup — dump the current contents of those tables before replacing
# them. Non-fatal on its own: the caller decides whether to continue without it.
# -----------------------------------------------------------------------------
_concepts_backup() {
  local out tables
  as_root mkdir -p "$BACKUP_DIR"
  out="${BACKUP_DIR}/concepts-preimport-$(date '+%Y%m%d_%H%M%S').sql"
  tables="$(_concepts_tables | tr '\n' ' ')"
  [ -n "${tables// /}" ] || { warn "No DROP TABLE statements found in ${CONCEPTS_SQL}; skipping pre-import backup."; return 1; }

  info "Backing up the tables about to be replaced -> ${out}"
  # mysqldump runs in the container; its stdout is piped through as_root tee so
  # the file can be written into a root-owned BACKUP_DIR.
  # shellcheck disable=SC2086  # $tables is a deliberate word-split table list
  if ( cd "$RESTORE_DIR" && as_root $DOCKER_COMPOSE exec -T "$DB_SERVICE" \
         sh -c 'pw="${3:-$MYSQL_ROOT_PASSWORD}"; user="$1"; db="$2"; shift 3
                exec mysqldump -u"$user" ${pw:+-p"$pw"} --single-transaction --no-tablespaces --skip-add-locks --complete-insert "$db" "$@"' \
            _ "$DB_USER" "$DB_NAME" "$DB_PASS" $tables ) | as_root tee "$out" >/dev/null
  then
    if [ -s "$out" ]; then
      success "Pre-import backup written: ${out}"
      CONCEPTS_PREIMPORT_SQL="$out"
      return 0
    fi
    warn "Pre-import backup came out empty; removing ${out}."
    as_root rm -f "$out"
    return 1
  fi
  warn "Pre-import backup failed (mysqldump error)."
  as_root rm -f "$out"
  return 1
}

# -----------------------------------------------------------------------------
# import_concepts — top-level entry, called from main() after the upgrade has
# been finalized and from the standalone import-concepts.sh.
# Returns non-zero on failure; callers treat that as advisory (the stack is
# already up, and the import can be retried by hand).
# -----------------------------------------------------------------------------
import_concepts() {
  step "Concept dictionary import"

  if [ "${IMPORT_CONCEPTS:-1}" != "1" ]; then
    info "Concept import disabled (--no-concepts / EREGISTER_IMPORT_CONCEPTS=0); skipping."
    return 0
  fi

  _concepts_resolve_compose || return 1
  [ -d "$RESTORE_DIR" ] || { error "v1 stack dir not found: ${RESTORE_DIR}. Has the upgrade run?"; return 1; }
  if [ ! -f "$CONCEPTS_SQL" ]; then
    error "Concept dump not found: ${CONCEPTS_SQL}"
    error "Expected it in the ${CONCEPTS_DIR} clone — re-run the installer, or set EREGISTER_CONCEPTS_SQL_NAME to the right filename."
    return 1
  fi

  warn "This REPLACES the concept dictionary in the '${DB_NAME}' database with"
  warn "${CONCEPTS_SQL}."
  warn "The dump drops and recreates the concept_*/drug* tables — including"
  warn "drug_order — so any rows those tables currently hold are replaced."
  confirm "Import the v1 concept dictionary now?" || { warn "Concept import skipped by user."; return 0; }

  _concepts_wait_for_db || return 1

  if ! _concepts_backup; then
    warn "Continuing without a pre-import backup of the concept tables."
    confirm "Import anyway, with no way to restore the current concept tables?" \
      || { warn "Concept import skipped by user."; return 0; }
  fi

  info "Importing ${CONCEPTS_SQL} into ${DB_SERVICE}:${DB_NAME} (this takes a few minutes)…"
  # as_root cat, so a root-owned clone is still readable; the dump carries its
  # own FOREIGN_KEY_CHECKS=0 preamble, so table order inside it is not our
  # problem.
  if as_root cat "$CONCEPTS_SQL" | _concepts_mysql; then
    success "Concept dictionary imported into ${DB_NAME}."
  else
    error "Concept import failed."
    if [ -n "${CONCEPTS_PREIMPORT_SQL:-}" ]; then
      error "Put the previous concept tables back with:"
      error "  cd ${RESTORE_DIR} && sudo cat ${CONCEPTS_PREIMPORT_SQL} | sudo ${DOCKER_COMPOSE} exec -T ${DB_SERVICE} mysql -u${DB_USER} -p ${DB_NAME}"
    fi
    return 1
  fi

  # Report what landed, as a cheap sanity check.
  local count
  count="$(printf 'SELECT COUNT(*) FROM concept;\n' | _concepts_mysql -N 2>/dev/null | tr -d '[:space:]')" || count=""
  [ -n "$count" ] && info "'${DB_NAME}'.concept now holds ${count} rows."

  notice "OpenMRS caches concepts. Restart the EMR service (${EMR_SERVICE}) once the import is done for the new dictionary to be picked up: ${DOCKER_COMPOSE} restart ${EMR_SERVICE}"
}
