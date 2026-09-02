# shellcheck shell=bash
# =============================================================================
# lib/upgrade/reporting.sh — import the OpenMRS report definitions into the
# openmrs DB.
#
# The openmrs_reporting_release repo (cloned to
# <base>/v1/openmrs_reporting_release by fetch_repos) ships a mysqldump of the
# OpenMRS reporting module's serialized_object table: Serialized_Object.sql.
# That table IS the report library — every report, cohort, indicator and
# dataset definition the Reports app offers is one serialized XML row in it.
# This module feeds that dump into the 'openmrs' database inside the openmrsdb
# service, the same way concepts.sh feeds in the dictionary.
#
# WHAT THE DUMP DOES
#   Plain mysqldump (FOREIGN_KEY_CHECKS=0, DROP TABLE IF EXISTS + CREATE TABLE
#   + INSERTs) covering serialized_object only. Importing it therefore REPLACES
#   that table wholesale rather than merging into it: report definitions written
#   on this site by hand, and not present in the release, are lost. A pre-import
#   dump of exactly the tables the file touches is written to BACKUP_DIR first,
#   so the import can be undone by feeding that file back in the same way.
#
#   Nothing else is touched — no patient data, no concepts, no obs. The blast
#   radius is one table of report definitions, which is why catch-up.sh imports
#   this one directly where it only ever REPORTS on the concept dictionary.
#
# WHO CALLS IT
#   catch-up.sh, via catchup_reporting. install.sh only CLONES the repo: it
#   finishes with a stack that has just been started, whose database needs 30+
#   minutes before an import is worth attempting.
#
# Re-runnable: the import is recorded by content hash, so a second run with an
# unchanged clone does nothing at all, and a run after the auto-pull job brings
# in a new release imports the new definitions.
#
# Depends on: logging, prompt (confirm), as_root() (privilege), and the DB
#             plumbing in concepts.sh (_concepts_resolve_compose,
#             _concepts_mysql, _concepts_db_ready) — same container, same
#             credentials handling, so it is reused rather than duplicated.
#             Both entrypoints that source this module source concepts.sh too.
# Uses config: REPORTING_DIR, REPORTING_SQL_NAME, REPORTING_SQL_PATTERN,
#              REPORTING_IMPORT_STATE, RESTORE_DIR, BACKUP_DIR, DOCKER_COMPOSE,
#              DB_SERVICE, DB_NAME, DB_USER, DB_PASS, EMR_SERVICE.
# =============================================================================

# -----------------------------------------------------------------------------
# _reporting_sql_files — WHICH dump(s) to import, one absolute path per line.
#
# A pinned REPORTING_SQL_NAME wins. Otherwise every REPORTING_SQL_PATTERN match
# at the top of the clone, in filename order — today that is the repo's single
# Serialized_Object.sql, and a second dump added upstream is picked up with no
# code change. Unlike the concept dictionary this does NOT take "the newest
# one": these files are a set to load, not successive releases of one file.
# -----------------------------------------------------------------------------
_reporting_sql_files() {
  if [ -n "${REPORTING_SQL_NAME:-}" ]; then
    local pinned="${REPORTING_DIR}/${REPORTING_SQL_NAME}"
    if as_root test -f "$pinned"; then printf '%s\n' "$pinned"; return 0; fi
    error "Pinned report dump not found: ${pinned}"
    error "Unset EREGISTER_REPORTING_SQL_NAME to import every ${REPORTING_SQL_PATTERN} in the clone instead."
    return 1
  fi

  [ -d "$REPORTING_DIR" ] || { error "Reporting clone not found: ${REPORTING_DIR}"; return 1; }

  local files
  files="$(as_root find "$REPORTING_DIR" -maxdepth 1 -name "$REPORTING_SQL_PATTERN" -type f 2>/dev/null | sort)"
  if [ -z "$files" ]; then
    error "No report dump matching '${REPORTING_SQL_PATTERN}' in ${REPORTING_DIR}"
    error "Has the repo been pulled? Contents: $(as_root ls "$REPORTING_DIR" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  printf '%s\n' "$files"
}

# sha256 of a file, coreutils or macOS spelling. Empty on failure.
_reporting_hash() { as_root sha256sum "$1" 2>/dev/null || as_root shasum -a 256 "$1" 2>/dev/null; }

# -----------------------------------------------------------------------------
# _reporting_fingerprint — one hash standing for the whole set of files that
# would be imported. Hash of "<sha256>  <basename>" lines, so it changes when a
# file's CONTENT changes and when a file is added or removed. Content, not
# mtime: every git reset rewrites the mtime of a file that did not change.
# Reads the file list on stdin.
# -----------------------------------------------------------------------------
_reporting_fingerprint() {
  local f h out=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    h="$(_reporting_hash "$f" | awk '{print $1}')"
    [ -n "$h" ] || return 1
    out+="${h}  $(basename "$f")"$'\n'
  done
  printf '%s' "$out" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | awk '{print $1}'
}

# -----------------------------------------------------------------------------
# Import state — what this site last imported, so a repeat run can tell a new
# release of the report definitions from the ones already in the database.
# Plain key=value, same shape as the concept import's state file.
# -----------------------------------------------------------------------------
_reporting_state_get() { # _reporting_state_get <key>
  as_root sed -n "s/^${1}=//p" "$REPORTING_IMPORT_STATE" 2>/dev/null | tail -1
}

_reporting_state_put() { # _reporting_state_put <fingerprint> <files> <rows>
  local tmp
  tmp="$(mktemp)"
  {
    printf '# eRegister v1 — the report definitions this site last imported.\n'
    printf '# Written by import_reporting; catch-up.sh reads it to decide whether\n'
    printf '# the dump in the clone is new. Delete it to force a re-import.\n'
    printf 'sha256=%s\n' "$1"
    printf 'files=%s\n'  "$2"
    printf 'rows=%s\n'   "$3"
    printf 'imported_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp"
  as_root install -m 0644 "$tmp" "$REPORTING_IMPORT_STATE" 2>/dev/null \
    || warn "Could not write ${REPORTING_IMPORT_STATE}; the next run will re-import the same dump."
  rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# _reporting_tables — the tables the dumps drop and recreate, read straight out
# of the .sql files so the backup below always matches what is being imported.
# Reads the file list on stdin.
# -----------------------------------------------------------------------------
_reporting_tables() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    as_root sed -n 's/^DROP TABLE IF EXISTS `\([A-Za-z0-9_]*\)`.*/\1/p' "$f"
  done | sort -u
}

# -----------------------------------------------------------------------------
# _reporting_backup — dump the current contents of those tables before replacing
# them. Non-fatal on its own: the caller decides whether to continue without it.
# A table the dump creates but this database does not have yet (a site whose
# reporting module never ran) is not an error — mysqldump is asked only for the
# tables that actually exist.
# -----------------------------------------------------------------------------
_reporting_backup() { # _reporting_backup <table>...
  local out tables=""
  as_root mkdir -p "$BACKUP_DIR"
  out="${BACKUP_DIR}/reporting-preimport-$(date '+%Y%m%d_%H%M%S').sql"

  local t
  for t in "$@"; do
    if printf 'SELECT 1 FROM `%s` LIMIT 1;\n' "$t" | _concepts_mysql -N >/dev/null 2>&1; then
      tables+="${t} "
    else
      info "Table '${t}' is not in '${DB_NAME}' yet — nothing of it to back up."
    fi
  done
  if [ -z "${tables// /}" ]; then
    info "None of the tables in the dump exist yet; no pre-import backup needed."
    return 0
  fi

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
      REPORTING_PREIMPORT_SQL="$out"
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
# import_reporting — the import itself.
#
# Sets, for the caller to report on:
#   REPORTING_STATUS  one of: imported | current | declined | disabled |
#                             no-dump | no-db | failed
#   REPORTING_DETAIL  a one-line explanation of that status
#   REPORTING_ROWS    serialized_object row count after a successful import
#
# Returns non-zero only when something actually went wrong (failed). "Nothing
# to do" and "the operator said no" are successes: the stack is unaffected
# either way and the import can be retried at any time.
# -----------------------------------------------------------------------------
import_reporting() {
  step "OpenMRS report definitions"

  REPORTING_STATUS=""; REPORTING_DETAIL=""; REPORTING_ROWS=""

  if [ "${IMPORT_REPORTING:-1}" != "1" ]; then
    info "Report definition import disabled (--no-reporting / EREGISTER_IMPORT_REPORTING=0); skipping."
    REPORTING_STATUS="disabled"; REPORTING_DETAIL="left alone (--no-reporting)"
    return 0
  fi

  local files
  if ! files="$(_reporting_sql_files)" || [ -z "$files" ]; then
    REPORTING_STATUS="no-dump"
    REPORTING_DETAIL="no ${REPORTING_SQL_PATTERN} in ${REPORTING_DIR}"
    return 0
  fi

  local names size
  # paste -sd takes a LIST of delimiter characters, not a separator string, so
  # ', ' would alternate ',' and ' ' between names. Join with commas, then space.
  names="$(printf '%s\n' "$files" | while IFS= read -r f; do basename "$f"; done | paste -sd, - | sed 's/,/, /g')"
  # Summed by hand rather than with `du -c`: as_root is a shell function, so the
  # file list cannot simply be handed to one du invocation through xargs.
  size="$(printf '%s\n' "$files" | while IFS= read -r f; do
            [ -n "$f" ] && as_root du -k "$f" 2>/dev/null | awk '{print $1}'
          done | awk '{s+=$1} END {if (s>=1024) printf "%.1f MB", s/1024; else printf "%d KB", s}')"
  info "Report dump(s) selected: ${names} (${size:-size unknown})"

  # Has this exact content already been imported? Answering before touching the
  # database is what makes catch-up safe to run on a schedule: an unchanged
  # clone costs a hash and nothing else.
  local disk_fp prev_fp prev_when
  # `|| disk_fp=""`: an unhashable file must not abort the run, and must not be
  # mistaken for "same as last time" either — the compare below fails closed.
  disk_fp="$(printf '%s\n' "$files" | _reporting_fingerprint)" || disk_fp=""
  prev_fp="$(_reporting_state_get sha256)"
  prev_when="$(_reporting_state_get imported_at)"
  if [ -n "$disk_fp" ] && [ "$disk_fp" = "$prev_fp" ]; then
    success "These report definitions are already in '${DB_NAME}' (imported ${prev_when:-?}); nothing to do."
    REPORTING_STATUS="current"
    REPORTING_DETAIL="${names} already imported (${prev_when:-?})"
    return 0
  fi

  _concepts_resolve_compose || {
    REPORTING_STATUS="no-db"; REPORTING_DETAIL="docker compose not available on this host"
    return 0
  }
  if [ ! -d "$RESTORE_DIR" ]; then
    error "v1 stack dir not found: ${RESTORE_DIR}. Has the upgrade run?"
    REPORTING_STATUS="no-db"; REPORTING_DETAIL="no stack directory at ${RESTORE_DIR}"
    return 0
  fi
  # One probe, no polling — same reasoning as the concept import: a database
  # that is still booting should cost one question, not a five-minute hang.
  if ! _concepts_db_ready; then
    warn "${DB_SERVICE}:${DB_NAME} is not accepting connections right now."
    warn "A freshly started v1 stack needs 30+ minutes before its database answers,"
    warn "so this is expected straight after an upgrade — it is not an error."
    warn "Skipping the report definitions; nothing else in this run depends on them."
    REPORTING_STATUS="no-db"
    REPORTING_DETAIL="${DB_SERVICE}:${DB_NAME} not reachable — re-run catch-up once the stack is up"
    return 0
  fi

  local tables
  tables="$(printf '%s\n' "$files" | _reporting_tables | tr '\n' ' ')"
  if [ -z "${tables// /}" ]; then
    error "No DROP TABLE statements in ${names} — this does not look like a mysqldump."
    REPORTING_STATUS="failed"; REPORTING_DETAIL="${names} has no DROP TABLE statements; refusing to import it"
    return 1
  fi

  warn "This REPLACES the report definitions in the '${DB_NAME}' database with"
  warn "${REPORTING_DIR}/{${names}}."
  warn "The dump drops and recreates: ${tables}"
  warn "Report/cohort/indicator definitions created on this site by hand, and not"
  warn "in the release, are replaced. Patient data is NOT touched."
  if ! confirm "Import the v1 report definitions now?"; then
    warn "Report definition import skipped by user."
    REPORTING_STATUS="declined"
    REPORTING_DETAIL="declined — run catch-up again, or import ${names} by hand"
    return 0
  fi

  # shellcheck disable=SC2086  # $tables is a deliberate word-split table list
  if ! _reporting_backup $tables; then
    warn "Continuing without a pre-import backup of the report definition tables."
    if ! confirm "Import anyway, with no way to restore the current report definitions?" \
                 "skip the report definition import"; then
      warn "Report definition import skipped by user."
      REPORTING_STATUS="declined"; REPORTING_DETAIL="declined (no pre-import backup could be taken)"
      return 0
    fi
  fi

  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    info "Importing $(basename "$f") into ${DB_SERVICE}:${DB_NAME}…"
    # as_root cat, so a root-owned clone is still readable; the dump carries its
    # own FOREIGN_KEY_CHECKS=0 preamble, so table order inside it is not our
    # problem.
    if ! as_root cat "$f" | _concepts_mysql; then
      error "Report definition import failed on $(basename "$f")."
      if [ -n "${REPORTING_PREIMPORT_SQL:-}" ]; then
        error "Put the previous report definitions back with:"
        error "  cd ${RESTORE_DIR} && sudo cat ${REPORTING_PREIMPORT_SQL} | sudo ${DOCKER_COMPOSE} exec -T ${DB_SERVICE} mysql -u${DB_USER} -p ${DB_NAME}"
      fi
      REPORTING_STATUS="failed"; REPORTING_DETAIL="import of $(basename "$f") FAILED"
      return 1
    fi
  done <<<"$files"
  success "Report definitions imported into ${DB_NAME}."

  # Report what landed, as a cheap sanity check.
  local count
  count="$(printf 'SELECT COUNT(*) FROM serialized_object;\n' | _concepts_mysql -N 2>/dev/null | tr -d '[:space:]')" || count=""
  [ -n "$count" ] && info "'${DB_NAME}'.serialized_object now holds ${count} rows."
  REPORTING_ROWS="${count:-}"

  _reporting_state_put "$disk_fp" "$names" "${count:-unknown}"

  REPORTING_STATUS="imported"
  REPORTING_DETAIL="${names} imported — serialized_object holds ${count:-unknown} rows"

  notice "OpenMRS caches report definitions. Restart the EMR service (${EMR_SERVICE}) for the new reports to appear: ${DOCKER_COMPOSE} restart ${EMR_SERVICE}"
}
