# shellcheck shell=bash
# =============================================================================
# lib/upgrade/dbbackup.sh — DAILY backup of the 'openmrs' database out of the
# v1 stack's openmrsdb service.
#
# Not to be confused with lib/upgrade/backup.sh: that one takes the ONE dump of
# the 0.92 EMR container that the migration restores from, once, before the
# upgrade. This module is about the site afterwards — a rolling nightly dump of
# the live v1 database, so a mistake at 10:00 costs a day and not a deployment.
#
# WHAT IT INSTALLS
#   /usr/local/bin/eregister-db-backup.sh   the backup script itself
#   eregister-db-backup.timer  |  /etc/cron.d/eregister-db-backup
#   <base>/v1/db-backups/openmrs_<stamp>.sql.gz   the dumps
#   <base>/v1/db-backups/latest.sql.gz            symlink to the newest one
#   /var/log/eregister-db-backup.log              every run
#
# The script is standalone on purpose — cron and systemd run it in a bare
# environment, so it carries its own logger, resolves docker compose itself and
# depends on nothing under lib/. Run it by hand at any time:
#     sudo /usr/local/bin/eregister-db-backup.sh
#
# WHAT ONE RUN DOES
#   1. mysqldump the whole 'openmrs' database inside the openmrsdb container
#      (--single-transaction: a consistent snapshot without locking writers)
#   2. stream it out, gzip it host-side, write it under a .part name
#   3. check the gzip integrity AND that mysqldump wrote its "Dump completed"
#      trailer — a dump cut short by an OOM or a restarting container is
#      otherwise a perfectly plausible-looking file that restores half a site
#   4. only then move it into place and repoint 'latest.sql.gz'
#   5. delete all but the newest DB_BACKUP_KEEP dumps
#
# Scheduled at 01:30 by default: before the auto-pull (02:30), the form import
# (03:30) and the concept import (04:30), so the night's dump is of the database
# as it was BEFORE anything scheduled touched it.
#
# Depends on: logging, prompt (confirm), as_root() (privilege), has_systemd()
#             (autopull).
# Uses config: RESTORE_DIR, DB_SERVICE, DB_NAME, DB_USER, DB_PASS,
#              DB_BACKUP_* (see lib/core/config.sh).
# =============================================================================

# -----------------------------------------------------------------------------
# _dbbackup_write_runner — generate and install the standalone backup script.
#
# Mode: 0755 normally. When EREGISTER_DB_PASS was set, the password is baked
# into the file and it goes in 0700 instead — the usual case bakes nothing,
# because the v1 database's root password is the container's own
# MYSQL_ROOT_PASSWORD and the script reads it there.
# -----------------------------------------------------------------------------
_dbbackup_write_runner() {
  local tmp mode="0755"
  [ -n "${DB_PASS:-}" ] && mode="0700"
  tmp="$(mktemp)"
  {
    cat <<'HEADER'
#!/usr/bin/env bash
# eRegister v1 — daily backup of the 'openmrs' database from the openmrsdb
# service. Installed by install.sh; safe to run by hand, as often as you like.
# Generated file: re-running the installer (or catch-up.sh) overwrites it.
set -uo pipefail
# Every file this writes — the dumps, the half-written .part, the log — holds
# patient data or its whereabouts. Create them root-only from the outset rather
# than chmod-ing after the fact, when the window has already been open.
umask 077
HEADER
    printf 'STACK_DIR=%q\n'  "$RESTORE_DIR"
    printf 'DB_SERVICE=%q\n' "$DB_SERVICE"
    printf 'DB_NAME=%q\n'    "$DB_NAME"
    printf 'DB_USER=%q\n'    "$DB_USER"
    printf 'DB_PASS=%q\n'    "${DB_PASS:-}"
    printf 'OUT_DIR=%q\n'    "$DB_BACKUP_DIR"
    printf 'LOG=%q\n'        "$DB_BACKUP_LOG"
    printf 'KEEP=%q\n'       "$DB_BACKUP_KEEP"
    printf 'COMPRESS=%q\n'   "$DB_BACKUP_COMPRESS"
    cat <<'BODY'

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG"; }

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log "=== db backup run start (pid $$) ==="

# --------------------------------------------------------------- docker compose
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  log "ERROR docker compose is not available on this host"
  log "=== db backup run end (rc=1) ==="
  exit 1
fi

if [ ! -d "$STACK_DIR" ]; then
  log "ERROR stack directory not found: $STACK_DIR"
  log "=== db backup run end (rc=1) ==="
  exit 1
fi

if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
  log "ERROR cannot create the backup directory: $OUT_DIR"
  log "=== db backup run end (rc=1) ==="
  exit 1
fi

# ------------------------------------------------------------------ the dump
# The password is passed as an ARGUMENT to a shell inside the container, never
# on this host's command line, and an empty one falls back to the container's
# own MYSQL_ROOT_PASSWORD — which is what a stock v1 stack uses. mariadb-dump
# is accepted as a stand-in where the image ships MariaDB rather than MySQL.
db_dump() {
  ( cd "$STACK_DIR" && $DC exec -T "$DB_SERVICE" \
      sh -c 'pw="${3:-$MYSQL_ROOT_PASSWORD}"; user="$1"; db="$2"
             if command -v mysqldump >/dev/null 2>&1; then d=mysqldump
             elif command -v mariadb-dump >/dev/null 2>&1; then d=mariadb-dump
             else echo "no mysqldump/mariadb-dump in the container" >&2; exit 127; fi
             exec "$d" -u"$user" ${pw:+-p"$pw"} \
                       --single-transaction --routines --triggers --events \
                       --hex-blob --no-tablespaces \
                       --default-character-set=utf8mb4 \
                       --databases "$db"' \
         _ "$DB_USER" "$DB_NAME" "$DB_PASS" )
}

STAMP="$(date '+%Y%m%d_%H%M%S')"
if [ "$COMPRESS" = "1" ]; then
  EXT="sql.gz"
else
  EXT="sql"
fi
FINAL="${OUT_DIR}/${DB_NAME}_${STAMP}.${EXT}"
PART="${FINAL}.part"

log "DUMP  ${DB_SERVICE}:${DB_NAME} -> $(basename "$FINAL")"
avail="$(df -Ph "$OUT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
[ -n "$avail" ] && log "DISK  ${avail} free on $(df -Ph "$OUT_DIR" 2>/dev/null | awk 'NR==2 {print $6}')"

rm -f "$PART"
# PIPESTATUS, not $?: a failing mysqldump behind a succeeding gzip still exits 0.
if [ "$COMPRESS" = "1" ]; then
  db_dump 2>>"$LOG" | gzip -c >"$PART"
else
  db_dump 2>>"$LOG" >"$PART"
fi
rc="${PIPESTATUS[0]}"

if [ "$rc" != "0" ]; then
  log "ERROR the dump command failed (rc=$rc) — is the ${DB_SERVICE} service up?"
  rm -f "$PART"
  log "=== db backup run end (rc=$rc) ==="
  exit "$rc"
fi
if [ ! -s "$PART" ]; then
  log "ERROR the dump came out empty"
  rm -f "$PART"
  log "=== db backup run end (rc=1) ==="
  exit 1
fi

# ------------------------------------------------------------------ integrity
# A dump cut short by an OOM, a disk filling up or a container restarting looks
# exactly like a good one until the day you restore it. mysqldump writes a
# "Dump completed" trailer as its last line; no trailer means no backup.
if [ "$COMPRESS" = "1" ]; then
  if ! gzip -t "$PART" 2>>"$LOG"; then
    log "ERROR the gzip stream is corrupt — keeping it as $(basename "$PART") for inspection"
    log "=== db backup run end (rc=1) ==="
    exit 1
  fi
  tail_txt="$(gzip -dc "$PART" 2>/dev/null | tail -5)"
else
  tail_txt="$(tail -5 "$PART" 2>/dev/null)"
fi

case "$tail_txt" in
  *"Dump completed"*) : ;;
  *)
    log "ERROR the dump has no 'Dump completed' trailer — it is TRUNCATED, not a usable backup"
    log "ERROR kept as $(basename "$PART") for inspection; delete it once you have looked"
    log "=== db backup run end (rc=1) ==="
    exit 1
    ;;
esac

mv -f "$PART" "$FINAL"
chmod 0600 "$FINAL" 2>/dev/null || true
size="$(du -h "$FINAL" 2>/dev/null | awk '{print $1}')"
log "OK    $(basename "$FINAL") (${size:-size unknown})"

# 'latest' is a convenience for a human at 3am, nothing depends on it.
ln -sfn "$FINAL" "${OUT_DIR}/latest.${EXT}" 2>/dev/null || true

# ------------------------------------------------------------------ retention
# Names carry the timestamp, so they sort chronologically; .part files are
# deliberately NOT matched, so a truncated dump is never silently rotated away
# before anyone has seen it.
if [ "$KEEP" -gt 0 ] 2>/dev/null; then
  files="$(find "$OUT_DIR" -maxdepth 1 -type f \
             \( -name "${DB_NAME}_*.sql" -o -name "${DB_NAME}_*.sql.gz" \) 2>/dev/null | sort)"
  total="$(printf '%s\n' "$files" | grep -c . )"
  if [ "$total" -gt "$KEEP" ]; then
    printf '%s\n' "$files" | head -n "$(( total - KEEP ))" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      rm -f "$f" && log "PRUNE $(basename "$f")"
    done
  fi
  log "KEEP  $(find "$OUT_DIR" -maxdepth 1 -type f \( -name "${DB_NAME}_*.sql" -o -name "${DB_NAME}_*.sql.gz" \) 2>/dev/null | wc -l | tr -d ' ') dump(s) retained (limit ${KEEP})"
fi

log "=== db backup run end (rc=0) ==="
exit 0
BODY
  } >"$tmp"

  as_root install -m "$mode" "$tmp" "$DB_BACKUP_RUNNER"
  rm -f "$tmp"
  success "Installed database backup script: ${DB_BACKUP_RUNNER} (mode ${mode})"
}

# -----------------------------------------------------------------------------
# _dbbackup_install_systemd_timer — daily oneshot .service + .timer.
# -----------------------------------------------------------------------------
_dbbackup_install_systemd_timer() {
  local svc="/etc/systemd/system/${DB_BACKUP_UNIT}.service"
  local tim="/etc/systemd/system/${DB_BACKUP_UNIT}.timer"

  printf '%s\n' \
    "# Written by the eRegister v1 installer — re-running it overwrites this file." \
    "[Unit]" \
    "Description=eRegister v1 — daily backup of the openmrs database" \
    "After=network-online.target docker.service" \
    "Wants=network-online.target" \
    "" \
    "[Service]" \
    "Type=oneshot" \
    "TimeoutStartSec=0" \
    "ExecStart=${DB_BACKUP_RUNNER}" \
    | as_root tee "$svc" >/dev/null
  as_root chmod 0644 "$svc"

  printf '%s\n' \
    "# Written by the eRegister v1 installer — re-running it overwrites this file." \
    "[Unit]" \
    "Description=eRegister v1 — daily schedule for the openmrs database backup" \
    "" \
    "[Timer]" \
    "OnCalendar=${DB_BACKUP_ONCALENDAR}" \
    "Persistent=true" \
    "RandomizedDelaySec=300" \
    "" \
    "[Install]" \
    "WantedBy=timers.target" \
    | as_root tee "$tim" >/dev/null
  as_root chmod 0644 "$tim"

  as_root systemctl daemon-reload
  as_root systemctl enable --now "${DB_BACKUP_UNIT}.timer"
  success "systemd timer enabled: ${DB_BACKUP_UNIT}.timer (OnCalendar=${DB_BACKUP_ONCALENDAR})"
  info "Status: systemctl status ${DB_BACKUP_UNIT}.timer   Run now: systemctl start ${DB_BACKUP_UNIT}.service"
}

# -----------------------------------------------------------------------------
# _dbbackup_install_cron_job — daily /etc/cron.d entry (no systemd on this host).
# -----------------------------------------------------------------------------
_dbbackup_install_cron_job() {
  local cronfile="/etc/cron.d/${DB_BACKUP_UNIT}"
  printf '%s\n' \
    "# Written by the eRegister v1 installer — remove this file to disable the daily database backup." \
    "SHELL=/bin/bash" \
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "${DB_BACKUP_CRON} root ${DB_BACKUP_RUNNER}" \
    | as_root tee "$cronfile" >/dev/null
  as_root chmod 0644 "$cronfile"
  success "Daily cron job installed: ${cronfile} (${DB_BACKUP_CRON})"
}

# -----------------------------------------------------------------------------
# _dbbackup_schedule — daily timer where systemd is available, else cron.d.
# -----------------------------------------------------------------------------
_dbbackup_schedule() {
  if has_systemd; then
    _dbbackup_install_systemd_timer
  elif [ -d /etc/cron.d ]; then
    warn "systemd not detected — falling back to a /etc/cron.d entry."
    _dbbackup_install_cron_job
  else
    warn "Neither systemd nor /etc/cron.d is available. The backup script was"
    warn "installed at ${DB_BACKUP_RUNNER} but NOT scheduled — add your own entry:"
    warn "  ${DB_BACKUP_CRON} root ${DB_BACKUP_RUNNER}"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# run_db_backup — one immediate run through the installed script, so the site
# holds a dump now rather than after the first nightly firing.
#
# Advisory. Straight after an upgrade the stack has only just been started, and
# while openmrsdb answers earlier than the EMR it may not answer YET — that is
# a "the timer will get it tonight", not a failure of the install.
# -----------------------------------------------------------------------------
run_db_backup() {
  info "Taking a database backup now (log: ${DB_BACKUP_LOG}) …"
  if as_root "$DB_BACKUP_RUNNER"; then
    success "Database backup written under ${DB_BACKUP_DIR}."
    as_root tail -n 6 "$DB_BACKUP_LOG" >&2 || true
    return 0
  fi
  warn "The backup did not complete (see ${DB_BACKUP_LOG})."
  as_root tail -n 10 "$DB_BACKUP_LOG" >&2 || true
  warn "Usually this is just ${DB_SERVICE} not accepting connections yet. The daily"
  warn "job (${DB_BACKUP_CRON}) will take the first dump, or run it by hand:"
  warn "  sudo ${DB_BACKUP_RUNNER}"
  return 1
}

# -----------------------------------------------------------------------------
# install_db_backup — top-level entry: install the script, schedule it daily,
# and take one dump straight away if the database is already answering.
# Called from install.sh's run_post_install and from catch-up.sh.
# -----------------------------------------------------------------------------
install_db_backup() {
  step "Scheduling the daily database backup"

  if [ "${DB_BACKUP:-1}" != "1" ]; then
    info "Daily database backup disabled (--no-db-backup / EREGISTER_DB_BACKUP=0); skipping."
    return 0
  fi

  info "The job runs daily (${DB_BACKUP_CRON}) and, in one run:"
  info "  • dumps '${DB_NAME}' from the ${DB_SERVICE} service (consistent snapshot,"
  info "    no locking — the site keeps working while it runs)"
  info "  • gzips it to ${DB_BACKUP_DIR}/${DB_NAME}_<stamp>.sql.gz"
  info "  • verifies the dump is complete before keeping it"
  info "  • deletes all but the newest ${DB_BACKUP_KEEP} dumps"
  info "It runs BEFORE the nightly repo pull, form import and concept import, so"
  info "each dump is of the database as it stood before any of them ran."
  warn "These dumps live on the SAME machine as the database. That covers a bad"
  warn "import or a deleted patient; it does NOT cover the disk or the server"
  warn "dying. Copy ${DB_BACKUP_DIR} off this host as well."

  confirm "Install the daily database backup?" \
    || { info "Skipped. Install it later by re-running the installer with --force, or ./catch-up.sh."; return 0; }

  # Not ensure_dir(): that lives in lib/upgrade/backup.sh, which catch-up.sh
  # does not source. The dumps are the whole patient database in plaintext, so
  # the folder is 0700 — off limits to other accounts on the box.
  if as_root mkdir -p "$DB_BACKUP_DIR"; then
    as_root chmod 0700 "$DB_BACKUP_DIR" 2>/dev/null || true
    success "database backup folder ready: ${DB_BACKUP_DIR}"
  else
    error "Could not create ${DB_BACKUP_DIR}."
    return 1
  fi

  _dbbackup_write_runner
  _dbbackup_schedule || return 1

  # One now, if the database is up. A fresh stack usually is not, and that is
  # explicitly fine — the message says so rather than reporting a failure.
  if [ "${DB_BACKUP_FIRST_RUN:-1}" = "1" ]; then
    run_db_backup || true
  else
    info "No immediate backup (EREGISTER_DB_BACKUP_FIRST_RUN=0); the daily job takes the first one."
  fi

  info "Run one by hand at any time:  sudo ${DB_BACKUP_RUNNER}   (log: ${DB_BACKUP_LOG})"
  info "Restore one with:"
  info "  gzip -dc ${DB_BACKUP_DIR}/latest.sql.gz | (cd ${RESTORE_DIR} && ${DOCKER_COMPOSE:-docker compose} exec -T ${DB_SERVICE} mysql -u${DB_USER} -p)"
}
