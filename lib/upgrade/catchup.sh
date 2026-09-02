# shellcheck shell=bash
# =============================================================================
# lib/upgrade/catchup.sh — reconcile a deployed site with what install.sh is
# currently meant to have set up, and redo only the parts that are missing or
# out of date.
#
# WHY THIS EXISTS
#   The installer keeps gaining steps (asset repos, the concept dictionary, the
#   auto-pull job, the daily clinical form import). Sites installed from an
#   earlier version never got those steps, and re-running install.sh on them is
#   the wrong tool: it freezes the old stack, restores a backup and restarts
#   everything. This module does the opposite — it is a read-mostly reconcile
#   that fixes gaps in place.
#
# WHAT IT MAY TOUCH
#   Every check is read-only (`docker compose ps`), every git update is a
#   fast-forward, and a repo with local changes is never reset. Exactly ONE step
#   acts on a running container, and it is the last one: catchup_recreate_emr
#   recreates the EMR service (--force-recreate --renew-anon-volumes) so the
#   refreshed config, omods and forms are actually loaded. That costs the EMR's
#   30+ minute boot, so it is confirmed and can be skipped with --no-recreate.
#   Changes to the stack repo itself still only ever get REPORTED — bringing the
#   whole compose project up is left for the site's maintenance window.
#
# WHAT IT CHECKS / FIXES
#   1. the repos install.sh clones          -> clone if missing, fast-forward if behind
#   2. the generated helper scripts         -> rewritten from the current modules
#   3. the scheduled jobs (auto-pull, forms, concept dictionary, database
#      backup)                              -> installed if absent
#   4. the clinical form import             -> run (only changed forms deploy)
#   5. the concept dictionary               -> reported, never auto-imported.
#      It drops and recreates the concept_*/drug* tables, which is too blunt to
#      do behind an operator's back — and it no longer needs doing here: the
#      daily concept job loads a changed dictionary on its own. What this
#      reports is whether the dump on disk is the one in the database, and
#      whether anything is scheduled to close that gap.
#   5b. the report definitions              -> IMPORTED, the one import this
#      script performs itself. The openmrs_reporting_release dump replaces a
#      single table (serialized_object, the report library) — a small enough
#      blast radius to do here, with a pre-import backup first — and it is
#      skipped outright when its content is already the one in the database.
#      Nothing else is scheduled to load it, so reporting a gap here would leave
#      that gap open forever.
#   6. the nightly database dumps           -> reported: how many, and how old
#      the newest is. A backup job that has been failing for a fortnight looks
#      exactly like one that is working until someone counts the files.
#   7. running services + endpoints         -> reported (as found, pre-reload)
#   8. the EMR service                      -> recreated last, so all of the
#      above is actually loaded (skippable)
#
# The updating of THIS repo happens before the module is even sourced — see
# catch-up.sh, which pulls the checkout and re-execs itself from it.
#
# Depends on: logging, prompt (confirm), as_root() (privilege),
#             git_clone_or_update() (verify), has_systemd() + auto-pull
#             installers (autopull), the form installers (forms), the database
#             backup installers (dbbackup), import_reporting() (reporting).
# =============================================================================

# Report rows, collected as "STATUS|CATEGORY|NAME|DETAIL" and rendered at the
# end by catchup_report. STATUS is one of:
#   OK    already in place and current
#   FIXED this run created or updated it
#   SKIP  deliberately left alone (local changes, disabled by a flag)
#   GAP   still missing or unhealthy — needs a human
CATCHUP_ROWS=()
CATCHUP_GAPS=0
CATCHUP_EMR_RECREATED=0   # set by catchup_recreate_emr, read by the report

_cu_row() {  # _cu_row <status> <category> <name> <detail>
  CATCHUP_ROWS+=("$1|$2|$3|$4")
  [ "$1" = "GAP" ] && CATCHUP_GAPS=$(( CATCHUP_GAPS + 1 ))
  return 0
}

# -----------------------------------------------------------------------------
# catchup_expected_repos — every repo install.sh clones, as
# "name|url|dir|ref|class" lines. class is:
#   asset  content that keeps changing after deployment (always updated)
#   stack  bahmni-docker-ls — compose files a running stack reads; updating it
#          is gated on CATCHUP_STACK_REPO because the new files only take
#          effect on the site's next `docker compose up -d`
#   pinned the 0.92 config kept beside the backup — historical, restore-only,
#          so it is checked for presence but never fast-forwarded
#   self   this repo's checkout on the site. Phase 1 (catch-up.sh) already
#          updated whichever checkout the running script came from; this row
#          exists so the SITE's managed checkout is kept current too, even when
#          the run was started from a developer clone somewhere else.
# -----------------------------------------------------------------------------
catchup_expected_repos() {
  printf '%s\n' \
    "upgrade-to-v1|${REPO_UPGRADE}|${UPGRADE_REPO_DIR}|${REF_UPGRADE}|self" \
    "bahmni-docker-ls|${REPO_BAHMNI_DOCKER}|${V1_DIR}/bahmni-docker-ls|${REF_BAHMNI_DOCKER}|stack" \
    "standard-config-ls|${REPO_STANDARD_CONFIG}|${V1_DIR}/standard-config-ls|${REF_STANDARD_CONFIG}|asset" \
    "openmrs-v1-modules|${REPO_OPENMRS_MODULES}|${V1_DIR}/openmrs-v1-modules|${REF_OPENMRS_MODULES}|asset" \
    "implementer-interface-release|${REPO_IMPL_INTERFACE}|${V1_DIR}/implementer-interface-release|${REF_IMPL_INTERFACE}|asset" \
    "clinical-obs-forms|${REPO_OBS_FORMS}|${V1_DIR}/clinical-obs-forms|${REF_OBS_FORMS}|asset" \
    "dhisconnector_mappings_v1|${REPO_DHIS_MAPPINGS}|${V1_DIR}/dhisconnector_mappings_v1|${REF_DHIS_MAPPINGS}|asset" \
    "eregister_concepts_release_v1|${REPO_CONCEPTS}|${V1_DIR}/eregister_concepts_release_v1|${REF_CONCEPTS}|asset" \
    "openmrs_reporting_release|${REPO_REPORTING}|${V1_DIR}/openmrs_reporting_release|${REF_REPORTING}|asset" \
    "bahmni_config (0.92)|${REPO_CONFIG_092}|${BACKUP_DIR}/bahmni_config|${REF_CONFIG_092}|pinned"
}

# -----------------------------------------------------------------------------
# _cu_update_repo — bring one clone up to date, or make it in the first place.
#
# Same contract as the auto-pull job, deliberately: a repo with uncommitted
# local changes is REPORTED and left completely alone. Sites do hand-edit
# config, and silently discarding that would be the one destructive thing this
# script could plausibly do.
# -----------------------------------------------------------------------------
_cu_update_repo() { # _cu_update_repo <name> <url> <dir> <ref> <class>
  local name="$1" url="$2" dir="$3" ref="$4" class="$5" branch before after origin note=""

  # Phase 1 already pulled the checkout the running script came from. Only skip
  # this row when that checkout IS this directory — otherwise the site's own
  # copy still needs updating, which is the whole point of listing it here.
  if [ "$class" = "self" ] && [ "${EREGISTER_CATCHUP_SELF_DIR:-}" = "$dir" ]; then
    return 0
  fi

  if [ -d "$dir" ] && [ ! -d "${dir}/.git" ]; then
    _cu_row GAP repo "$name" "${dir} exists but is not a git checkout — move it aside and re-run"
    return 0
  fi

  if [ ! -d "${dir}/.git" ]; then
    info "Missing clone: ${name} -> ${dir}"
    if git_clone_or_update "$url" "$dir" "$ref"; then
      _cu_row FIXED repo "$name" "cloned @ $(git_here -C "$dir" rev-parse --short HEAD 2>/dev/null)"
    else
      _cu_row GAP repo "$name" "clone FAILED from ${url}"
    fi
    return 0
  fi

  if [ "$class" = "pinned" ]; then
    _cu_row OK repo "$name" "present (pinned to the deployed release; not updated)"
    return 0
  fi
  if [ "$class" = "stack" ] && [ "$CATCHUP_STACK_REPO" != "1" ]; then
    _cu_row SKIP repo "$name" "left at $(git_here -C "$dir" rev-parse --short HEAD 2>/dev/null) (--no-stack)"
    return 0
  fi

  # A clone may point at a different remote than this release configures — a
  # fork, or an older URL. Note it now, but do NOT re-point it yet: if the repo
  # turns out to be off-release below, re-pointing without also moving the ref
  # would leave it tracking a branch its new origin may not even have.
  origin="$(git_here -C "$dir" remote get-url origin 2>/dev/null || echo '')"
  if [ -n "$origin" ] && [ "$origin" != "$url" ]; then
    note=" [origin is ${origin}, release expects ${url}]"
  fi

  branch="$(git_here -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"

  # Dirty tree, detached HEAD, or a branch other than the one this release pins:
  # all three mean a plain fast-forward is either unsafe or would leave the repo
  # off-release. --force-repos resolves them the way the installer would.
  if [ -n "$(git_here -C "$dir" status --porcelain 2>/dev/null)" ] \
     || [ "$branch" = "HEAD" ] || { [ -n "$ref" ] && [ "$branch" != "$ref" ]; }; then
    local why
    if [ -n "$(git_here -C "$dir" status --porcelain 2>/dev/null)" ]; then
      why="uncommitted local changes"
    elif [ "$branch" = "HEAD" ]; then
      why="detached HEAD"
    else
      why="on branch '${branch}', release pins '${ref}'"
    fi
    if [ "$CATCHUP_FORCE_REPOS" = "1" ]; then
      before="$(git_here -C "$dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
      if git_clone_or_update "$url" "$dir" "$ref" >/dev/null 2>&1; then
        after="$(git_here -C "$dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        _cu_row FIXED repo "$name" "forced onto ${ref} ${before} -> ${after} (was: ${why})${note}"
      else
        _cu_row GAP repo "$name" "forced update onto ${ref} FAILED (${why})${note}"
      fi
      return 0
    fi
    _cu_row SKIP repo "$name" "${why} — left untouched; --force-repos to reset it onto ${ref}${note}"
    return 0
  fi
  # Every capture below carries its own fallback: this runs under `set -e` with
  # pipefail, where a bare `x="$(cmd)"` that fails would abort the whole script.
  before="$(git_here -C "$dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"

  # Safe here: clean tree, on the pinned ref. git_clone_or_update does the same
  # thing on the forced path.
  if [ -n "$origin" ] && [ "$origin" != "$url" ]; then
    git_here -C "$dir" remote set-url origin "$url" >/dev/null 2>&1 \
      && note=" (origin re-pointed from ${origin})"
  fi

  if ! git_here -C "$dir" fetch --depth 1 origin "$branch" >/dev/null 2>&1; then
    _cu_row GAP repo "$name" "fetch failed (offline? branch '${branch}' gone?) — still at ${before}"
    return 0
  fi
  if ! git_here -C "$dir" reset --hard "origin/${branch}" >/dev/null 2>&1; then
    _cu_row GAP repo "$name" "could not fast-forward onto origin/${branch}"
    return 0
  fi
  after="$(git_here -C "$dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"

  if [ "$before" = "$after" ]; then
    _cu_row OK repo "$name" "current (${branch} @ ${after})${note}"
  elif [ "$class" = "stack" ]; then
    _cu_row FIXED repo "$name" "${branch} ${before} -> ${after}${note} — needs 'docker compose up -d' to take effect"
  else
    _cu_row FIXED repo "$name" "${branch} ${before} -> ${after}${note}"
  fi
}

catchup_repos() {
  step "Dependency repos"
  local line name url dir ref class
  while IFS= read -r line; do
    IFS='|' read -r name url dir ref class <<<"$line"
    _cu_update_repo "$name" "$url" "$dir" "$ref" "$class"
  done < <(catchup_expected_repos)
}

# -----------------------------------------------------------------------------
# catchup_helper_scripts — rewrite the generated helpers from the modules that
# were just pulled. They are generated files, so rewriting is how a site picks
# up fixes to them; doing it unconditionally keeps the check trivial and the
# result identical to a fresh install.
# -----------------------------------------------------------------------------
catchup_helper_scripts() {
  step "Installed helper scripts"

  # --- auto-pull updater ---------------------------------------------------
  if [ "$AUTO_PULL" = "1" ]; then
    local had_updater=0
    [ -x "$AUTO_PULL_SCRIPT" ] && had_updater=1
    if write_updater_script >/dev/null 2>&1; then
      if [ "$had_updater" = "1" ]; then
        _cu_row OK script "$(basename "$AUTO_PULL_SCRIPT")" "present, refreshed from this release"
      else
        _cu_row FIXED script "$(basename "$AUTO_PULL_SCRIPT")" "was missing — installed"
      fi
    else
      _cu_row GAP script "$(basename "$AUTO_PULL_SCRIPT")" "could not be written"
    fi
  else
    _cu_row SKIP script "$(basename "$AUTO_PULL_SCRIPT")" "auto-pull disabled (EREGISTER_AUTO_PULL=0)"
  fi

  [ "$IMPORT_FORMS" = "1" ] || {
    _cu_row SKIP script "form importer" "form import disabled (--no-forms)"
    return 0
  }

  # --- form importer + its runner -----------------------------------------
  local had_importer=0
  [ -x "$FORM_IMPORT_SCRIPT" ] && had_importer=1
  if _forms_install_importer >/dev/null 2>&1; then
    if [ "$had_importer" = "1" ]; then
      _cu_row OK script "$(basename "$FORM_IMPORT_SCRIPT")" "present, refreshed from this release"
    else
      _cu_row FIXED script "$(basename "$FORM_IMPORT_SCRIPT")" "was missing — installed"
    fi
  else
    _cu_row GAP script "$(basename "$FORM_IMPORT_SCRIPT")" "could not be installed"
    return 0
  fi

  # --- credentials for the unattended runs ---------------------------------
  # Never overwrite a working env file: the password in it is the one the site
  # actually uses, and this script may be running without any password at hand.
  if as_root test -s "$FORM_IMPORT_ENV"; then
    _cu_row OK config "$(basename "$FORM_IMPORT_ENV")" "present (left as-is)"
  elif _forms_prompt_credentials; then
    _forms_write_env >/dev/null 2>&1
    _cu_row FIXED config "$(basename "$FORM_IMPORT_ENV")" "was missing — written for ${BAHMNI_USER}@${BAHMNI_URL}"
  else
    _cu_row GAP config "$(basename "$FORM_IMPORT_ENV")" "missing and no password given — the daily form import cannot run"
  fi

  local had_runner=0
  [ -x "$FORM_IMPORT_RUNNER" ] && had_runner=1
  if _forms_write_runner >/dev/null 2>&1; then
    if [ "$had_runner" = "1" ]; then
      _cu_row OK script "$(basename "$FORM_IMPORT_RUNNER")" "present, refreshed from this release"
    else
      _cu_row FIXED script "$(basename "$FORM_IMPORT_RUNNER")" "was missing — installed"
    fi
  else
    _cu_row GAP script "$(basename "$FORM_IMPORT_RUNNER")" "could not be written"
  fi

  # --- database backup script (independent of everything else here) --------
  # Written before the form/concept rows below on purpose: this is the script a
  # site needs when one of those two jobs has done something it should not have.
  if [ "${DB_BACKUP:-1}" = "1" ]; then
    local had_dbb=0
    [ -x "$DB_BACKUP_RUNNER" ] && had_dbb=1
    if _dbbackup_write_runner >/dev/null 2>&1; then
      if [ "$had_dbb" = "1" ]; then
        _cu_row OK script "$(basename "$DB_BACKUP_RUNNER")" "present, refreshed from this release"
      else
        _cu_row FIXED script "$(basename "$DB_BACKUP_RUNNER")" "was missing — installed"
      fi
    else
      _cu_row GAP script "$(basename "$DB_BACKUP_RUNNER")" "could not be written"
    fi
  else
    _cu_row SKIP script "$(basename "$DB_BACKUP_RUNNER")" "database backup disabled (--no-db-backup)"
  fi

  # --- concept-dictionary runner (its own job, independent of forms) -------
  if [ "${CONCEPT_IMPORT:-1}" = "1" ]; then
    local had_crunner=0
    [ -x "$CONCEPT_IMPORT_RUNNER" ] && had_crunner=1
    if _concepts_ensure_toolkit >/dev/null 2>&1 && _concepts_write_runner >/dev/null 2>&1; then
      if [ "$had_crunner" = "1" ]; then
        _cu_row OK script "$(basename "$CONCEPT_IMPORT_RUNNER")" "present, refreshed from this release"
      else
        _cu_row FIXED script "$(basename "$CONCEPT_IMPORT_RUNNER")" "was missing — installed"
      fi
    else
      _cu_row GAP script "$(basename "$CONCEPT_IMPORT_RUNNER")" "could not be installed"
    fi
  else
    _cu_row SKIP script "$(basename "$CONCEPT_IMPORT_RUNNER")" "concept job disabled (EREGISTER_CONCEPT_IMPORT=0)"
  fi

}

# -----------------------------------------------------------------------------
# _cu_schedule_state — how a unit is scheduled on this host, as a short string
# on stdout; non-zero when it is not scheduled at all.
# -----------------------------------------------------------------------------
_cu_schedule_state() { # _cu_schedule_state <unit-basename>
  local unit="$1" next=""
  if has_systemd && as_root systemctl list-unit-files "${unit}.timer" >/dev/null 2>&1 \
     && as_root systemctl is-enabled "${unit}.timer" >/dev/null 2>&1; then
    next="$(as_root systemctl list-timers --all --no-pager "${unit}.timer" 2>/dev/null \
            | awk 'NR==2 {print $1, $2, $3}' || true)"
    printf 'systemd timer %s, next: %s' \
      "$(as_root systemctl is-active "${unit}.timer" 2>/dev/null || echo inactive)" \
      "${next:-unknown}"
    return 0
  fi
  if [ -f "/etc/cron.d/${unit}" ]; then
    printf 'cron: %s' "$(as_root awk '$0 !~ /^#|^$|^[A-Z]+=/ {print $1, $2, $3, $4, $5; exit}' "/etc/cron.d/${unit}")"
    return 0
  fi
  return 1
}

# _cu_scheduler_available — does this host have anything to schedule WITH?
# Told apart from a failed install so the report can say which it was.
_cu_scheduler_available() { has_systemd || [ -d /etc/cron.d ]; }

# -----------------------------------------------------------------------------
# catchup_schedules — the point of the whole exercise for an early site: make
# sure both scheduled jobs exist, and install the missing one.
# -----------------------------------------------------------------------------
catchup_schedules() {
  step "Scheduled jobs"
  local state

  # --- nightly repo auto-pull ---------------------------------------------
  if [ "$AUTO_PULL" != "1" ]; then
    _cu_row SKIP cron "$AUTO_PULL_UNIT" "disabled (EREGISTER_AUTO_PULL=0)"
  elif state="$(_cu_schedule_state "$AUTO_PULL_UNIT")"; then
    _cu_row OK cron "$AUTO_PULL_UNIT" "$state"
  elif ! _cu_scheduler_available; then
    _cu_row GAP cron "$AUTO_PULL_UNIT" "no systemd and no /etc/cron.d — schedule '${AUTO_PULL_CRON} ${AUTO_PULL_SCRIPT}' by hand"
  else
    warn "The repo auto-pull job is not scheduled on this host."
    if confirm "Install the auto-pull schedule (${AUTO_PULL_CRON})?"; then
      if install_auto_pull >/dev/null 2>&1 && state="$(_cu_schedule_state "$AUTO_PULL_UNIT")"; then
        _cu_row FIXED cron "$AUTO_PULL_UNIT" "installed — ${state}"
      else
        _cu_row GAP cron "$AUTO_PULL_UNIT" "installation failed"
      fi
    else
      _cu_row GAP cron "$AUTO_PULL_UNIT" "not scheduled (declined)"
    fi
  fi

  # --- daily clinical form import -----------------------------------------
  if [ "$IMPORT_FORMS" != "1" ]; then
    _cu_row SKIP cron "$FORM_IMPORT_UNIT" "disabled (--no-forms)"
  elif state="$(_cu_schedule_state "$FORM_IMPORT_UNIT")"; then
    _cu_row OK cron "$FORM_IMPORT_UNIT" "$state"
  elif [ ! -x "$FORM_IMPORT_RUNNER" ]; then
    _cu_row GAP cron "$FORM_IMPORT_UNIT" "not scheduled (its runner is missing)"
  elif ! _cu_scheduler_available; then
    _cu_row GAP cron "$FORM_IMPORT_UNIT" "no systemd and no /etc/cron.d — schedule '${FORM_IMPORT_CRON} ${FORM_IMPORT_RUNNER}' by hand"
  else
    warn "The daily clinical form import is not scheduled on this host."
    if confirm "Install the daily form-import schedule (${FORM_IMPORT_CRON})?"; then
      if _forms_schedule >/dev/null 2>&1 && state="$(_cu_schedule_state "$FORM_IMPORT_UNIT")"; then
        _cu_row FIXED cron "$FORM_IMPORT_UNIT" "installed — ${state}"
      else
        _cu_row GAP cron "$FORM_IMPORT_UNIT" "installation failed"
      fi
    else
      _cu_row GAP cron "$FORM_IMPORT_UNIT" "not scheduled (declined)"
    fi
  fi

  # --- daily database backup ------------------------------------------------
  if [ "${DB_BACKUP:-1}" != "1" ]; then
    _cu_row SKIP cron "$DB_BACKUP_UNIT" "disabled (--no-db-backup)"
  elif state="$(_cu_schedule_state "$DB_BACKUP_UNIT")"; then
    _cu_row OK cron "$DB_BACKUP_UNIT" "$state"
  elif [ ! -x "$DB_BACKUP_RUNNER" ]; then
    _cu_row GAP cron "$DB_BACKUP_UNIT" "not scheduled (its script is missing)"
  elif ! _cu_scheduler_available; then
    _cu_row GAP cron "$DB_BACKUP_UNIT" "no systemd and no /etc/cron.d — schedule '${DB_BACKUP_CRON} ${DB_BACKUP_RUNNER}' by hand"
  else
    warn "This site has NO scheduled backup of the openmrs database."
    if confirm "Install the daily database backup (${DB_BACKUP_CRON}, keeping ${DB_BACKUP_KEEP} dumps)?"; then
      if _dbbackup_schedule >/dev/null 2>&1 && state="$(_cu_schedule_state "$DB_BACKUP_UNIT")"; then
        _cu_row FIXED cron "$DB_BACKUP_UNIT" "installed — ${state}"
        # A site that had no backup job has no backups either, and the two jobs
        # still to come in this run (the form import, the EMR reload) are
        # exactly the sort of thing you would want one from before. So take the
        # first dump now rather than leaving the site bare until 01:30. Only on
        # a FIRST install — a site whose job was already scheduled has last
        # night's dump and does not need another.
        if confirm "Take the first database backup now (it has none)?"; then
          run_db_backup || true
        fi
      else
        _cu_row GAP cron "$DB_BACKUP_UNIT" "installation failed"
      fi
    else
      _cu_row GAP cron "$DB_BACKUP_UNIT" "not scheduled (declined) — this site has no database backup"
    fi
  fi

  # --- daily concept-dictionary import -------------------------------------
  if [ "${CONCEPT_IMPORT:-1}" != "1" ]; then
    _cu_row SKIP cron "$CONCEPT_IMPORT_UNIT" "disabled (EREGISTER_CONCEPT_IMPORT=0)"
  elif state="$(_cu_schedule_state "$CONCEPT_IMPORT_UNIT")"; then
    _cu_row OK cron "$CONCEPT_IMPORT_UNIT" "$state"
  elif [ ! -x "$CONCEPT_IMPORT_RUNNER" ]; then
    _cu_row GAP cron "$CONCEPT_IMPORT_UNIT" "not scheduled (its runner is missing)"
  elif ! _cu_scheduler_available; then
    _cu_row GAP cron "$CONCEPT_IMPORT_UNIT" "no systemd and no /etc/cron.d — schedule '${CONCEPT_IMPORT_CRON} ${CONCEPT_IMPORT_RUNNER}' by hand"
  else
    warn "The daily concept-dictionary import is not scheduled on this host."
    if confirm "Install the daily concept-import schedule (${CONCEPT_IMPORT_CRON})?"; then
      if _concepts_schedule >/dev/null 2>&1 && state="$(_cu_schedule_state "$CONCEPT_IMPORT_UNIT")"; then
        _cu_row FIXED cron "$CONCEPT_IMPORT_UNIT" "installed — ${state}"
      else
        _cu_row GAP cron "$CONCEPT_IMPORT_UNIT" "installation failed"
      fi
    else
      _cu_row GAP cron "$CONCEPT_IMPORT_UNIT" "not scheduled (declined)"
    fi
  fi
}

# -----------------------------------------------------------------------------
# catchup_forms — run the form import once, now. Cheap and safe to repeat: the
# importer deploys only the forms whose content changed since the last run, and
# a changed form goes out as a NEW version, so nothing live is overwritten.
# -----------------------------------------------------------------------------
catchup_forms() {
  step "Clinical observation forms"

  if [ "$IMPORT_FORMS" != "1" ]; then
    _cu_row SKIP forms "import" "disabled (--no-forms)"
    return 0
  fi
  if [ ! -x "$FORM_IMPORT_RUNNER" ] || ! as_root test -s "$FORM_IMPORT_ENV"; then
    _cu_row GAP forms "import" "not runnable (missing runner or credentials)"
    return 0
  fi

  local deployed=0
  if as_root test -s "$FORM_IMPORT_STATE" && command -v jq >/dev/null 2>&1; then
    deployed="$(as_root cat "$FORM_IMPORT_STATE" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  fi
  info "Forms recorded as deployed on this site so far: ${deployed}"
  info "Concept resolution makes this slow — minutes per changed form. Unchanged forms are skipped."

  if ! confirm "Run the form import now?"; then
    _cu_row SKIP forms "import" "declined; the daily job still runs (${FORM_IMPORT_CRON})"
    return 0
  fi

  if run_form_import; then
    local summary
    summary="$(as_root grep -E 'imported [0-9]+/' "$FORM_IMPORT_LOG" 2>/dev/null | tail -1 || true)"
    # "imported 0/…" means every form was already current — that is an OK, not
    # a FIXED: nothing on the site actually changed.
    if [[ "$summary" == *"imported 0/"* ]]; then
      _cu_row OK forms "import" "$summary"
    else
      _cu_row FIXED forms "import" "${summary:-completed}"
    fi
  else
    _cu_row GAP forms "import" "run failed — see ${FORM_IMPORT_LOG}"
  fi
}

# -----------------------------------------------------------------------------
# catchup_concepts — REPORT ONLY.
#
# Importing drops and recreates the concept_*/drug* tables, so catch-up does not
# do it. The daily concept job does, when the dump changes. The severity of the
# "imported" row therefore depends on whether that job is actually scheduled:
# a newer dump with the job in place is simply pending (OK), while the same dump
# with no job is a real gap that needs a human.
# -----------------------------------------------------------------------------
catchup_concepts() {
  step "Concept dictionary (report only)"
  local count=""

  # --no-concepts means "leave the dictionary alone", so it silences these rows
  # too. Reporting a GAP that tells you to run the job you just disabled would
  # be noise, and it would fail the exit code for a state you chose.
  if [ "${CONCEPT_IMPORT:-1}" != "1" ]; then
    _cu_row SKIP concepts "dictionary" "left alone (--no-concepts)"
    return 0
  fi

  if ! _concepts_resolve_sql >/dev/null 2>&1 || [ ! -f "$CONCEPTS_SQL" ]; then
    _cu_row GAP concepts "dump" "no ${CONCEPTS_SQL_PATTERN} in ${CONCEPTS_DIR}"
    return 0
  fi
  _cu_row OK concepts "dump" "$(basename "$CONCEPTS_SQL") ($(as_root du -h "$CONCEPTS_SQL" 2>/dev/null | awk '{print $1}'))"

  # The question the old report could not answer: is what is on disk what is in
  # the database? The nightly pull brings new dictionaries in silently, so a
  # site can sit on a stale one indefinitely while every other row reads OK.
  local disk_hash prev_hash prev_file prev_when
  disk_hash="$(_concepts_hash "$CONCEPTS_SQL" 2>/dev/null | awk '{print $1}')"
  prev_hash="$(_concepts_state_get sha256)"
  prev_file="$(_concepts_state_get file)"
  prev_when="$(_concepts_state_get imported_at)"
  # Is anything scheduled to act on a stale dictionary? That decides whether a
  # newer dump is "pending" or "stuck".
  local job_state="" job_ok=0
  if [ "${CONCEPT_IMPORT:-1}" = "1" ] && job_state="$(_cu_schedule_state "$CONCEPT_IMPORT_UNIT")"; then
    job_ok=1
  fi

  if [ -z "$prev_hash" ]; then
    if [ "$job_ok" = "1" ]; then
      _cu_row OK concepts "imported" "no import recorded yet — the daily job loads it (${CONCEPT_IMPORT_CRON})"
    else
      _cu_row GAP concepts "imported" "no import recorded and no job scheduled — run ${CONCEPT_IMPORT_RUNNER} (or ./import-concepts.sh)"
    fi
  elif [ "$prev_hash" = "$disk_hash" ]; then
    _cu_row OK concepts "imported" "${prev_file:-?} is the dump in the database (imported ${prev_when:-?})"
  elif [ "$job_ok" = "1" ]; then
    _cu_row OK concepts "imported" "newer dump pending — daily job loads it (${CONCEPT_IMPORT_CRON}); in the DB now: ${prev_file:-?} from ${prev_when:-?}"
  else
    _cu_row GAP concepts "imported" "dump on disk is NEWER than the one imported (${prev_file:-?} on ${prev_when:-?}) and NO job is scheduled — run ${CONCEPT_IMPORT_RUNNER}"
  fi

  if [ "$CATCHUP_DB_CHECK" != "1" ]; then
    _cu_row SKIP concepts "database" "DB check disabled (EREGISTER_CATCHUP_DB_CHECK=0)"
    return 0
  fi
  # Read-only probe through the same helper the importer uses.
  if _concepts_resolve_compose >/dev/null 2>&1 && [ -n "${DOCKER_COMPOSE:-}" ] && [ -d "$RESTORE_DIR" ]; then
    count="$(printf 'SELECT COUNT(*) FROM concept;\n' | _concepts_mysql -N 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
    _cu_row OK concepts "database" "${DB_NAME}.concept holds ${count} rows"
  else
    _cu_row GAP concepts "database" "could not read a concept count — import may never have run (./import-concepts.sh)"
  fi
}

# -----------------------------------------------------------------------------
# catchup_reporting — import the OpenMRS report definitions, for real.
#
# The one import catch-up performs itself, and the reason it can:
#   * it replaces ONE table, serialized_object — the report/cohort/indicator
#     definitions the Reports app lists. No patient data, no concepts, no obs.
#   * a pre-import dump of that table goes to BACKUP_DIR first, so it is
#     undoable with a single mysql < file.
#   * it is content-addressed: a clone whose dump is already the one in the
#     database costs a sha256 and stops there, so running catch-up nightly
#     never re-imports the same definitions.
#   * nothing else schedules it. The concept dictionary has a daily job to
#     defer to; the report definitions do not, so "catch-up reports a gap and
#     leaves it" would leave the gap open forever.
#
# The heavy lifting is in lib/upgrade/reporting.sh; this only turns the status
# it comes back with into a report row.
# -----------------------------------------------------------------------------
catchup_reporting() {
  # import_reporting prints its own step banner.
  # `|| true`: a failed import is a GAP row, not a reason to lose the report.
  import_reporting || true

  case "${REPORTING_STATUS:-}" in
    imported) _cu_row FIXED reporting "definitions" "${REPORTING_DETAIL}" ;;
    current)  _cu_row OK    reporting "definitions" "${REPORTING_DETAIL}" ;;
    disabled) _cu_row SKIP  reporting "definitions" "${REPORTING_DETAIL}" ;;
    declined) _cu_row SKIP  reporting "definitions" "${REPORTING_DETAIL}" ;;
    no-db)    _cu_row GAP   reporting "definitions" "${REPORTING_DETAIL}" ;;
    no-dump)  _cu_row GAP   reporting "dump"        "${REPORTING_DETAIL}" ;;
    failed)   _cu_row GAP   reporting "definitions" "${REPORTING_DETAIL:-import failed}" ;;
    *)        _cu_row GAP   reporting "definitions" "import did not report a status" ;;
  esac
}

# -----------------------------------------------------------------------------
# catchup_db_backups — REPORT ONLY: are the nightly dumps actually happening?
#
# The schedule row above says a timer exists. This one says the timer is
# producing files — which is a different question, and the one that matters. A
# backup job whose openmrsdb service has been unreachable since a compose rename
# fails silently every night; the only visible symptom is that the newest dump
# stops moving. So: count the dumps, and age the newest one against the
# schedule. Nothing here writes anything.
# -----------------------------------------------------------------------------
catchup_db_backups() {
  step "Database backups (report only)"

  if [ "${DB_BACKUP:-1}" != "1" ]; then
    _cu_row SKIP backup "dumps" "left alone (--no-db-backup)"
    return 0
  fi
  if ! as_root test -d "$DB_BACKUP_DIR"; then
    _cu_row GAP backup "dumps" "no backup folder yet at ${DB_BACKUP_DIR} — run: sudo ${DB_BACKUP_RUNNER}"
    return 0
  fi

  local count newest newest_epoch age_h now
  # -type f, so the 'latest' symlink is not counted as a dump of its own.
  count="$(as_root find "$DB_BACKUP_DIR" -maxdepth 1 -type f \
             \( -name "${DB_NAME}_*.sql" -o -name "${DB_NAME}_*.sql.gz" \) 2>/dev/null \
           | wc -l | tr -d ' ')"
  if [ "${count:-0}" -eq 0 ]; then
    _cu_row GAP backup "dumps" "${DB_BACKUP_DIR} holds no dumps — the job has never produced one (sudo ${DB_BACKUP_RUNNER})"
    return 0
  fi

  # Names carry the timestamp, so the newest sorts last.
  newest="$(as_root find "$DB_BACKUP_DIR" -maxdepth 1 -type f \
              \( -name "${DB_NAME}_*.sql" -o -name "${DB_NAME}_*.sql.gz" \) 2>/dev/null \
            | sort | tail -1)"
  newest_epoch="$(as_root stat -c %Y "$newest" 2>/dev/null || as_root stat -f %m "$newest" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age_h=$(( ( now - ${newest_epoch:-0} ) / 3600 ))

  # 36h, not 24h: a daily job plus systemd RandomizedDelaySec plus a host that
  # was off overnight is not yet a broken backup.
  if [ "${newest_epoch:-0}" -gt 0 ] && [ "$age_h" -le 36 ]; then
    _cu_row OK backup "dumps" "${count} kept (limit ${DB_BACKUP_KEEP}); newest $(basename "$newest") $(as_root du -h "$newest" 2>/dev/null | awk '{print $1}'), ${age_h}h old"
  else
    _cu_row GAP backup "dumps" "${count} kept, but the newest ($(basename "$newest")) is ${age_h}h old — the job is failing; see ${DB_BACKUP_LOG}"
  fi

  # A .part file is a dump that failed its completeness check. It is left behind
  # deliberately, and it is worth a row: it names the night the backup broke.
  local partials
  partials="$(as_root find "$DB_BACKUP_DIR" -maxdepth 1 -type f -name '*.part' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${partials:-0}" -gt 0 ]; then
    _cu_row GAP backup "partial dumps" "${partials} incomplete dump(s) (*.part) in ${DB_BACKUP_DIR} — a run was truncated; check ${DB_BACKUP_LOG}, then delete them"
  fi
}

# -----------------------------------------------------------------------------
# catchup_services — READ-ONLY health of the running stack.
# `docker compose ps` and two HTTP probes; nothing is started or stopped.
# -----------------------------------------------------------------------------
catchup_services() {
  step "Service health (read-only)"

  if [ ! -d "$RESTORE_DIR" ]; then
    _cu_row GAP services "stack" "no stack directory at ${RESTORE_DIR}"
    return 0
  fi
  # Without this, an empty DOCKER_COMPOSE would turn `as_root $DOCKER_COMPOSE ps`
  # into a plain `ps` and report the host's process list as the stack.
  if ! _concepts_resolve_compose >/dev/null 2>&1 || [ -z "${DOCKER_COMPOSE:-}" ]; then
    _cu_row GAP services "docker compose" "not available on this host — cannot read service health"
    return 0
  fi

  local rows total=0 up=0 line name state status
  rows="$( ( cd "$RESTORE_DIR" && as_root $DOCKER_COMPOSE ps --format '{{.Service}}|{{.State}}|{{.Status}}' 2>/dev/null ) || true )"

  if [ -z "$rows" ]; then
    # Older compose builds have no Go-template support for ps; fall back to the
    # plain table so the operator still sees something real.
    rows="$( ( cd "$RESTORE_DIR" && as_root $DOCKER_COMPOSE ps 2>/dev/null ) || true )"
    if [ -n "$rows" ]; then
      log "$rows"
      _cu_row OK services "compose ps" "printed above (this compose build has no --format support)"
    else
      _cu_row GAP services "compose ps" "no containers found for the stack in ${RESTORE_DIR}"
    fi
    return 0
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS='|' read -r name state status <<<"$line"
    total=$(( total + 1 ))
    case "$state" in
      running) up=$(( up + 1 )); [[ "$status" == *unhealthy* ]] && _cu_row GAP service "$name" "$status" ;;
      *)       _cu_row GAP service "$name" "${state:-unknown} — ${status:-no status}" ;;
    esac
  done <<<"$rows"

  if [ "$up" -eq "$total" ] && [ "$total" -gt 0 ]; then
    _cu_row OK services "containers" "${up}/${total} running"
  else
    _cu_row GAP services "containers" "${up}/${total} running"
  fi

  # --- endpoints -----------------------------------------------------------
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time "$CATCHUP_HTTP_TIMEOUT" \
          "${BAHMNI_URL}/openmrs/ws/rest/v1/session" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then
    _cu_row OK endpoint "openmrs REST" "${BAHMNI_URL}/openmrs — HTTP 200"
  else
    _cu_row GAP endpoint "openmrs REST" "${BAHMNI_URL}/openmrs — HTTP ${code} (still booting? EMR needs 30+ min)"
  fi
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time "$CATCHUP_HTTP_TIMEOUT" \
          "${BAHMNI_URL}/bahmni/home/index.html" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    _cu_row OK endpoint "bahmni UI" "${BAHMNI_URL}/bahmni — HTTP ${code}"
  else
    _cu_row GAP endpoint "bahmni UI" "${BAHMNI_URL}/bahmni — HTTP ${code}"
  fi
}

# -----------------------------------------------------------------------------
# catchup_recreate_emr — the LAST job: recreate the EMR service so everything
# refreshed above is actually picked up.
#
#     docker compose up -d --force-recreate --renew-anon-volumes <EMR_SERVICE>
#
# Why it is needed: the steps before this update files on disk — standard-config,
# the omods, the implementer interface, the forms. A long-running openmrs
# container goes on serving what it read at boot, and anything seeded into an
# ANONYMOUS volume when the container was first created keeps the old content
# even across a plain restart. --force-recreate replaces the container and
# --renew-anon-volumes throws its anonymous volumes away so they are re-seeded.
#
# THIS IS THE ONE PART OF CATCH-UP THAT TOUCHES A RUNNING CONTAINER:
#   * the EMR is down until it finishes booting — normally 30+ minutes;
#   * the openmrs service's anonymous volumes are discarded. Named volumes and
#     the separate openmrsdb service (the patient data) are NOT touched, so this
#     is not a data-loss operation — but anything a site hand-placed inside the
#     running EMR container, rather than in its config repo, is gone.
# Hence the confirm, the --no-recreate flag and EREGISTER_CATCHUP_RECREATE=0.
# -----------------------------------------------------------------------------
catchup_recreate_emr() {
  step "Reloading the EMR service (${EMR_SERVICE})"

  if [ "${CATCHUP_RECREATE_EMR:-1}" != "1" ]; then
    _cu_row SKIP reload "$EMR_SERVICE" "not recreated (--no-recreate)"
    return 0
  fi
  if [ ! -d "$RESTORE_DIR" ]; then
    _cu_row GAP reload "$EMR_SERVICE" "no stack directory at ${RESTORE_DIR}"
    return 0
  fi
  if ! _concepts_resolve_compose >/dev/null 2>&1 || [ -z "${DOCKER_COMPOSE:-}" ]; then
    _cu_row GAP reload "$EMR_SERVICE" "docker compose not available on this host"
    return 0
  fi

  warn "This RECREATES the '${EMR_SERVICE}' container so it picks up the refreshed"
  warn "config, omods and forms, and renews its anonymous volumes."
  warn "The EMR will be DOWN while it boots — normally 30+ minutes."
  warn "Patient data (the ${DB_SERVICE} service and its named volumes) is not touched."
  if ! confirm "Recreate '${EMR_SERVICE}' now?"; then
    _cu_row SKIP reload "$EMR_SERVICE" "declined — run it yourself: cd ${RESTORE_DIR} && ${DOCKER_COMPOSE} up -d --force-recreate --renew-anon-volumes ${EMR_SERVICE}"
    return 0
  fi

  info "Running: ${DOCKER_COMPOSE} up -d --force-recreate --renew-anon-volumes ${EMR_SERVICE}"
  if ( cd "$RESTORE_DIR" && as_root $DOCKER_COMPOSE up -d --force-recreate --renew-anon-volumes "$EMR_SERVICE" ); then
    _cu_row FIXED reload "$EMR_SERVICE" "recreated with renewed anonymous volumes — booting now"
    success "'${EMR_SERVICE}' recreated. It is booting; give it 30+ minutes before use."
    CATCHUP_EMR_RECREATED=1
  else
    _cu_row GAP reload "$EMR_SERVICE" "recreate FAILED — check '${DOCKER_COMPOSE} ps' and the service logs"
    error "Could not recreate '${EMR_SERVICE}'."
    return 1
  fi
}

# -----------------------------------------------------------------------------
# catchup_report — the whole point of the run: one table, then a verdict.
# -----------------------------------------------------------------------------
catchup_report() {
  local row status kind name detail mark color
  printf '\n%s══════════════════════════════════════════════════════════════%s\n' "$C_HDR" "$C_RESET" >&2
  printf '%s eRegister v1 — catch-up report  (%s)%s\n' "$C_HDR" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$C_RESET" >&2
  printf '%s══════════════════════════════════════════════════════════════%s\n\n' "$C_HDR" "$C_RESET" >&2

  for row in "${CATCHUP_ROWS[@]}"; do
    IFS='|' read -r status kind name detail <<<"$row"
    case "$status" in
      OK)    mark="✔"; color="$C_OK"   ;;
      FIXED) mark="⟳"; color="$C_INFO" ;;
      SKIP)  mark="—"; color="$C_DIM"  ;;
      *)     mark="✘"; color="$C_ERR"  ;;
    esac
    printf '  %s%s %-5s%s %-9s %-32.32s %s\n' \
      "$color" "$mark" "$status" "$C_RESET" "$kind" "$name" "$detail" >&2
  done

  printf '\n' >&2
  info "OK = already current · FIXED = redone by this run · SKIP = left alone · GAP = needs attention"

  if [ "$CATCHUP_GAPS" -eq 0 ]; then
    success "No gaps: this site matches what the installer is meant to leave behind."
  else
    warn "${CATCHUP_GAPS} item(s) need attention — see the ✘ rows above."
  fi

  if [ "$CATCHUP_EMR_RECREATED" = "1" ]; then
    notice "'${EMR_SERVICE}' was just recreated and is still booting. Give it 30+ minutes; the endpoint rows above were probed BEFORE the reload."
  fi

  local touched="Nothing here stopped or restarted a container."
  [ "$CATCHUP_EMR_RECREATED" = "1" ] && \
    touched="Apart from the '${EMR_SERVICE}' reload, nothing here stopped or restarted a container."

  cat >&2 <<EOF

  ${touched} If a repo row says a stack
  update needs it, apply that during a maintenance window:
      cd ${RESTORE_DIR} && ${DOCKER_COMPOSE:-docker compose} up -d

  Concept dictionary — handled by its own daily job (${CONCEPT_IMPORT_CRON}):
      check now:   sudo ${CONCEPT_IMPORT_RUNNER}
      log:         ${CONCEPT_IMPORT_LOG}
      by hand:     ${UPGRADE_REPO_DIR}/import-concepts.sh
    An imported dictionary is only visible after ${EMR_SERVICE} restarts.

  Report definitions — imported by this script, from the clone at
  ${REPORTING_DIR}:
      re-import:   sudo ${UPGRADE_REPO_DIR}/catch-up.sh   (skipped when already current)
      force one:   sudo rm ${REPORTING_IMPORT_STATE}, then run that again
      undo one:    the pre-import dump in ${BACKUP_DIR}/reporting-preimport-*.sql
    New reports only appear after ${EMR_SERVICE} restarts.

  Database backups — nightly (${DB_BACKUP_CRON}), kept ${DB_BACKUP_KEEP} deep:
      take one now: sudo ${DB_BACKUP_RUNNER}
      they live in: ${DB_BACKUP_DIR}
      log:          ${DB_BACKUP_LOG}
      restore one:  gzip -dc ${DB_BACKUP_DIR}/latest.sql.gz \\
                      | (cd ${RESTORE_DIR} && ${DOCKER_COMPOSE:-docker compose} exec -T ${DB_SERVICE} mysql -u${DB_USER} -p)
    These sit on this machine's own disk — copy them off it too.

  Run the form import by hand:   sudo ${FORM_IMPORT_RUNNER}
  Run the repo sync by hand:     sudo ${AUTO_PULL_SCRIPT}
  Logs:                          ${FORM_IMPORT_LOG}
                                 ${AUTO_PULL_LOG}
EOF
}

# -----------------------------------------------------------------------------
# catch_up — orchestrator. Returns non-zero when gaps remain, so it can be used
# as a monitoring check (`catch-up.sh --yes; echo $?`).
# -----------------------------------------------------------------------------
catch_up() {
  # Phase 1 (updating this repo) happened in catch-up.sh before these modules
  # even existed, so it hands its outcome over in the environment.
  if [ -n "${EREGISTER_CATCHUP_SELF_STATUS:-}" ]; then
    _cu_row "$EREGISTER_CATCHUP_SELF_STATUS" self "upgrade-to-v1" \
            "${EREGISTER_CATCHUP_SELF_DETAIL:-}"
  fi
  catchup_repos
  catchup_helper_scripts
  catchup_schedules
  catchup_forms
  catchup_concepts
  catchup_reporting     # the one import catch-up does itself (see the function)
  catchup_db_backups
  catchup_services      # health of the site AS FOUND, before anything is reloaded
  # `|| true` because catch-up.sh runs under `set -e`: this is the only step
  # that returns non-zero, and losing the report over it would be the worst
  # possible moment to lose the report. The failure is already a GAP row.
  catchup_recreate_emr || true   # last job: the EMR picks up everything above
  catchup_report
  [ "$CATCHUP_GAPS" -eq 0 ]
}
