#!/usr/bin/env bash
###############################################################################
# eRegister Lesotho — Installer / Upgrader (v0.92 -> v1)
#
# eRegister is an EMR system based on Bahmni. This script works as BOTH a fresh
# installer and an in-place upgrader. Functions are organized into modules under
# lib/ (see DESIGN NOTES); only main() lives here.
#
# USAGE
#   ./install.sh [--yes] [--force] [--install-dir DIR] [--target-ref REF]
#                [--no-concepts] [--no-forms] [--no-db-backup] [--help]
#
# FLAGS / ENV
#   -y, --yes            Non-interactive; assume "yes" to all prompts (CI/automation).
#                        Also enabled with: EREGISTER_ASSUME_YES=1
#   --force              Redo the whole upgrade even if the v1 marker says the
#                        install already finished (or was only part-way through).
#   --install-dir DIR    Override install base (default: /var/lib).
#   --target-ref REF[,REF...]
#                        Git ref(s)/tag(s)/commit(s) to check out for the repos.
#                        Tried in order against each repo; the first one that
#                        exists on that remote wins, and the repo's own default
#                        ref is the last resort. The repos do not share a branch
#                        name, so a list is usually what you want:
#                          --target-ref Bokang-changes,main
#                        Default: empty (each repo uses its own default ref).
#   --no-concepts        Do not install the concept-dictionary job at all — no
#                        delayed first import, no daily job.
#   --no-forms           Skip the post-install clinical form import (and its
#                        daily job).
#   --no-db-backup       Do not install the daily backup of the v1 database.
#                        The site is then left with NO routine backup at all.
#   --no-color           Disable ANSI colors.
#   -h, --help           Show help and exit.
#
#   The concept dictionary shipped in eregister_concepts_release_v1
#   (omrs_concept_dictionary_*.sql) is NOT imported by this script. The stack has
#   only just been started when the upgrade ends: openmrsdb answers early, but
#   the instance behind it needs 30+ minutes — hours on site hardware — before
#   importing a dictionary is worth doing, and the import replaces the
#   concept_*/drug* tables (a pre-import copy goes to
#   <base>/v1/bahmni-backup/concepts-preimport-<stamp>.sql first).
#
#   Instead the installer installs the import job and gives it ONE delayed run,
#   3 hours out by default, after which the daily job below keeps the dictionary
#   current. The delayed run is a transient systemd timer
#   (eregister-concept-import-first.timer), or an `at` job where systemd is
#   absent; if neither exists the daily job simply takes the first import.
#     EREGISTER_CONCEPT_IMPORT_FIRST_RUN=0        No delayed first run.
#     EREGISTER_CONCEPT_IMPORT_FIRST_DELAY_SEC    Delay in seconds (default 10800).
#     EREGISTER_CONCEPTS_SQL_NAME                 Dump filename in the concepts repo.
#   Import it yourself at any time with ./import-concepts.sh — that is also what
#   the scheduled runner calls.
#
#   The job itself is a DAILY one, separate from the form import: it
#   fast-forwards eregister_concepts_release_v1
#   and imports the newest omrs_concept_dictionary_*.sql it holds into the
#   openmrs database, but only when that dump's content differs from the one
#   already loaded (sha256, recorded in <base>/v1/.eregister_concept_import_state).
#   Runner: /usr/local/bin/eregister-concept-import.sh. Control it:
#     EREGISTER_CONCEPT_IMPORT=0            Do not install the job.
#     EREGISTER_CONCEPT_IMPORT_CRON         cron schedule (default '30 4 * * *').
#     EREGISTER_CONCEPT_IMPORT_ONCALENDAR   systemd OnCalendar (default '*-*-* 04:30:00').
#     EREGISTER_CONCEPT_IMPORT_RESTART_EMR=1  restart the EMR after an import
#                                           (off by default: 30+ min downtime).
#
#   After the concept dictionary is in place, the clinical observation forms
#   shipped in the clinical-obs-forms clone are imported into the running EMR
#   over its REST API — the scripted equivalent of clicking "Import" in the
#   Implementer Interface for every form file. The importer
#   (bin/bahmni_form_import.sh) is installed to /usr/local/bin/bahmni-form-import.sh
#   and scheduled to run DAILY so forms pushed to that repo go live on their own.
#   Only forms whose CONTENT changed are deployed (sha256 per form, recorded in
#   <base>/v1/.bahmni_form_import_state.json), and a changed form is deployed as
#   a NEW version rather than overwriting the live one — so a same-named file
#   holding a new export counts as new work, while an unchanged file that was
#   merely re-pulled is skipped. Control it:
#     EREGISTER_IMPORT_FORMS=0         Skip it (same as --no-forms).
#     EREGISTER_BAHMNI_URL/_USER/_PASS EMR endpoint and account (default
#                                      https://localhost, superman; the password
#                                      is prompted when not set).
#     EREGISTER_FORMS_DIR              Folder of form JSON (default the clone).
#     EREGISTER_FORM_IMPORT_ONCALENDAR systemd OnCalendar (default '*-*-* 03:30:00').
#     EREGISTER_FORM_IMPORT_CRON       cron schedule    (default '30 3 * * *').
#   Credentials for the unattended runs live in /etc/eregister/form-import.env
#   (0600). Re-run it on its own at any time with ./import-forms.sh, or
#   sudo /usr/local/bin/eregister-form-import.sh.
#
#   The OpenMRS REPORT DEFINITIONS are cloned but not imported here, for the
#   same reason as the concept dictionary: openmrs_reporting_release ships a
#   mysqldump of the reporting module's serialized_object table — the report,
#   cohort and indicator definitions the Reports app lists — and the database it
#   would go into is minutes old when this script finishes. The clone lands at
#   <base>/v1/openmrs_reporting_release and the auto-pull job keeps it current;
#   ./catch-up.sh does the import, backing the table up first and skipping the
#   work entirely when the dump is already the one in the database.
#     EREGISTER_REF_REPORTING          Its branch (default master).
#     EREGISTER_REPORTING_SQL_NAME     Pin one .sql file in that repo (default:
#                                      every *.sql in it).
#
#   The installer also schedules a DAILY BACKUP of the live v1 database. This is
#   not the pre-upgrade dump in <base>/v1/bahmni-backup — that one is taken once,
#   from the 0.92 stack, and is what the restore reads. This is the rolling
#   backup of the site from here on: it dumps 'openmrs' out of the openmrsdb
#   service, gzips it to <base>/v1/db-backups/openmrs_<stamp>.sql.gz, refuses to
#   keep a dump that mysqldump did not finish writing, and deletes all but the
#   newest 14. It runs at 01:30 — before the auto-pull, the form import and the
#   concept import — so each night's dump predates whatever those did.
#   Script: /usr/local/bin/eregister-db-backup.sh (run it by hand any time).
#     EREGISTER_DB_BACKUP=0            Do not install it (same as --no-db-backup).
#     EREGISTER_DB_BACKUP_CRON         cron schedule (default '30 1 * * *').
#     EREGISTER_DB_BACKUP_ONCALENDAR   systemd OnCalendar (default '*-*-* 01:30:00').
#     EREGISTER_DB_BACKUP_KEEP         how many dumps to retain (default 14).
#     EREGISTER_DB_BACKUP_DIR          where they go (default <base>/v1/db-backups).
#   The dumps sit on the SAME disk as the database, so they protect against a bad
#   import or a deleted record, NOT against losing the machine. Copy that folder
#   off the host as well.
#
#   After a successful upgrade, the installer offers to schedule a job that
#   periodically pulls the v1 asset/config repos (standard-config-ls,
#   implementer-interface-release, openmrs-v1-modules, clinical-obs-forms,
#   dhisconnector_mappings_v1, eregister_concepts_release_v1,
#   openmrs_reporting_release) via a systemd
#   timer, or an /etc/cron.d entry
#   where systemd is absent. Control it:
#     EREGISTER_AUTO_PULL=0            Disable the feature entirely.
#     EREGISTER_AUTO_PULL_ONCALENDAR   systemd OnCalendar (default: '*-*-* 02:30:00').
#     EREGISTER_AUTO_PULL_CRON         cron schedule    (default: '30 2 * * *').
#   The standalone updater is installed to /usr/local/bin/eregister-autopull.sh
#   and can be run by hand for a one-off sync.
#
#   RE-RUNNING AFTER AN INTERRUPTED RUN.
#   <base>/v1/.eregister-upgrade-complete records how far the last run got, not
#   merely that one happened:
#     stage=migrated   the stack was migrated, verified and started, but the
#                      post-install steps (concept import, form import,
#                      auto-updates) had not finished.
#     stage=complete   the whole run finished.
#   Only stage=complete short-circuits with "nothing to do". stage=migrated
#   redoes the upgrade from the top — and the BACKUP ALREADY IN
#   <base>/v1/bahmni-backup is reused, not retaken: it is the 0.92 data the
#   restore needs, and once the old stack has been frozen it cannot be retaken
#   at all. Note that the restore therefore reloads the openmrs database from
#   that file, replacing anything entered since it was made. A marker written by
#   an installer older than this one carries no stage; what is still outstanding
#   is then inferred from what those steps leave on disk (the concept-import
#   state file, the form-import runner).
#
#   ALREADY ON v1? Do not re-run this script to pick up changes made to it since
#   your site was installed — it freezes the old stack, restores a backup and
#   restarts everything. Run ./catch-up.sh instead: it reconciles a live site
#   (repos, helper scripts, both scheduled jobs, the form import) and reports on
#   service health. The only container it touches is the EMR service, which it
#   recreates as its last job so the refreshed config/omods/forms are loaded
#   (--no-recreate skips that); the rest of the stack is left running.
#
# DESIGN NOTES
#   * Modules live under lib/, grouped by concern and sourced by this file:
#       lib/core/    config, logging, traps, prompt, cli
#       lib/system/  platform, privilege, deps
#       lib/upgrade/ verify, detect, backup, migrate, rollback, postinstall,
#                    concepts, forms, autopull, dbbackup
#     Override the lib location with EREGISTER_LIB_DIR (e.g. for system install).
#   * `curl | bash` still works: with no lib/ beside it, the script fetches the
#     modules itself — first by shallow-cloning the repo (which also resolves
#     the remote's default branch), then, failing that, file by file from
#     EREGISTER_RAW_BASE. It only proceeds once EVERY module in the list is
#     present, so a half-published branch is caught here with a message naming
#     the missing file, not with curl's opaque "(56) … error: 404" mid-run.
#     After adding or renaming anything under lib/ or bin/, PUSH IT, then run
#     ./tests/check-published.sh — that is what the one-liners fetch.
#   * ALL logic still lives in functions; main() is called on the LAST line.
#     main() itself only decides whether this run has anything to do (see
#     RE-RUNNING above); the work lives in run_migration and run_post_install.
###############################################################################

set -euo pipefail

# Base raw URL used to self-bootstrap modules when lib/ isn't present locally
# (e.g. when only install.sh was downloaded, or piped via curl | bash).
EREGISTER_RAW_BASE="${EREGISTER_RAW_BASE:-https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main}"
BOOTSTRAP_DIR=""   # temp dir holding downloaded modules; cleaned up on EXIT

# Modules to source, in dependency order (core -> system -> upgrade). Everything
# but config.sh only *defines* functions, so order is otherwise flexible.
EREGISTER_MODULES=(
  core/config.sh
  core/logging.sh
  core/traps.sh
  core/prompt.sh
  core/cli.sh
  system/platform.sh
  system/privilege.sh
  system/deps.sh
  upgrade/verify.sh
  upgrade/detect.sh
  upgrade/backup.sh
  upgrade/migrate.sh
  upgrade/rollback.sh
  upgrade/postinstall.sh
  upgrade/concepts.sh
  upgrade/forms.sh
  upgrade/autopull.sh
  upgrade/dbbackup.sh
)

# -----------------------------------------------------------------------------
# Module bootstrap — obtain lib/ when it isn't sitting next to this script
# (only install.sh was downloaded, or the script was piped into bash).
#
# Two ways in, tried in this order:
#   1. git clone --depth 1 of the repo. One request, always a self-consistent
#      tree, and it resolves the remote's DEFAULT branch by itself — so it keeps
#      working when the branch in EREGISTER_RAW_BASE is renamed or wrong.
#   2. per-file download from the raw host, tried against each ref in
#      EREGISTER_RAW_REFS.
# Either way the tree is only accepted once EVERY required module is present, so
# a half-published branch is rejected here instead of failing mid-upgrade.
#
# Why not a plain `curl -fsSL`: over HTTP/2, `curl -f` reports a missing file as
#   curl: (56) The requested URL returned error: 404
# which names neither the file nor the reason. Every download below checks the
# HTTP status itself and says which URL returned what.
# -----------------------------------------------------------------------------
EREGISTER_REPO="${EREGISTER_REPO:-${EREGISTER_UPGRADE_REPO:-https://github.com/Lesotho-eRegister-v1/upgrade-to-v1}}"
# Branches tried when a module is missing from the configured one. Ordered.
EREGISTER_RAW_REFS="${EREGISTER_RAW_REFS:-main,master}"
# Set when the caller pinned a raw base explicitly; then it is used verbatim and
# no other ref is guessed.
_BOOT_RAW_BASE_PINNED="${EREGISTER_RAW_BASE_PINNED:-0}"
# Every attempt is logged for the failure message. It goes to a FILE, not an
# array: the try-functions below run inside $( ) to hand back the directory they
# found, and a subshell's variables die with it — a file survives.
_BOOT_TRIED_FILE=""

_boot_log()   { printf '%s\n' "$*" >&2; }
_boot_tried() { [ -n "$_BOOT_TRIED_FILE" ] && printf '%s\n' "$*" >>"$_BOOT_TRIED_FILE"; return 0; }

# _boot_raw_base <ref> — the raw URL prefix for one ref, derived from
# EREGISTER_REPO. Empty when the repo isn't on github.com (self-hosted git):
# there is nothing to derive, so only the configured EREGISTER_RAW_BASE is used.
_boot_raw_base() {
  local ref="$1" path="${EREGISTER_REPO%.git}"
  case "$path" in
    https://github.com/*) printf 'https://raw.githubusercontent.com/%s/refs/heads/%s' \
                                 "${path#https://github.com/}" "$ref" ;;
    *) printf '' ;;
  esac
}

# _boot_have_all <dir> — is every required module readable under <dir>?
# Echoes the first missing one on stdout when it isn't.
_boot_have_all() {
  local dir="$1" m
  for m in "${EREGISTER_MODULES[@]}"; do
    if [ ! -r "${dir}/${m}" ]; then printf '%s' "$m"; return 1; fi
  done
  return 0
}

# _boot_try_clone <tmp> — shallow-clone the repo; echoes the lib dir on success.
_boot_try_clone() {
  local tmp="$1" ref missing dest
  command -v git >/dev/null 2>&1 || { _boot_tried "git clone -> git is not installed"; return 1; }
  # "" first = whatever the remote calls its default branch.
  for ref in "" ${EREGISTER_RAW_REFS//,/ }; do
    dest="${tmp}/repo${ref:+-$ref}"
    rm -rf "$dest"
    if [ -z "$ref" ]; then
      git clone --quiet --depth 1 "$EREGISTER_REPO" "$dest" >/dev/null 2>&1 || {
        _boot_tried "git clone ${EREGISTER_REPO} (default branch) -> failed (no network? private repo?)"; continue; }
    else
      git clone --quiet --depth 1 --branch "$ref" "$EREGISTER_REPO" "$dest" >/dev/null 2>&1 || {
        _boot_tried "git clone ${EREGISTER_REPO} --branch ${ref} -> failed (branch missing?)"; continue; }
    fi
    if missing="$(_boot_have_all "${dest}/lib")"; then
      printf '%s' "${dest}/lib"; return 0
    fi
    _boot_tried "git clone ${EREGISTER_REPO} ${ref:-(default branch)} -> cloned OK, but lib/${missing} is not on that branch"
  done
  return 1
}

# _boot_try_raw <tmp> — download every module over HTTP; echoes the lib dir.
_boot_try_raw() {
  local tmp="$1" base ref bases=() m url dest code ok
  command -v curl >/dev/null 2>&1 || { _boot_tried "http download -> curl is not installed"; return 1; }

  if [ "$_BOOT_RAW_BASE_PINNED" = "1" ]; then
    bases=("$EREGISTER_RAW_BASE")
  else
    bases=("$EREGISTER_RAW_BASE")
    for ref in ${EREGISTER_RAW_REFS//,/ }; do
      base="$(_boot_raw_base "$ref")"
      [ -n "$base" ] && [ "$base" != "$EREGISTER_RAW_BASE" ] && bases+=("$base")
    done
  fi

  for base in "${bases[@]}"; do
    [ -n "$base" ] || continue
    dest="${tmp}/raw"
    rm -rf "$dest"; mkdir -p "$dest"
    ok=1
    for m in "${EREGISTER_MODULES[@]}"; do
      url="${base}/lib/${m}"
      mkdir -p "${dest}/$(dirname "$m")"
      # No -f: it hides the status behind curl's own exit code. Check it here.
      code="$(curl -sSL -o "${dest}/${m}" -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
      if [ "$code" != "200" ]; then
        rm -f "${dest}/${m}"
        _boot_tried "${url} -> HTTP ${code}"
        ok=0
        break
      fi
    done
    if [ "$ok" = "1" ]; then printf '%s' "$dest"; return 0; fi
  done
  return 1
}

# _boot_fail — one diagnostic that names the cause instead of a curl exit code.
_boot_fail() {
  local t self repo_name
  self="$(basename "${BASH_SOURCE[0]:-install.sh}")"
  repo_name="$(basename "${EREGISTER_REPO%.git}")"
  _boot_log ""
  _boot_log "FATAL: could not obtain the eRegister modules (lib/)."
  _boot_log "Tried:"
  while IFS= read -r t; do _boot_log "  • ${t}"; done < "${_BOOT_TRIED_FILE:-/dev/null}"
  _boot_log ""
  _boot_log "An HTTP 404 here almost always means one of:"
  _boot_log "  • the file is not pushed to that branch yet — the script you are running"
  _boot_log "    is newer than what is published (commit and push lib/, then retry);"
  _boot_log "  • you pushed in the last few minutes and the raw CDN is still stale;"
  _boot_log "  • the branch does not exist, or the repo is private (raw answers 404,"
  _boot_log "    not 401, for private repos — use a checkout and an SSH key instead)."
  _boot_log ""
  _boot_log "Work around it with a checkout:"
  _boot_log "  git clone ${EREGISTER_REPO}"
  _boot_log "  cd ${repo_name} && ./${self}"
  _boot_log "Or point the scripts at a branch that has the modules:"
  _boot_log "  EREGISTER_RAW_REFS=my-branch   (comma-separated; tried in order)"
  _boot_log "  EREGISTER_RAW_BASE=<raw url>   (used verbatim; set EREGISTER_RAW_BASE_PINNED=1 to stop the guessing)"
  _boot_log ""
  exit 1
}

bootstrap_modules() {
  local tmp lib
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/eregister-lib.XXXXXX")" || exit 1
  BOOTSTRAP_DIR="$tmp"          # cleaned up on EXIT, whichever way we got in
  _BOOT_TRIED_FILE="${tmp}/attempts.log"
  : > "$_BOOT_TRIED_FILE"
  _boot_log "lib/ not found locally — fetching the modules …"
  if lib="$(_boot_try_clone "$tmp")"; then
    _boot_log "Modules obtained by cloning ${EREGISTER_REPO}."
    printf '%s' "$lib"; return 0
  fi
  if lib="$(_boot_try_raw "$tmp")"; then
    _boot_log "Modules downloaded over HTTP."
    printf '%s' "$lib"; return 0
  fi
  _boot_fail
}

# -----------------------------------------------------------------------------
# Module loader — prefer lib/ next to this script; otherwise bootstrap it.
# -----------------------------------------------------------------------------
load_modules() {
  local self_dir lib_dir m
  # When piped (curl | bash) BASH_SOURCE may not be a real path; tolerate that.
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || self_dir=""
  lib_dir="${EREGISTER_LIB_DIR:-${self_dir:+${self_dir}/lib}}"

  if [ -z "$lib_dir" ] || [ ! -d "$lib_dir" ]; then
    lib_dir="$(bootstrap_modules)"
  fi

  for m in "${EREGISTER_MODULES[@]}"; do
    if [ ! -r "${lib_dir}/${m}" ]; then
      # A local lib/ that is missing a module is the same "you are running a
      # newer script than your checkout" problem — say so plainly.
      _boot_log "FATAL: missing module: ${lib_dir}/${m}"
      _boot_log "Your lib/ is older than this script. Update the checkout (git pull),"
      _boot_log "or unset EREGISTER_LIB_DIR to let it fetch a matching set."
      exit 1
    fi
    # shellcheck source=/dev/null
    . "${lib_dir}/${m}"
  done
}

# =============================================================================
# main — the single entrypoint (no top-level work happens before this is called)
# =============================================================================
# run_migration — everything that changes the machine: dependencies, the backup,
# freezing the 0.92 stack, cloning v1, the restore, the start and the verify.
# Every step is individually confirmed, and declining rolls back once the old
# stack has been frozen. Ends with the marker at stage=migrated.
# =============================================================================
run_migration() {
  # --- overall go/no-go (each step below is also confirmed individually) --
  warn "Cautious mode: you will be asked to confirm EVERY step before it runs."
  warn "Answer 'n' at any prompt to stop safely (with rollback if the old stack"
  warn "has already been frozen). Anything that is neither a yes nor a no is"
  warn "treated as a slip: the prompt asks whether you meant to stop, and repeats"
  warn "itself if you did not. Use --yes to auto-confirm all steps."
  if ! confirm "Begin the upgrade ${CURRENT_VERSION_DEFAULT} -> ${TARGET_VERSION}?" \
                "quit without upgrading anything"; then
    error "Aborted by user."
    exit 1
  fi

  # --- dependencies -------------------------------------------------------
  confirm_step "Check for, and install if missing, required dependencies (git, docker, …)"
  ensure_deps

  # --- temp workspace + scaffolding --------------------------------------
  confirm_step "Create the temp workspace and the v1 folders under ${INSTALL_BASE}"
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/eregister-v1.XXXXXX")"
  info "Working dir: ${WORKDIR}"
  step "Preparing directories"
  ensure_dir "$V1_DIR" "v1 folder"
  ensure_dir "$BACKUP_DIR" "bahmni-backup folder"

  # --- backup BEFORE touching anything ------------------------------------
  # A dump already sitting in BACKUP_DIR wins. It is the 0.92 data the restore
  # needs, and after an earlier run has frozen the old stack it cannot be
  # retaken at all — so it is REUSED rather than the run being written off as a
  # fresh install with nothing to migrate. A new dump is taken only when the
  # 0.92 EMR container is actually running and we do not already hold one (or
  # --force says to replace it). Resolving the container inside that branch also
  # avoids prompting for a DB password we would never use, which would abort a
  # --yes/CI run at prompt_db_password before we ever reach take_backup.
  step "Backup"
  local backup_size=""
  if [ -s "$BACKUP_SQL" ]; then
    backup_size="$(as_root du -h "$BACKUP_SQL" 2>/dev/null | awk '{print $1}' || true)"
    [ -n "$backup_size" ] && backup_size=" (${backup_size})"
  fi

  if [ -s "$BACKUP_SQL" ] && [ "$FORCE" != "1" ]; then
    success "Reusing the backup already in ${BACKUP_DIR}:"
    success "  ${BACKUP_SQL}${backup_size}"
    info "The restore below loads THIS file. To retake it instead, re-run with"
    info "--force while the ${CURRENT_VERSION_DEFAULT} EMR container is running."
  elif resolve_emr_container; then
    confirm_step "Take a MySQL backup of '${DB_NAME}' from container ${EMR_CONTAINER} into ${BACKUP_SQL}"
    prompt_db_password
    take_backup
  elif [ -s "$BACKUP_SQL" ]; then
    # --force asked for a fresh dump, but the 0.92 stack is gone — most likely
    # frozen by an earlier run of this very script. The dump we already hold is
    # still exactly the right input for the restore.
    warn "--force asked for a fresh backup, but no running ${CURRENT_VERSION_DEFAULT} EMR container was found."
    success "Reusing the backup already in ${BACKUP_DIR}: ${BACKUP_SQL}${backup_size}"
  else
    warn "No running EMR container to back up, and no backup in ${BACKUP_DIR} —"
    warn "continuing as a fresh install (nothing to migrate)."
    BACKUP_SKIPPED="1"
  fi

  # --- stop old stack (rollback armed from here) --------------------------
  step "Migration"
  confirm_step "Freeze (stop, not remove) the running ${CURRENT_VERSION_DEFAULT} stack at ${OLD_DOCKER_DIR}"
  shutdown_old_stack

  # --- bring in v1 sources & 0.92 config ----------------------------------
  confirm_step "Clone the v1 source repos, asset repos and 0.92 config into ${V1_DIR}"
  fetch_repos

  # --- restore data into v1 ----------------------------------------------
  confirm_step "Run restore_bahmni_standard.sh to load the backup into the v1 stack"
  run_restore

  # --- start the v1 stack -------------------------------------------------
  confirm_step "Start eRegister ${TARGET_VERSION} via run-bahmni.sh (falls back to '${DOCKER_COMPOSE} up -d' on error)"
  start_v1_stack

  # --- verify & mark the migration done -----------------------------------
  # post_verify records stage=migrated, NOT a finished install: the steps in
  # run_post_install below still have to happen, and they take long enough to be
  # interrupted. A resumable marker is what lets the next run pick them up
  # instead of short-circuiting on "already installed".
  confirm_step "Run post-install verification and finalize the upgrade"
  post_verify
  UPGRADE_COMPLETE="1"   # disarms rollback in the error trap
}

# =============================================================================
# run_post_install — the long tail of the install: the concept dictionary, the
# clinical forms and the auto-update job, each with its own schedule.
#
# The migration is already finalized before any of this runs, so every step here
# is ADVISORY: a failure warns and names the standalone script that redoes it,
# and none of them can abort the run or trigger a rollback. Runs both at the end
# of a fresh upgrade and on its own when a previous run was interrupted here.
# =============================================================================
run_post_install() {
  # --- the daily database backup ------------------------------------------
  # FIRST, deliberately. Everything else in this function installs something
  # that will later write to the openmrs database on a schedule — the concept
  # dictionary replaces whole tables, the form import creates form versions. The
  # job that lets a site undo any of that should be in place before those jobs
  # are, not after.
  if ! install_db_backup; then
    warn "Daily database backup NOT installed. Add it later with ./catch-up.sh,"
    warn "or by re-running the installer with --force."
  fi

  # --- the concept dictionary ---------------------------------------------
  # NOT imported here. The stack has only just been started: openmrsdb answers
  # early, but the instance behind it needs 30+ minutes — often hours on site
  # hardware — before importing a dictionary is worth doing. Doing it inline
  # therefore either blocked the run or skipped for nothing, and either way it
  # asked the operator to authorise replacing the concept_*/drug* tables at the
  # least informative possible moment.
  #
  # So: install the job, give it ONE delayed run a few hours out
  # (CONCEPT_IMPORT_FIRST_DELAY_SEC), and let the daily job carry on from there.
  # ./import-concepts.sh still imports on demand, whenever you want it.
  if ! install_concept_import; then
    warn "Scheduled concept import NOT installed. Add it later with: ./import-concepts.sh --schedule"
  fi

  # --- import the clinical observation forms ------------------------------
  # This installs the importer, deploys the forms once, and schedules the daily
  # job.
  if ! install_form_import; then
    warn "Clinical forms NOT imported. Run it again later with: ./import-forms.sh"
  fi

  # --- schedule automatic repo updates ------------------------------------
  # Declining here is NOT an abort: the upgrade is already done, so this is a
  # plain confirm (not confirm_step, which would roll back / exit). Honors
  # --yes and EREGISTER_AUTO_PULL=0. The '|| warn' matters as much as the rest:
  # without it an errexit on the very last step would kill the run just before
  # the summary is printed.
  if [ "$AUTO_PULL" = "1" ] && confirm "Install the auto-update job that periodically pulls the v1 asset/config repos?"; then
    install_auto_pull || warn "Auto-update job NOT installed. Add it later by re-running with --force."
  else
    info "Skipping auto-update scheduling. Enable it later by re-running with --force, or add your own cron/timer entry for ${AUTO_PULL_SCRIPT}."
  fi
}

# =============================================================================
# main — the single entrypoint (no top-level work happens before this is called)
# =============================================================================
main() {
  load_modules        # bring in all module functions/config before anything else

  parse_args "$@"
  setup_colors
  install_traps
  banner

  # --- discovery (read-only) ---------------------------------------------
  detect_platform
  detect_pkg_mgr
  resolve_config
  detect_privilege
  print_config

  # --- idempotency guard --------------------------------------------------
  # The marker says how far the last run got, so there are three cases, not two.
  # The one that used to be missing is the middle one: a run that migrated the
  # stack but was interrupted before the post-install steps finished. Treating
  # that as "already installed" is what made the installer print a summary of
  # work it had not done and exit without finishing the outstanding steps.
  INSTALL_STAGE="$(resolve_install_stage)"
  if [ -n "$INSTALL_STAGE" ] && [ "$FORCE" = "1" ]; then
    warn "--force: redoing the whole upgrade even though the marker records stage=${INSTALL_STAGE}."
    INSTALL_STAGE=""
  fi

  if [ "$INSTALL_STAGE" = "complete" ]; then
    SUMMARY_MODE="existing"
    success "${APP_NAME} ${TARGET_VERSION} is already installed (${DONE_MARKER}). Nothing to do."
    info "To pick up later changes to these scripts on a live site, run ./catch-up.sh."
    info "To redo the whole upgrade from the backup in ${BACKUP_DIR}, re-run with --force."
    next_steps
    exit 0
  fi

  if [ "$INSTALL_STAGE" = "migrated" ]; then
    warn "A previous run migrated the stack but stopped before the post-install"
    warn "steps finished (${DONE_MARKER} records stage=migrated)."
    warn "This run redoes the upgrade from the top. The backup already in"
    warn "${BACKUP_DIR} is REUSED, not retaken — and the restore reloads"
    warn "'${DB_NAME}' from it, replacing anything entered since it was made."
  fi

  SUMMARY_MODE="upgrade"
  run_migration
  run_post_install

  # Only now is the install actually finished.
  mark_stage complete
  next_steps
  success "Done."
}

main "$@"
