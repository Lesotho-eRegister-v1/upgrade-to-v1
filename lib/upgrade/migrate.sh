# shellcheck shell=bash
# =============================================================================
# lib/upgrade/migrate.sh — the orchestrated migration steps: freeze old stack,
# fetch v1 sources, run the restore.
# Depends on: logging, as_root() (privilege), git_clone_or_update() (verify).
# =============================================================================
shutdown_old_stack() {
  log ""
  info "Shutting down ${APP_NAME} ${CURRENT_VERSION_DEFAULT}"
  if [ -f "${OLD_DOCKER_DIR}/docker-compose.yml" ]; then
    # 'stop' (not 'down') freezes the containers in place — they are halted but
    # NOT removed, so volumes/networks stay intact and rollback is a fast
    # 'start' with no re-create. Then continue straight on with the upgrade.
    ( cd "$OLD_DOCKER_DIR" && as_root $DOCKER_COMPOSE stop )
    OLD_STACK_STOPPED="1"
    success "Old stack stopped (containers frozen, not removed)."
  else
    warn "No docker-compose.yml at ${OLD_DOCKER_DIR}; nothing to shut down."
  fi
}

fetch_repos() {
  step "Fetching v1 sources"
  git_clone_or_update "$REPO_BAHMNI_DOCKER"   "${V1_DIR}/bahmni-docker-ls"    "$REF_BAHMNI_DOCKER"
  git_clone_or_update "$REPO_STANDARD_CONFIG" "${V1_DIR}/standard-config-ls"  "$REF_STANDARD_CONFIG"
  # v1 assets (omods, implementer interface, obs forms) live beside the stack.
  notice "The openmrs-v1-modules repo is ~246 MB, so this step will pause here for a while on a slow connection. This is expected — let it run."
  git_clone_or_update "$REPO_OPENMRS_MODULES" "${V1_DIR}/openmrs-v1-modules"  "$REF_OPENMRS_MODULES"
  git_clone_or_update "$REPO_IMPL_INTERFACE"  "${V1_DIR}/implementer-interface-release" "$REF_IMPL_INTERFACE"
  git_clone_or_update "$REPO_OBS_FORMS"       "${V1_DIR}/clinical-obs-forms"  "$REF_OBS_FORMS"
  git_clone_or_update "$REPO_DHIS_MAPPINGS"   "${V1_DIR}/dhisconnector_mappings_v1" "$REF_DHIS_MAPPINGS"
  git_clone_or_update "$REPO_CONCEPTS"        "${V1_DIR}/eregister_concepts_release_v1" "$REF_CONCEPTS"
  # Report definitions (the serialized_object dump). Cloned only — catch-up.sh
  # imports it, because the database it would go into is minutes old here.
  git_clone_or_update "$REPO_REPORTING"       "${V1_DIR}/openmrs_reporting_release" "$REF_REPORTING"
  # 0.92 config goes alongside the backup and is renamed to bahmni_config.
  git_clone_or_update "$REPO_CONFIG_092"      "${BACKUP_DIR}/bahmni_config"   "$REF_CONFIG_092"
}

run_restore() {
  step "Restoring data into v1"
  local restore_script="${RESTORE_DIR}/restore_bahmni_standard.sh"

  # No backup was taken (no old EMR container — a fresh install). There is
  # nothing to migrate, so we still ATTEMPT the restore (an existing dump, if
  # any, is honored) but never abort: missing artifacts or a restore error only
  # warn and continue. The normal path below stays strict.
  if [ "$BACKUP_SKIPPED" = "1" ]; then
    if [ ! -d "$RESTORE_DIR" ] || [ ! -f "$restore_script" ]; then
      warn "No restore artifacts under ${RESTORE_DIR}; skipping restore (no backup was taken)."
      return 0
    fi
    as_root chmod +x "$restore_script" || true
    info "Attempting restore (no backup was taken; any failure is non-fatal)…"
    if ( cd "$RESTORE_DIR" && as_root ./restore_bahmni_standard.sh "$BACKUP_DIR" ); then
      success "Restore completed."
    else
      warn "Restore did not complete; continuing anyway (no backup was taken to restore)."
    fi
    return 0
  fi

  [ -d "$RESTORE_DIR" ] || { error "Missing ${RESTORE_DIR}."; return 1; }
  [ -f "$restore_script" ] || { error "Restore script not found: ${restore_script}"; return 1; }
  as_root chmod +x "$restore_script" || true
  info "Running restore (this can take a while)…"
  ( cd "$RESTORE_DIR" && as_root ./restore_bahmni_standard.sh "$BACKUP_DIR" )
  success "Restore completed."
}

start_v1_stack() {
  # Bring up eRegister v1: prefer run-bahmni.sh; if it errors (or is missing),
  # fall back to a plain 'docker compose up -d'. The run-bahmni.sh call is in an
  # 'if' so a non-zero exit triggers the fallback instead of the ERR trap.
  step "Starting eRegister ${TARGET_VERSION}"
  local run_script="${RESTORE_DIR}/run-bahmni.sh" started=0
  if [ -f "$run_script" ]; then
    as_root chmod +x "$run_script" || true
    info "Launching via run-bahmni.sh…"
    if ( cd "$RESTORE_DIR" && as_root ./run-bahmni.sh ); then
      success "eRegister ${TARGET_VERSION} started via run-bahmni.sh."
      started=1
    else
      warn "run-bahmni.sh returned an error — falling back to '${DOCKER_COMPOSE} up -d'."
    fi
  else
    warn "run-bahmni.sh not found in ${RESTORE_DIR}; using '${DOCKER_COMPOSE} up -d'."
  fi
  if [ "$started" != "1" ]; then
    ( cd "$RESTORE_DIR" && as_root $DOCKER_COMPOSE up -d )
    success "eRegister ${TARGET_VERSION} started via docker compose."
  fi
  # Read by next_steps: only a run that started the stack may say so.
  STACK_STARTED="1"
  # The reports service is separate (and often profile-gated); start it too so
  # dashboards/reports are available. Runs regardless of which path launched the
  # main stack above.
  start_reports_service
}

start_reports_service() {
  # Naming the service explicitly on the CLI enables it even when it's gated
  # behind a compose 'reports' profile. Non-fatal: a failure only warns.
  info "Starting the reports service (${REPORTS_SERVICE})…"
  if ( cd "$RESTORE_DIR" && as_root $DOCKER_COMPOSE up -d "$REPORTS_SERVICE" ); then
    success "Reports service '${REPORTS_SERVICE}' started."
  else
    warn "Could not start reports service '${REPORTS_SERVICE}'; start it manually with '${DOCKER_COMPOSE} up -d ${REPORTS_SERVICE}'."
  fi
}
