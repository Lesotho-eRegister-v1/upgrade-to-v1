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
#              DOCKER_COMPOSE, DB_SERVICE, DB_NAME, DB_USER, DB_PASS.
# =============================================================================

# -----------------------------------------------------------------------------
# _concepts_resolve_sql — decide WHICH dump to import, and set CONCEPTS_SQL.
#
# The concepts repo names every release after the moment it was taken
# (run_concept_dump.sh: omrs_concept_dictionary_$(date +%Y%m%d_%H%M%S).sql), so
# there is no stable filename to pin — a new dictionary arrives as a NEW file
# beside the old one. Unless CONCEPTS_SQL_NAME pins an exact name, take the
# newest match of CONCEPTS_SQL_PATTERN: names sort chronologically, and mtime
# breaks ties for anything hand-placed.
# -----------------------------------------------------------------------------
_concepts_resolve_sql() {
  local pick=""

  if [ -n "${CONCEPTS_SQL_NAME:-}" ]; then
    CONCEPTS_SQL="${CONCEPTS_DIR}/${CONCEPTS_SQL_NAME}"
    [ -f "$CONCEPTS_SQL" ] && return 0
    error "Pinned concept dump not found: ${CONCEPTS_SQL}"
    error "Unset EREGISTER_CONCEPTS_SQL_NAME to use the newest ${CONCEPTS_SQL_PATTERN} instead."
    return 1
  fi

  [ -d "$CONCEPTS_DIR" ] || { error "Concepts clone not found: ${CONCEPTS_DIR}"; return 1; }
  # ls -t would order by mtime, which a fresh `git reset --hard` rewrites for
  # every file at once; sort by name so the timestamp IN the name decides.
  pick="$(as_root find "$CONCEPTS_DIR" -maxdepth 1 -name "$CONCEPTS_SQL_PATTERN" -type f 2>/dev/null \
          | sort | tail -1)"
  if [ -z "$pick" ]; then
    error "No concept dump matching '${CONCEPTS_SQL_PATTERN}' in ${CONCEPTS_DIR}"
    error "Has the repo been pulled? Contents: $(as_root ls "$CONCEPTS_DIR" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  CONCEPTS_SQL="$pick"
  info "Concept dump selected: $(basename "$CONCEPTS_SQL")"
  return 0
}

# sha256 of a file, coreutils or macOS spelling. Empty on failure.
_concepts_hash() { as_root sha256sum "$1" 2>/dev/null || as_root shasum -a 256 "$1" 2>/dev/null; }

# -----------------------------------------------------------------------------
# Import state — what this site last imported, so a scheduled run can tell a new
# dictionary from the one already in the database. Same question the form
# importer answers with its state file, and the same answer: hash the CONTENT,
# because the filename changes on every release and the mtime changes on every
# git reset.
# Plain key=value; it is read by the generated runner, which has no jq.
# -----------------------------------------------------------------------------
_concepts_state_get() { # _concepts_state_get <key>
  as_root sed -n "s/^${1}=//p" "$CONCEPT_IMPORT_STATE" 2>/dev/null | tail -1
}

_concepts_state_put() { # _concepts_state_put <sha256> <file> <rows>
  local tmp
  tmp="$(mktemp)"
  {
    printf '# eRegister v1 — the concept dictionary this site last imported.\n'
    printf '# Written by import_concepts; the scheduled job reads it to decide\n'
    printf '# whether the dump on disk is new. Delete it to force a re-import.\n'
    printf 'sha256=%s\n' "$1"
    printf 'file=%s\n'   "$2"
    printf 'rows=%s\n'   "$3"
    printf 'imported_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp"
  as_root install -m 0644 "$tmp" "$CONCEPT_IMPORT_STATE" 2>/dev/null \
    || warn "Could not write ${CONCEPT_IMPORT_STATE}; the scheduled import will re-import every night."
  rm -f "$tmp"
}

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
# _concepts_require_db — ONE connectivity probe. No polling.
#
# This used to poll for up to five minutes, on the theory that the import runs
# while the stack is still booting. In practice that turned a skippable step
# into a five-minute hang whenever openmrsdb was not coming up at all — and the
# import is not on the critical path: the dictionary can be loaded at any point
# afterwards with ./import-concepts.sh, and the daily job would pick it up in
# any case. So ask once, and if the answer is no, say why and let the caller
# move on.
# -----------------------------------------------------------------------------
_concepts_require_db() {
  if _concepts_db_ready; then return 0; fi
  warn "${DB_SERVICE}:${DB_NAME} is not accepting connections right now."
  warn "A freshly started v1 stack needs 30+ minutes before its database answers,"
  warn "so this is expected straight after an upgrade — it is not an error."
  warn "Skipping the concept dictionary; nothing else in this run depends on it."
  warn "Load it once the stack is up with:  ./import-concepts.sh"
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
# import_concepts — the import itself. Entered from ./import-concepts.sh, which
# is what both the scheduled runner and a human invoke; install.sh no longer
# calls it inline (see run_post_install there for why).
# Returns non-zero on failure; callers treat that as advisory — the stack is
# unaffected, and the import can be retried at any time.
# -----------------------------------------------------------------------------
import_concepts() {
  step "Concept dictionary import"

  if [ "${IMPORT_CONCEPTS:-1}" != "1" ]; then
    info "Concept import disabled (--no-concepts / EREGISTER_IMPORT_CONCEPTS=0); skipping."
    return 0
  fi

  _concepts_resolve_compose || return 1
  [ -d "$RESTORE_DIR" ] || { error "v1 stack dir not found: ${RESTORE_DIR}. Has the upgrade run?"; return 1; }
  _concepts_resolve_sql || return 1

  # Reachability first, so a database that is still booting costs one probe
  # rather than a prompt to replace tables we could not touch anyway.
  _concepts_require_db || return 1

  warn "This REPLACES the concept dictionary in the '${DB_NAME}' database with"
  warn "${CONCEPTS_SQL}."
  warn "The dump drops and recreates the concept_*/drug* tables — including"
  warn "drug_order — so any rows those tables currently hold are replaced."
  confirm "Import the v1 concept dictionary now?" || { warn "Concept import skipped by user."; return 0; }

  if ! _concepts_backup; then
    warn "Continuing without a pre-import backup of the concept tables."
    confirm "Import anyway, with no way to restore the current concept tables?" \
      "skip the concept import" \
      || { warn "Concept import skipped by user."; return 0; }
  fi

  info "Importing ${CONCEPTS_SQL} into ${DB_SERVICE}:${DB_NAME} (this takes a few minutes)…"
  # as_root cat, so a root-owned clone is still readable; the dump carries its
  # own FOREIGN_KEY_CHECKS=0 preamble, so table order inside it is not our
  # problem.
  if as_root cat "$CONCEPTS_SQL" | _concepts_mysql; then
    success "Concept dictionary imported into ${DB_NAME}."
    # Read by next_steps: only a run that imported may report an import.
    CONCEPTS_IMPORTED="1"
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

  # Record WHAT was imported, so the scheduled job can tell a genuinely new
  # dictionary from the one already loaded. Written on every successful import,
  # manual or scheduled, so a hand-run import never triggers a redundant one.
  _concepts_state_put "$(_concepts_hash "$CONCEPTS_SQL" | awk '{print $1}')" \
                      "$(basename "$CONCEPTS_SQL")" "${count:-unknown}"

  notice "OpenMRS caches concepts. Restart the EMR service (${EMR_SERVICE}) once the import is done for the new dictionary to be picked up: ${DOCKER_COMPOSE} restart ${EMR_SERVICE}"
}

# =============================================================================
# The scheduled concept-dictionary job.
#
# Separate from the daily form import on purpose: different content, different
# blast radius, different cadence. This one keeps the eregister_concepts_release_v1
# clone current and imports its dump into openmrsdb -> the 'openmrs' database,
# but ONLY when the dump's content has changed since the last import.
#
#   /usr/local/bin/eregister-concept-import.sh   the runner cron/systemd calls
#   eregister-concept-import.timer | /etc/cron.d/eregister-concept-import
#   <base>/v1/.eregister_concept_import_state    sha256 of what was imported
#   /var/log/eregister-concept-import.log        every run
#
# The runner does the cheap parts itself (refresh the clone, pick the newest
# dump, compare hashes) and hands the import to import-concepts.sh, so the
# pre-import backup, the DB wait and the import itself stay in ONE place rather
# than being duplicated into a generated file.
# =============================================================================

# -----------------------------------------------------------------------------
# _concepts_ensure_toolkit — the runner calls import-concepts.sh from the site's
# own checkout of this repo, so make sure that checkout exists.
# -----------------------------------------------------------------------------
_concepts_ensure_toolkit() {
  if [ -x "${UPGRADE_REPO_DIR}/import-concepts.sh" ] || [ -f "${UPGRADE_REPO_DIR}/import-concepts.sh" ]; then
    return 0
  fi
  info "The scheduled import needs a local checkout of this repo — cloning into ${UPGRADE_REPO_DIR}"
  if git_clone_or_update "$REPO_UPGRADE" "$UPGRADE_REPO_DIR" "$REF_UPGRADE"; then
    return 0
  fi
  error "Could not clone ${REPO_UPGRADE} into ${UPGRADE_REPO_DIR}."
  error "Without it the scheduled job has no importer to call."
  return 1
}

# -----------------------------------------------------------------------------
# _concepts_write_runner — generate the runner. Bare environment: no lib/, no
# PATH assumptions, its own log and its own ownership guard.
# -----------------------------------------------------------------------------
_concepts_write_runner() {
  local tmp
  tmp="$(mktemp)"
  {
    cat <<'HEADER'
#!/usr/bin/env bash
# eRegister v1 — scheduled concept-dictionary import.
#
# 1. refreshes the eregister_concepts_release_v1 clone
# 2. picks the newest omrs_concept_dictionary_*.sql in it
# 3. imports it into the openmrs database of the openmrsdb container — but only
#    when its content differs from the one recorded as last imported
#
# The import itself (pre-import backup, DB wait, mysql) is done by
# import-concepts.sh, not duplicated here. Installed by install.sh; safe to run
# by hand. Generated file: re-running the installer overwrites it.
set -uo pipefail
HEADER
    printf 'REPO_DIR=%q\n'    "$CONCEPTS_DIR"
    printf 'PATTERN=%q\n'     "$CONCEPTS_SQL_PATTERN"
    printf 'PINNED=%q\n'      "${CONCEPTS_SQL_NAME:-}"
    printf 'STATE=%q\n'       "$CONCEPT_IMPORT_STATE"
    printf 'LOG=%q\n'         "$CONCEPT_IMPORT_LOG"
    printf 'IMPORTER=%q\n'    "${UPGRADE_REPO_DIR}/import-concepts.sh"
    printf 'INSTALL_BASE=%q\n' "$INSTALL_BASE"
    printf 'SELF_PULL=%q\n'   "$CONCEPT_IMPORT_SELF_PULL"
    printf 'RESTART_EMR=%q\n' "$CONCEPT_IMPORT_RESTART_EMR"
    printf 'RESTORE_DIR=%q\n' "$RESTORE_DIR"
    printf 'EMR_SERVICE=%q\n' "$EMR_SERVICE"
    cat <<'BODY'

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG"; }

# Clones here may be owned by root or by the operator depending on how the
# installer ran; git refuses a repo owned by "someone else" unless told.
git_here() { git -c safe.directory='*' "$@"; }

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log "=== concept import run start (pid $$) ==="

if [ ! -d "$REPO_DIR" ]; then
  log "ERROR concepts clone not found: $REPO_DIR"
  exit 1
fi

# ------------------------------------------------------------------ 1. refresh
if [ "$SELF_PULL" = "1" ] && [ -d "$REPO_DIR/.git" ]; then
  if ! branch="$(git_here -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
    log "SKIP  refresh (git cannot read $REPO_DIR — ownership or permissions)"
  elif [ "$branch" = "HEAD" ]; then
    log "SKIP  refresh ($REPO_DIR is on a detached HEAD)"
  elif [ -n "$(git_here -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]; then
    log "SKIP  refresh ($REPO_DIR has uncommitted local changes)"
  elif git_here -C "$REPO_DIR" fetch --depth 1 origin "$branch" >>"$LOG" 2>&1 &&
       git_here -C "$REPO_DIR" reset --hard "origin/$branch" >>"$LOG" 2>&1; then
    log "OK    refreshed $REPO_DIR ($branch @ $(git_here -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null))"
  else
    log "WARN  could not refresh $REPO_DIR — using what is on disk"
  fi
fi

# ------------------------------------------------------------------ 2. which dump
# Every release lands under a new timestamped name, so take the newest by name
# (they sort chronologically) unless one was pinned at install time.
if [ -n "$PINNED" ]; then
  DUMP="$REPO_DIR/$PINNED"
else
  DUMP="$(find "$REPO_DIR" -maxdepth 1 -name "$PATTERN" -type f 2>/dev/null | sort | tail -1)"
fi
if [ -z "$DUMP" ] || [ ! -f "$DUMP" ]; then
  log "ERROR no dump matching '$PATTERN' in $REPO_DIR"
  exit 1
fi

# ------------------------------------------------------------------ 3. is it new?
if command -v sha256sum >/dev/null 2>&1; then
  HASH="$(sha256sum "$DUMP" | awk '{print $1}')"
else
  HASH="$(shasum -a 256 "$DUMP" | awk '{print $1}')"
fi
PREV="$(sed -n 's/^sha256=//p' "$STATE" 2>/dev/null | tail -1)"

if [ -n "$PREV" ] && [ "$PREV" = "$HASH" ]; then
  log "OK    $(basename "$DUMP") already imported (sha ${HASH:0:12}); nothing to do"
  log "=== concept import run end (rc=0) ==="
  exit 0
fi

if [ -n "$PREV" ]; then
  log "NEW   $(basename "$DUMP") differs from the imported dictionary (${PREV:0:12} -> ${HASH:0:12})"
else
  log "NEW   $(basename "$DUMP") — no previous import recorded"
fi

# ------------------------------------------------------------------ 4. import
if [ ! -f "$IMPORTER" ]; then
  log "ERROR importer not found: $IMPORTER (clone the upgrade-to-v1 repo there)"
  exit 1
fi
log "RUN   $IMPORTER --yes"
EREGISTER_INSTALL_BASE="$INSTALL_BASE" EREGISTER_ASSUME_YES=1 \
  bash "$IMPORTER" --yes --no-color >>"$LOG" 2>&1
rc=$?
if [ "$rc" != "0" ]; then
  log "ERROR import failed (rc=$rc) — the pre-import backup in the bahmni-backup folder undoes a partial run"
  log "=== concept import run end (rc=$rc) ==="
  exit "$rc"
fi
log "OK    imported $(basename "$DUMP")"

# ------------------------------------------------------------------ 5. cache
# OpenMRS caches concepts: until the EMR restarts, the new dictionary is on disk
# and in the database but not visible in the UI.
if [ "$RESTART_EMR" = "1" ]; then
  log "RUN   docker compose restart $EMR_SERVICE"
  if ( cd "$RESTORE_DIR" && docker compose restart "$EMR_SERVICE" >>"$LOG" 2>&1 ); then
    log "OK    $EMR_SERVICE restarted — it needs 30+ minutes to come back"
  else
    log "WARN  could not restart $EMR_SERVICE — restart it yourself for the new dictionary to show"
  fi
else
  log "NOTE  restart $EMR_SERVICE for the new dictionary to become visible (RESTART_EMR=0)"
fi

log "=== concept import run end (rc=0) ==="
exit 0
BODY
  } >"$tmp"

  as_root install -m 0755 "$tmp" "$CONCEPT_IMPORT_RUNNER"
  rm -f "$tmp"
  success "Installed concept-import runner: ${CONCEPT_IMPORT_RUNNER}"
}

_concepts_install_systemd_timer() {
  local svc="/etc/systemd/system/${CONCEPT_IMPORT_UNIT}.service"
  local tim="/etc/systemd/system/${CONCEPT_IMPORT_UNIT}.timer"

  printf '%s\n' \
    "# Written by the eRegister v1 installer — re-running it overwrites this file." \
    "[Unit]" \
    "Description=eRegister v1 — import a new concept dictionary" \
    "After=network-online.target docker.service" \
    "Wants=network-online.target" \
    "" \
    "[Service]" \
    "Type=oneshot" \
    "TimeoutStartSec=0" \
    "ExecStart=${CONCEPT_IMPORT_RUNNER}" \
    | as_root tee "$svc" >/dev/null
  as_root chmod 0644 "$svc"

  printf '%s\n' \
    "# Written by the eRegister v1 installer — re-running it overwrites this file." \
    "[Unit]" \
    "Description=eRegister v1 — daily check for a new concept dictionary" \
    "" \
    "[Timer]" \
    "OnCalendar=${CONCEPT_IMPORT_ONCALENDAR}" \
    "Persistent=true" \
    "RandomizedDelaySec=300" \
    "" \
    "[Install]" \
    "WantedBy=timers.target" \
    | as_root tee "$tim" >/dev/null
  as_root chmod 0644 "$tim"

  as_root systemctl daemon-reload
  as_root systemctl enable --now "${CONCEPT_IMPORT_UNIT}.timer"
  success "systemd timer enabled: ${CONCEPT_IMPORT_UNIT}.timer (OnCalendar=${CONCEPT_IMPORT_ONCALENDAR})"
}

_concepts_install_cron_job() {
  local cronfile="/etc/cron.d/${CONCEPT_IMPORT_UNIT}"
  printf '%s\n' \
    "# Written by the eRegister v1 installer — remove this file to disable the concept-dictionary import." \
    "SHELL=/bin/bash" \
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "${CONCEPT_IMPORT_CRON} root ${CONCEPT_IMPORT_RUNNER}" \
    | as_root tee "$cronfile" >/dev/null
  as_root chmod 0644 "$cronfile"
  success "Cron job installed: ${cronfile} (${CONCEPT_IMPORT_CRON})"
}

_concepts_schedule() {
  if has_systemd; then
    _concepts_install_systemd_timer
  elif [ -d /etc/cron.d ]; then
    warn "systemd not detected — falling back to a /etc/cron.d entry."
    _concepts_install_cron_job
  else
    warn "Neither systemd nor /etc/cron.d is available. The runner is at"
    warn "${CONCEPT_IMPORT_RUNNER} but NOT scheduled — add your own entry:"
    warn "  ${CONCEPT_IMPORT_CRON} root ${CONCEPT_IMPORT_RUNNER}"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# The DELAYED FIRST RUN.
#
# The dictionary is deliberately not imported at the end of the upgrade. The
# stack has only just been started there, and while openmrsdb answers early, the
# instance behind it needs 30+ minutes (often hours on site hardware) before the
# import is worth doing — so an inline import either blocked the installer or
# skipped for nothing. Instead the job is installed and given ONE shot a few
# hours out; the daily job takes over from there.
#
# Backends, in order: a transient systemd timer (one command, nothing to write
# or clean up), then `at`. Neither available is not a failure — the daily job is
# the backstop, and that is what the message says.
# -----------------------------------------------------------------------------
_concepts_first_run_when() {
  # Human-readable local time of the first run; falls back to a relative label.
  local at; at=$(( $(date +%s) + $1 ))
  date -d "@${at}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
    || date -r "$at" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
    || printf '%sh from now' "$(( $1 / 3600 ))"
}

_concepts_schedule_first_run() {
  local secs="$CONCEPT_IMPORT_FIRST_DELAY_SEC" unit="${CONCEPT_IMPORT_UNIT}-first" when

  if [ "${CONCEPT_IMPORT_FIRST_RUN:-1}" != "1" ]; then
    info "No delayed first import (EREGISTER_CONCEPT_IMPORT_FIRST_RUN=0);"
    info "the daily job at ${CONCEPT_IMPORT_CRON} will be the first one."
    return 0
  fi
  when="$(_concepts_first_run_when "$secs")"

  if has_systemd; then
    # Clear any timer a previous install left pending or failed, so --unit is
    # free to be created again.
    as_root systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
    as_root systemctl reset-failed "$unit" "${unit}.timer" >/dev/null 2>&1 || true
    if as_root systemd-run --quiet --unit="$unit" --on-active="$secs" \
         --timer-property=AccuracySec=1min \
         --description="eRegister v1 — first concept-dictionary import" \
         "$CONCEPT_IMPORT_RUNNER" >/dev/null 2>&1; then
      success "First concept import scheduled for ~${when}."
      info "  Check:  systemctl list-timers ${unit}.timer"
      info "  Cancel: sudo systemctl stop ${unit}.timer"
      info "  Log:    ${CONCEPT_IMPORT_LOG}"
      warn  "It is a transient timer: a reboot before then drops it, and the"
      warn  "daily job (${CONCEPT_IMPORT_CRON}) becomes the first import instead."
      return 0
    fi
    warn "systemd-run could not schedule the one-off first import."
  fi

  if command -v at >/dev/null 2>&1; then
    if printf '%s\n' "$CONCEPT_IMPORT_RUNNER" \
         | as_root at now + $(( (secs + 59) / 60 )) minutes >/dev/null 2>&1; then
      success "First concept import queued with 'at' for ~${when} (list it with: atq)."
      return 0
    fi
    warn "'at' could not queue the one-off first import."
  fi

  # Not a failure: the job IS installed, it just starts a bit later than asked.
  warn "No way to schedule a one-off run on this host (no systemd, no 'at')."
  warn "The daily job (${CONCEPT_IMPORT_CRON}) will take the first import, or run"
  warn "it yourself once the instance is up:  sudo ${CONCEPT_IMPORT_RUNNER}"
  return 0
}

# -----------------------------------------------------------------------------
# install_concept_import — top-level entry: install the runner and schedule it.
# Called from install.sh after the first import, and from
# ./import-concepts.sh --schedule.
# -----------------------------------------------------------------------------
install_concept_import() {
  step "Scheduling the concept-dictionary import"

  if [ "${CONCEPT_IMPORT:-1}" != "1" ]; then
    info "Concept-import job disabled (EREGISTER_CONCEPT_IMPORT=0); skipping."
    return 0
  fi

  info "The job runs daily (${CONCEPT_IMPORT_CRON}) and, in one run:"
  info "  • fast-forwards ${CONCEPTS_DIR}"
  info "  • picks the newest ${CONCEPTS_SQL_PATTERN} in it"
  info "  • imports it into ${DB_SERVICE}:${DB_NAME} — ONLY if its content changed"
  info "It is separate from the daily form import, and leaves it untouched."
  if [ "${CONCEPT_IMPORT_FIRST_RUN:-1}" = "1" ]; then
    info "Nothing is imported right now: the instance has only just been started"
    info "and needs hours to finish booting. The FIRST import is scheduled for"
    info "~$(( CONCEPT_IMPORT_FIRST_DELAY_SEC / 3600 ))h from now, and the daily job carries on from there."
  fi
  warn "An import replaces the concept_*/drug* tables (a pre-import backup is taken"
  warn "first), and the new dictionary is only visible once the EMR restarts."

  confirm "Install the scheduled concept-dictionary import?" \
    || { info "Skipped. Install it later with: ./import-concepts.sh --schedule"; return 0; }

  _concepts_ensure_toolkit || return 1
  _concepts_write_runner
  _concepts_schedule || return 1
  _concepts_schedule_first_run

  if [ "$CONCEPT_IMPORT_RESTART_EMR" = "1" ]; then
    warn "EREGISTER_CONCEPT_IMPORT_RESTART_EMR=1: the job will restart ${EMR_SERVICE} after"
    warn "an import — 30+ minutes of EMR downtime, unattended, at ${CONCEPT_IMPORT_CRON}."
  else
    info "After an import the job logs that ${EMR_SERVICE} needs a restart; it does not"
    info "restart it (set EREGISTER_CONCEPT_IMPORT_RESTART_EMR=1 to change that)."
  fi
  info "Run it now with: sudo ${CONCEPT_IMPORT_RUNNER}   (log: ${CONCEPT_IMPORT_LOG})"
}
