# shellcheck shell=bash
# =============================================================================
# lib/upgrade/postinstall.sh — post-install verification, the completion marker
# and the "what to do next" summary.
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
  # The migration is done and verified — but the post-install steps (concept
  # import, form import, auto-updates) have NOT run yet, so record only that.
  # See mark_stage() for why the difference matters.
  mark_stage migrated
  persist_env
  success "Verification passed."
}

# -----------------------------------------------------------------------------
# The completion marker.
#
# It records HOW FAR a run got, not merely that one happened:
#
#   stage=migrated   the stack was migrated, verified and started, but the
#                    post-install steps (concept import, form import, the
#                    auto-update job) had not finished.
#   stage=complete   the whole run finished.
#
# That distinction is the whole point of the file. Those post-install steps run
# for a long time (the concept import alone waits on the DB and then loads a
# multi-hundred-MB dump) and are easy to interrupt with a Ctrl-C or a dropped
# ssh session. When the marker was a bare `touch` taken at verification time, an
# interrupt anywhere in that window left a marker behind that said "installed",
# and every later run of install.sh short-circuited on it: it printed a summary
# of work it had not done and exited without finishing the steps that were still
# outstanding. Recording the stage lets such a run be resumed instead.
# -----------------------------------------------------------------------------
mark_stage() {
  local stage="$1" tmp
  tmp="$(mktemp)"
  {
    printf '# eRegister v1 install marker — written by install.sh.\n'
    printf '# stage=migrated: stack migrated, verified and started; post-install\n'
    printf '#                 steps (concepts, forms, auto-update) still pending.\n'
    printf '# stage=complete: the whole install finished.\n'
    printf 'stage=%s\n'   "$stage"
    printf 'version=%s\n' "$TARGET_VERSION"
    printf 'at=%s\n'      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp"
  as_root install -m 0644 "$tmp" "$DONE_MARKER" \
    || warn "Could not write ${DONE_MARKER}; the next run will redo this one."
  rm -f "$tmp"
}

read_stage() {
  # Echoes: "" when there is no marker, the recorded stage when there is one,
  # and "legacy" for a marker left by an installer that only touched an empty
  # file (i.e. a site installed before the stage was recorded).
  local stage
  [ -f "$DONE_MARKER" ] || return 0
  stage="$(as_root sed -n 's/^stage=//p' "$DONE_MARKER" 2>/dev/null | tail -1)"
  printf '%s' "${stage:-legacy}"
}

resolve_install_stage() {
  # What this run should act on: "", "migrated" or "complete".
  #
  # A legacy marker carries no stage, so decide from what the post-install steps
  # leave behind on disk. A step that is switched off for this run cannot be
  # outstanding, so it counts as satisfied.
  local stage concepts_done=0 forms_done=0
  stage="$(read_stage)"
  if [ "$stage" != "legacy" ]; then printf '%s' "$stage"; return 0; fi

  if [ "${IMPORT_CONCEPTS:-1}" != "1" ] || [ -f "$CONCEPT_IMPORT_STATE" ]; then
    concepts_done=1
  fi
  if [ "${IMPORT_FORMS:-1}" != "1" ] || [ -f "$FORM_IMPORT_STATE" ] || [ -f "$FORM_IMPORT_RUNNER" ]; then
    forms_done=1
  fi

  if [ "$concepts_done" = "1" ] && [ "$forms_done" = "1" ]; then
    printf 'complete'
  else
    printf 'migrated'
  fi
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

# -----------------------------------------------------------------------------
# next_steps — the closing reference card.
#
# It is printed after three different kinds of run (SUMMARY_MODE), and it must
# describe THIS run honestly in each of them:
#   upgrade   the migration ran here — past tense is earned.
#   resume    only the post-install steps ran; the stack was started earlier.
#   existing  nothing was changed; this is a reference card, not a report.
# The helpers below supply the lines that differ.
# -----------------------------------------------------------------------------
_next_steps_headline() {
  case "${SUMMARY_MODE:-upgrade}" in
    resume)   printf '%s ✔ %s %s — post-install steps completed%s' \
                     "$C_OK" "$APP_NAME" "$TARGET_VERSION" "$C_RESET" ;;
    existing) printf '%s ℹ %s %s is already installed — nothing was changed%s' \
                     "$C_INFO" "$APP_NAME" "$TARGET_VERSION" "$C_RESET" ;;
    *)        printf '%s ✔ %s upgraded to %s%s' \
                     "$C_OK" "$APP_NAME" "$TARGET_VERSION" "$C_RESET" ;;
  esac
}

_next_steps_rule() {
  # The rule around the headline is green for a run that did something and
  # neutral for one that only reported — the ✔-in-green is exactly what makes
  # an "already installed" summary read as "we just did all of this".
  case "${SUMMARY_MODE:-upgrade}" in
    existing) printf '%s══════════════════════════════════════════════════════════════%s' "$C_INFO" "$C_RESET" ;;
    *)        printf '%s══════════════════════════════════════════════════════════════%s' "$C_OK" "$C_RESET" ;;
  esac
}

_next_steps_stack_line() {
  local dc="$1"
  if [ "${STACK_STARTED:-0}" = "1" ]; then
    printf "The v1 stack has been started (run-bahmni.sh, or '%s up -d')." "$dc"
  else
    printf "The v1 stack was started by an earlier run — this run did not touch it.\n  Check it with '%s ps' (step 2 below)." "$dc"
  fi
}

_next_steps_concepts_line() {
  # What actually happened to the dictionary, rather than what usually happens.
  local last at
  if [ "${CONCEPTS_IMPORTED:-0}" = "1" ]; then
    printf 'was imported into %s:%s during this run\n    (pre-import copy of the replaced tables: %s).' \
           "$DB_SERVICE" "$DB_NAME" "${CONCEPTS_PREIMPORT_SQL:-none taken}"
    return 0
  fi
  if command -v _concepts_state_get >/dev/null 2>&1 && [ -f "$CONCEPT_IMPORT_STATE" ]; then
    last="$(_concepts_state_get file)"
    at="$(_concepts_state_get imported_at)"
    if [ -n "$last" ]; then
      printf 'was NOT imported by this run. Last imported: %s (%s).' "$last" "${at:-time unknown}"
      return 0
    fi
  fi
  printf 'has NOT been imported yet — run ./import-concepts.sh, or leave it to the daily job.'
}

_next_steps_forms_line() {
  # Don't describe a schedule that was never installed. The runner is what the
  # timer/cron entry calls, so its absence means nothing is importing forms.
  if [ -f "$FORM_IMPORT_RUNNER" ]; then
    printf "is imported into %s as '%s' by\n    %s\n    (%ssystemd: %s.timer, or /etc/cron.d/%s%s), daily at %s." \
           "$BAHMNI_URL" "$BAHMNI_USER" "$FORM_IMPORT_RUNNER" \
           "$C_DIM" "$FORM_IMPORT_UNIT" "$FORM_IMPORT_UNIT" "$C_RESET" "$FORM_IMPORT_CRON"
  else
    printf "is NOT being imported on a schedule: %s is not installed\n    on this host. Install it with ./import-forms.sh — it would then import\n    into %s as '%s', daily at %s." \
           "$FORM_IMPORT_RUNNER" "$BAHMNI_URL" "$BAHMNI_USER" "$FORM_IMPORT_CRON"
  fi
}

_next_steps_autopull_line() {
  if [ -f "$AUTO_PULL_SCRIPT" ]; then
    printf 'are pulled on a schedule by %s\n    (%ssystemd: %s.timer, or /etc/cron.d/%s%s).\n    Run a sync now:  %s\n    Log:             %s' \
           "$AUTO_PULL_SCRIPT" "$C_DIM" "$AUTO_PULL_UNIT" "$AUTO_PULL_UNIT" "$C_RESET" \
           "$AUTO_PULL_SCRIPT" "$AUTO_PULL_LOG"
  else
    printf 'are NOT pulled automatically: %s is not installed on\n    this host (the auto-update step was declined, or did not run). Install it\n    by re-running the installer with --force.' \
           "$AUTO_PULL_SCRIPT"
  fi
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

$(_next_steps_rule)
$(_next_steps_headline)
$(_next_steps_rule)

  Install dir : ${V1_DIR}
  DB backup   : ${BACKUP_SQL}${backup_size}
  v1 stack    : ${V1_DIR}/bahmni-docker-ls
  Environment : eRegister_HOME=${eRegister_HOME} (persisted in /etc/profile.d/eregister.sh)

  $(_next_steps_stack_line "$dc")

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
    ${CONCEPTS_SQL:-newest ${CONCEPTS_SQL_PATTERN} in ${CONCEPTS_DIR}}
    $(_next_steps_concepts_line)
    From here on it keeps itself current: ${CONCEPT_IMPORT_UNIT} runs daily
    (${CONCEPT_IMPORT_CRON}) via ${CONCEPT_IMPORT_RUNNER}, pulls the concepts
    repo and imports a dump ONLY when its content has changed.
    Check now:   sudo ${CONCEPT_IMPORT_RUNNER}
    Log:         ${CONCEPT_IMPORT_LOG}
    Import by hand at any time:
         curl -fsSL ${RAW_BASE}/import-concepts.sh | bash
       (or, from the upgrade repo:  ./import-concepts.sh)
    NOTE: OpenMRS caches concepts — the EMR must restart before a newly
    imported dictionary is visible. The job logs this; it does not restart it.

  Clinical observation forms:
    ${FORMS_DIR}
    $(_next_steps_forms_line)
    Only forms whose content changed are deployed, and a changed form goes out
    as a NEW version — the live one is never overwritten.
    Import now:  sudo ${FORM_IMPORT_RUNNER}
    Log:         ${FORM_IMPORT_LOG}
    State:       ${FORM_IMPORT_STATE}
    Credentials: ${FORM_IMPORT_ENV} (mode 0600)
    Re-install / re-schedule:
         curl -fsSL ${RAW_BASE}/import-forms.sh | bash
       (or, from the upgrade repo:  ./import-forms.sh)

  Auto-updates:
    The asset/config repos
    (standard-config-ls, implementer-interface-release, openmrs-v1-modules,
    clinical-obs-forms, dhisconnector_mappings_v1,
    eregister_concepts_release_v1) $(_next_steps_autopull_line)

  Re-running this script is safe (idempotent). Use --force to redo a
  completed upgrade. To pick up later changes to these scripts without a full
  re-run, use the catch-up script instead — it reconciles the repos, helpers and
  scheduled jobs in place, reports on service health, and reloads the EMR
  service at the end (--no-recreate to leave even that alone):
       curl -fsSL ${RAW_BASE}/catch-up.sh | bash
     (or, from the upgrade repo:  ./catch-up.sh)

${C_ERR}  ⚠ Please wait ~30+ minutes before using eRegister. The v1 services
    need time to fully start up, and this can take considerably longer
    depending on the server hardware hosting eRegister.${C_RESET}
EOF
}
