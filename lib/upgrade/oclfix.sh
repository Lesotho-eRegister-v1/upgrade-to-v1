# shellcheck shell=bash
# =============================================================================
# lib/upgrade/oclfix.sh — post-startup OCL concept-name fix.
#
# Run ONCE, AFTER the v1 instance has fully started and finished its OCL import
# (~30+ min after start). During that import OCL voids the local concept names
# (reason "Removed from OCL") and inserts its own replacements. This:
#   1. Unvoids the original names and voids OCL's replacements in the 'openmrs'
#      db (openmrsdb service).
#   2. Renames CIEL_*.zip -> .DONE in the OCL dir of the EMR (openmrs) service
#      so the import does not run again on the next startup.
# Naturally idempotent: a second run finds nothing to unvoid and no zip to move.
# Depends on: logging, prompt (confirm), as_root() (privilege).
# Uses config: RESTORE_DIR, DOCKER_COMPOSE, DB_SERVICE, EMR_SERVICE, DB_NAME,
#              DB_USER, DB_PASS, OCL_DIR.
# =============================================================================

_ocl_resolve_compose() {
  # Populate DOCKER_COMPOSE if the caller (standalone script) hasn't already.
  [ -n "${DOCKER_COMPOSE:-}" ] && return 0
  if docker compose version >/dev/null 2>&1; then DOCKER_COMPOSE="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then DOCKER_COMPOSE="docker-compose"
  else error "docker compose not available."; return 1; fi
}

_ocl_service_up() {
  # _ocl_service_up <service>  -> 0 if the compose service reports up/running.
  local svc="$1" out
  out="$( cd "$RESTORE_DIR" && v1_compose ps "$svc" 2>/dev/null )" || return 1
  printf '%s' "$out" | grep -Eqi 'up|running'
}

_ocl_run_sql() {
  # Feed the concept-name SQL into mysql inside the openmrsdb service. The
  # password is taken from EREGISTER_DB_PASS if set, else the container's own
  # MYSQL_ROOT_PASSWORD (never placed on a host process list). One session, so
  # the TEMPORARY table survives across the statements.
  ( cd "$RESTORE_DIR" && v1_compose exec -T "$DB_SERVICE" \
      sh -c 'pw="${3:-$MYSQL_ROOT_PASSWORD}"; exec mysql -u"$1" ${pw:+-p"$pw"} "$2"' \
         _ "$DB_USER" "$DB_NAME" "$DB_PASS" ) <<'SQL'
-- Unvoid original concept names and void OCL's replacements.

-- Step 1: concepts whose names were voided with reason "Removed from OCL"
-- (OCL inserted replacement names at the same time).
CREATE TEMPORARY TABLE replaced_concepts AS
SELECT DISTINCT concept_id
FROM concept_name
WHERE void_reason = 'Removed from OCL'
  AND voided = 1;

-- Step 2: unvoid the original names.
UPDATE concept_name
SET voided = 0, voided_by = NULL, date_voided = NULL, void_reason = NULL
WHERE concept_id IN (SELECT concept_id FROM replaced_concepts)
  AND void_reason = 'Removed from OCL';

-- Step 3: void OCL's replacement names.
UPDATE concept_name
SET voided = 1, voided_by = 1, date_voided = NOW(), void_reason = 'Replaced by original'
WHERE concept_id IN (SELECT concept_id FROM replaced_concepts)
  AND voided = 0
  AND creator = 2
  AND date_created >= '2026-06-16';

DROP TEMPORARY TABLE replaced_concepts;
SQL
}

_ocl_rename_zips() {
  # Rename every CIEL_*.zip (not already .DONE) in the OCL dir of the EMR
  # service, so the OCL import is skipped on the next startup.
  ( cd "$RESTORE_DIR" && v1_compose exec -T "$EMR_SERVICE" \
      sh -c '
        dir="$1"
        cd "$dir" 2>/dev/null || { echo "OCL dir not found: $dir" >&2; exit 0; }
        n=0
        for f in CIEL_*.zip; do
          [ -e "$f" ] || continue
          if mv "$f" "$f.DONE"; then echo "renamed: $f -> $f.DONE"; n=$((n+1)); fi
        done
        [ "$n" -gt 0 ] || echo "no CIEL_*.zip to rename (already done)"
      ' _ "$OCL_DIR" )
}

ocl_fix() {
  step "OCL concept-name fix"
  _ocl_resolve_compose || return 1
  [ -d "$RESTORE_DIR" ] || { error "v1 stack dir not found: ${RESTORE_DIR}. Has the upgrade run?"; return 1; }
  if ! _ocl_service_up "$DB_SERVICE"; then
    error "Service '${DB_SERVICE}' is not up at ${RESTORE_DIR}."
    error "Start the v1 stack and wait for the OCL import to finish (~30+ min) before running this."
    return 1
  fi

  warn "This corrects concept names in the '${DB_NAME}' database and stops the OCL"
  warn "re-import. Run it ONLY after the instance is fully up and OCL import is done."
  confirm "Proceed with the OCL fix now?" || { warn "OCL fix skipped by user."; return 0; }

  info "Applying concept-name SQL to ${DB_SERVICE}:${DB_NAME}…"
  _ocl_run_sql || { error "SQL step failed."; return 1; }
  success "Concept names corrected (originals unvoided, OCL replacements voided)."

  info "Renaming imported OCL zip(s) in ${EMR_SERVICE}:${OCL_DIR} to prevent re-import…"
  _ocl_rename_zips || warn "Could not rename OCL zip(s); check ${OCL_DIR} in the ${EMR_SERVICE} service manually."
  success "OCL fix complete."
}
