# shellcheck shell=bash
# =============================================================================
# lib/upgrade/postinstall.sh — post-install verification & "what to do next"
# Depends on: logging, as_root() (privilege).
# =============================================================================
# A failed post-install check. Normally fatal — it records the failure in the
# caller's 'ok' so post_verify returns non-zero. But when the backup was skipped
# (fresh install, no old EMR container) every check is advisory: warn and keep
# going so the upgrade still finalizes. Relies on being called from post_verify
# (bash dynamic scope) to see and flip its local 'ok'.
verify_fail() {
  if [ "${BACKUP_SKIPPED:-0}" = "1" ]; then
    warn "$1 (non-fatal: no backup was taken)"
  else
    error "$1"
    ok=0
  fi
}

post_verify() {
  step "Post-install verification"
  local ok=1
  [ -s "$BACKUP_SQL" ]                        || verify_fail "Missing DB backup."
  [ -d "${V1_DIR}/bahmni-docker-ls/.git" ]    || verify_fail "bahmni-docker-ls missing."
  [ -d "${V1_DIR}/standard-config-ls/.git" ]  || verify_fail "standard-config-ls missing."
  [ -d "${BACKUP_DIR}/bahmni_config/.git" ]   || verify_fail "bahmni_config missing."
  [ "$ok" = "1" ] || return 1
  as_root touch "$DONE_MARKER"
  persist_env
  success "Verification passed."
}

persist_env() {
  # Persist eRegister_HOME beyond this process so future shell sessions (and
  # scripts run from them) can find the v1 tree. profile.d only reaches login
  # shells — daemons/cron jobs still need the path passed explicitly.
  local profile="/etc/profile.d/eregister.sh"
  if [ ! -d /etc/profile.d ]; then
    warn "No /etc/profile.d on this system; eRegister_HOME not persisted."
    return 0
  fi
  printf '# Written by the eRegister v1 installer — re-running it overwrites this file.\nexport eRegister_HOME=%q\n' "$eRegister_HOME" \
    | as_root tee "$profile" >/dev/null
  as_root chmod 0644 "$profile"
  success "eRegister_HOME persisted to ${profile} (takes effect in new login shells)."
}

next_steps() {
  local backup_size dc
  # '|| true' so a missing/unreadable backup never aborts next_steps under set -e.
  backup_size="$(as_root du -h "$BACKUP_SQL" 2>/dev/null | awk '{print $1}' || true)"
  [ -n "$backup_size" ] && backup_size=" (${backup_size})"
  # DOCKER_COMPOSE is only resolved in ensure_deps, which the "already installed"
  # early-exit path skips — fall back to a sensible default so the printed
  # commands are never blank.
  dc="${DOCKER_COMPOSE:-docker compose}"
  cat >&2 <<EOF

${C_OK}══════════════════════════════════════════════════════════════${C_RESET}
${C_OK} ✔ ${APP_NAME} upgraded to ${TARGET_VERSION}${C_RESET}
${C_OK}══════════════════════════════════════════════════════════════${C_RESET}

  Install dir : ${V1_DIR}
  DB backup   : ${BACKUP_SQL}${backup_size}
  v1 stack    : ${V1_DIR}/bahmni-docker-ls
  Environment : eRegister_HOME=${eRegister_HOME} (persisted in /etc/profile.d/eregister.sh)

  The v1 stack has been started (run-bahmni.sh, or '${dc} up -d').

  What to do next:
    1. cd ${V1_DIR}/bahmni-docker-ls/bahmni-standard
    2. Confirm services are healthy:
         ${dc} ps
    3. If anything is down, bring it up with:
         ${dc} up -d
    4. After the instance is FULLY up and the OCL import has finished
       (~30+ min), apply the OCL concept-name fix (run once):
         curl -fsSL ${RAW_BASE}/ocl-fix.sh | bash
       (or, from the upgrade repo:  ./ocl-fix.sh)
    5. Once verified, the old install in ${OLD_DOCKER_DIR} can be archived.

  Concept dictionary:
    ${CONCEPTS_SQL}
    was imported into ${DB_SERVICE}:${DB_NAME} at the end of this run
    (pre-import copy of the replaced tables: ${CONCEPTS_PREIMPORT_SQL:-none taken}).
    Re-run it any time — e.g. after the auto-pull job picks up a newer
    dictionary — with:
         curl -fsSL ${RAW_BASE}/import-concepts.sh | bash
       (or, from the upgrade repo:  ./import-concepts.sh)

  Auto-updates:
    If you accepted the auto-update step, the asset/config repos
    (standard-config-ls, implementer-interface-release, openmrs-v1-modules,
    clinical-obs-forms, dhisconnector_mappings_v1,
    eregister_concepts_release_v1) are pulled on a schedule by ${AUTO_PULL_SCRIPT}
    (${C_DIM}systemd: ${AUTO_PULL_UNIT}.timer, or /etc/cron.d/${AUTO_PULL_UNIT}${C_RESET}).
    Run a sync now:  ${AUTO_PULL_SCRIPT}
    Log:             ${AUTO_PULL_LOG}

  Re-running this script is safe (idempotent). Use --force to redo a
  completed upgrade.

${C_ERR}  ⚠ Please wait ~30+ minutes before using eRegister. The v1 services
    need time to fully start up, and this can take considerably longer
    depending on the server hardware hosting eRegister.${C_RESET}
EOF
}
