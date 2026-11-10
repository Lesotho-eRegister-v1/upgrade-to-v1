#!/usr/bin/env bash
###############################################################################
# eRegister Lesotho — Clinical patient-queue fix
#
# Restores the custom emrapi.sqlSearch.queue.* global properties used by the
# clinical queue tabs (Active, My Patients, OPD-1, PatientsByLocation). Without
# them the tabs stay on "(...)" and OpenMRS logs
#   "No such query:emrapi.sqlSearch.queue.activePatients".
# They are lost when the openmrs DB is restored from a dump that lacks them.
#
# Runs from any directory (e.g. ~). Backs up the emrapi.sqlSearch.* rows first.
# Safe to re-run (idempotent).
#
# USAGE
#   ~/bahmniDev/upgrade-to-v1/queue-fix.sh            # check, back up, apply, verify
#   ~/bahmniDev/upgrade-to-v1/queue-fix.sh --check    # only report what is missing
#   ~/bahmniDev/upgrade-to-v1/queue-fix.sh --rollback # delete the queue rows again
#   ~/bahmniDev/upgrade-to-v1/queue-fix.sh --fix-gp   # reload gp_clinical.xml via Initializer
#        (labResultNotifications = Notifications tab, emergencyMedicationToAcknowledge).
#        Deletes Initializer's stale gp_clinical.checksum and RESTARTS OpenMRS (downtime).
#   add --yes to skip the confirmation prompt
#
# ENV
#   EREGISTER_DB_SERVICE  db compose service (default openmrsdb)
#   EREGISTER_DB_NAME     database           (default openmrs)
#   EREGISTER_DB_PASS     mysql root password (else the container's MYSQL_ROOT_PASSWORD)
#   EREGISTER_EMR_SERVICE openmrs compose service (default openmrs)
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_SQL="$SCRIPT_DIR/fix_queue_sqlsearch.sql"
ROLLBACK_SQL="$SCRIPT_DIR/rollback_queue_sqlsearch.sql"
BACKUP_DIR="$SCRIPT_DIR/backups"
DB_SERVICE="${EREGISTER_DB_SERVICE:-openmrsdb}"
DB_NAME="${EREGISTER_DB_NAME:-openmrs}"
EXPECTED=3
EMR_SERVICE="${EREGISTER_EMR_SERVICE:-openmrs}"
GP_CHECKSUM=/openmrs/data/configuration_checksums/globalproperties/gp_clinical.checksum
GP_PROPS="'emrapi.sqlSearch.labResultNotifications','emrapi.sqlSearch.emergencyMedicationToAcknowledge'"
GP_EXPECTED=2
GP_WAIT_SECS=900

MODE=apply; ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --rollback) MODE=rollback ;;
    --fix-gp) MODE=fixgp ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ -f "$FIX_SQL" ]] || die "missing $FIX_SQL"
[[ -f "$ROLLBACK_SQL" ]] || die "missing $ROLLBACK_SQL"
command -v docker >/dev/null || die "docker not found"

DB_CONTAINER="$(docker ps --filter "label=com.docker.compose.service=$DB_SERVICE" --format '{{.Names}}' | head -1)"
[[ -n "$DB_CONTAINER" ]] || die "no running container for compose service '$DB_SERVICE'"
EMR_CONTAINER="$(docker ps --filter "label=com.docker.compose.service=$EMR_SERVICE" --format '{{.Names}}' | head -1)"

# Password stays inside the container (env var), never on this host's command line.
mysql_in() {  # mysql_in [extra mysql args...]  (reads SQL on stdin)
  docker exec -i -e EREG_PW="${EREGISTER_DB_PASS:-}" "$DB_CONTAINER" \
    sh -c 'MYSQL_PWD="${EREG_PW:-$MYSQL_ROOT_PASSWORD}" exec mysql -uroot "$@"' _ "$@" "$DB_NAME"
}

queue_count() {
  echo "SELECT COUNT(*) FROM global_property WHERE property IN ('emrapi.sqlSearch.queue.activePatients','emrapi.sqlSearch.queue.activePatientsByProvider','emrapi.sqlSearch.queue.activePatientsByLocation');" \
    | mysql_in -N
}

gp_count() {
  echo "SELECT COUNT(*) FROM global_property WHERE property IN ($GP_PROPS);" | mysql_in -N
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

backup() {
  mkdir -p "$BACKUP_DIR"
  local f="$BACKUP_DIR/sqlsearch_$(date +%Y%m%d_%H%M%S).sql"
  docker exec -e EREG_PW="${EREGISTER_DB_PASS:-}" "$DB_CONTAINER" \
    sh -c 'MYSQL_PWD="${EREG_PW:-$MYSQL_ROOT_PASSWORD}" mysqldump -uroot --no-create-info --replace --skip-extended-insert "$1" global_property --where="property LIKE '"'"'emrapi.sqlSearch%'"'"'"' _ "$DB_NAME" > "$f"
  local n; n=$(grep -c '^REPLACE INTO' "$f" || true)
  [[ "$n" -gt 0 ]] || die "backup $f is empty; not continuing"
  info "Backed up $n emrapi.sqlSearch rows to $f"
}

info "DB container: $DB_CONTAINER (database: $DB_NAME)"
have=$(queue_count)
info "Queue search handlers present: $have/$EXPECTED"
gp_have=$(gp_count)
info "gp_clinical.xml handlers present (Notifications etc.): $gp_have/$GP_EXPECTED"

case "$MODE" in
  check)
    [[ "$have" -eq $EXPECTED ]] && info "Queue handlers OK." || info "Queue handlers missing: run without options to fix."
    [[ "$gp_have" -eq $GP_EXPECTED ]] && info "gp_clinical handlers OK." || info "gp_clinical handlers missing: run with --fix-gp (restarts OpenMRS)."
    ;;
  rollback)
    confirm "Delete the emrapi.sqlSearch.queue.* rows from $DB_NAME?"
    backup
    mysql_in < "$ROLLBACK_SQL"
    info "Rolled back. To restore the earlier rows exactly, run:"
    echo "  docker exec -i $DB_CONTAINER sh -c 'mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" $DB_NAME' < $BACKUP_DIR/<backup file>.sql"
    ;;
  apply)
    confirm "Back up and (re)write the $EXPECTED emrapi.sqlSearch.queue.* rows in $DB_NAME?"
    backup
    mysql_in < "$FIX_SQL"
    have=$(queue_count)
    [[ "$have" -eq $EXPECTED ]] || die "only $have/$EXPECTED handlers present after apply"
    info "Applied: $have/$EXPECTED queue search handlers present."
    echo
    echo "Next: hard-reload https://<server>/bahmni/clinical/index.html (Ctrl+Shift+R);"
    echo "each queue tab should show a count. Then check the log (expect 0):"
    echo "  docker logs --since 5m ${EMR_CONTAINER:-<openmrs container>} 2>&1 | grep -c 'No such query:emrapi.sqlSearch.queue'"
    echo "If it is not 0 after a reload, restart OpenMRS once: docker restart ${EMR_CONTAINER:-<openmrs container>}"
    ;;
  fixgp)
    [[ -n "$EMR_CONTAINER" ]] || die "no running container for compose service '$EMR_SERVICE'"
    if [[ "$gp_have" -eq $GP_EXPECTED ]]; then info "Already present, nothing to do."; exit 0; fi
    confirm "Delete $GP_CHECKSUM in $EMR_CONTAINER and RESTART OpenMRS (a few minutes downtime)?"
    backup
    if docker exec "$EMR_CONTAINER" test -f "$GP_CHECKSUM"; then
      cb="$BACKUP_DIR/gp_clinical.checksum.$(date +%Y%m%d_%H%M%S)"
      docker cp "$EMR_CONTAINER:$GP_CHECKSUM" "$cb" >/dev/null
      info "Saved checksum to $cb"
      docker exec "$EMR_CONTAINER" rm -f "$GP_CHECKSUM"
    else
      info "No checksum file found; restarting anyway so Initializer re-reads gp_clinical.xml."
    fi
    info "Restarting $EMR_CONTAINER ..."
    docker restart "$EMR_CONTAINER" >/dev/null
    info "Waiting up to $((GP_WAIT_SECS/60)) min for Initializer to load gp_clinical.xml ..."
    for ((t=0; t<GP_WAIT_SECS; t+=15)); do
      sleep 15
      gp_have=$(gp_count 2>/dev/null || echo 0)
      [[ "$gp_have" -eq $GP_EXPECTED ]] && break
    done
    [[ "$gp_have" -eq $GP_EXPECTED ]] || die "after $((GP_WAIT_SECS/60)) min only $gp_have/$GP_EXPECTED present; check: docker logs $EMR_CONTAINER | grep -i initializer"
    info "Loaded: $gp_have/$GP_EXPECTED gp_clinical handlers present. Wait for OpenMRS to finish starting, then reload the clinical page."
    ;;
esac
