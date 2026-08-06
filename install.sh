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
#                [--no-concepts] [--help]
#
# FLAGS / ENV
#   -y, --yes            Non-interactive; assume "yes" to all prompts (CI/automation).
#                        Also enabled with: EREGISTER_ASSUME_YES=1
#   --force              Re-run upgrade even if a completed v1 marker exists.
#   --install-dir DIR    Override install base (default: /var/lib).
#   --target-ref REF[,REF...]
#                        Git ref(s)/tag(s)/commit(s) to check out for the repos.
#                        Tried in order against each repo; the first one that
#                        exists on that remote wins, and the repo's own default
#                        ref is the last resort. The repos do not share a branch
#                        name, so a list is usually what you want:
#                          --target-ref Bokang-changes,main
#                        Default: empty (each repo uses its own default ref).
#   --no-concepts        Skip the post-install concept-dictionary import.
#   --no-color           Disable ANSI colors.
#   -h, --help           Show help and exit.
#
#   After the v1 stack starts, the concept dictionary shipped in
#   eregister_concepts_release_v1 (omrs_concept_dictionary_v1.sql) is imported
#   into the 'openmrs' database of the openmrsdb container. It replaces the
#   concept_*/drug* tables, so the tables it touches are dumped to
#   <base>/v1/bahmni-backup/concepts-preimport-<stamp>.sql first. Control it:
#     EREGISTER_IMPORT_CONCEPTS=0      Skip it (same as --no-concepts).
#     EREGISTER_CONCEPTS_SQL_NAME      Dump filename inside the concepts repo.
#     EREGISTER_CONCEPTS_DB_WAIT       Seconds to wait for openmrsdb (default 300).
#   Re-run it on its own at any time with ./import-concepts.sh.
#
#   After a successful upgrade, the installer offers to schedule a job that
#   periodically pulls the v1 asset/config repos (standard-config-ls,
#   implementer-interface-release, openmrs-v1-modules, clinical-obs-forms,
#   dhisconnector_mappings_v1, eregister_concepts_release_v1) via a systemd
#   timer, or an /etc/cron.d entry
#   where systemd is absent. Control it:
#     EREGISTER_AUTO_PULL=0            Disable the feature entirely.
#     EREGISTER_AUTO_PULL_ONCALENDAR   systemd OnCalendar (default: '*-*-* 02:30:00').
#     EREGISTER_AUTO_PULL_CRON         cron schedule    (default: '30 2 * * *').
#   The standalone updater is installed to /usr/local/bin/eregister-autopull.sh
#   and can be run by hand for a one-off sync.
#
# DESIGN NOTES
#   * Modules live under lib/, grouped by concern and sourced by this file:
#       lib/core/    config, logging, traps, prompt, cli
#       lib/system/  platform, privilege, deps
#       lib/upgrade/ verify, detect, backup, migrate, rollback, postinstall,
#                    concepts, autopull
#     Override the lib location with EREGISTER_LIB_DIR (e.g. for system install).
#   * Because functions now live in separate files, this is NO LONGER safe to
#     `curl | bash` directly — clone/download the whole repo and run ./install.sh.
#     (To regain a single pipe-able file, concatenate lib/**/*.sh + main; see
#     the build note at the end of this repo's README.)
#   * ALL logic still lives in functions; main() is called on the LAST line.
###############################################################################

set -euo pipefail

# Base raw URL used to self-bootstrap modules when lib/ isn't present locally
# (e.g. when only install.sh was downloaded, or piped via curl | bash).
EREGISTER_RAW_BASE="${EREGISTER_RAW_BASE:-https://raw.githubusercontent.com/eRegister/upgrade-to-v1/refs/heads/main}"
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
  upgrade/autopull.sh
)

# -----------------------------------------------------------------------------
# bootstrap_modules — download all modules into a temp dir when lib/ is absent.
# Echoes the temp dir path on stdout; logs to stderr (loggers aren't loaded yet).
# -----------------------------------------------------------------------------
bootstrap_modules() {
  local tmp m url
  command -v curl >/dev/null 2>&1 || { printf 'FATAL: curl required to fetch modules.\n' >&2; return 1; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/eregister-lib.XXXXXX")" || return 1
  printf 'lib/ not found locally — downloading modules from %s …\n' "$EREGISTER_RAW_BASE" >&2
  for m in "${EREGISTER_MODULES[@]}"; do
    mkdir -p "${tmp}/$(dirname "$m")"
    url="${EREGISTER_RAW_BASE}/lib/${m}"
    if ! curl -fsSL "$url" -o "${tmp}/${m}"; then
      printf 'FATAL: could not download module: %s\n' "$url" >&2
      rm -rf "$tmp"
      return 1
    fi
  done
  printf '%s' "$tmp"
}

# -----------------------------------------------------------------------------
# Module loader — prefer lib/ next to this script; otherwise self-bootstrap.
# -----------------------------------------------------------------------------
load_modules() {
  local self_dir lib_dir m
  # When piped (curl | bash) BASH_SOURCE may not be a real path; tolerate that.
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || self_dir=""
  lib_dir="${EREGISTER_LIB_DIR:-${self_dir:+${self_dir}/lib}}"

  if [ -z "$lib_dir" ] || [ ! -d "$lib_dir" ]; then
    lib_dir="$(bootstrap_modules)" || exit 1
    BOOTSTRAP_DIR="$lib_dir"   # mark for cleanup (see cleanup() in traps.sh)
  fi

  for m in "${EREGISTER_MODULES[@]}"; do
    if [ ! -r "${lib_dir}/${m}" ]; then
      printf 'FATAL: missing module: %s/%s\n' "$lib_dir" "$m" >&2
      exit 1
    fi
    # shellcheck source=/dev/null
    . "${lib_dir}/${m}"
  done
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
  if [ -f "$DONE_MARKER" ] && [ "$FORCE" != "1" ]; then
    success "${APP_NAME} ${TARGET_VERSION} already installed (${DONE_MARKER}). Nothing to do."
    success "Re-run with --force to redo the upgrade."
    next_steps
    exit 0
  fi

  # --- overall go/no-go (each step below is also confirmed individually) --
  warn "Cautious mode: you will be asked to confirm EVERY step before it runs."
  warn "Answer 'n' at any prompt to stop safely (with rollback if the old stack"
  warn "has already been frozen). Use --yes to auto-confirm all steps."
  if ! confirm "Begin the upgrade ${CURRENT_VERSION_DEFAULT} -> ${TARGET_VERSION}?"; then
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
  # Resolve a running EMR container first (configured name, then the known
  # alternate, then ask the user). Only when one is found do we run the backup
  # and its password prompt — with no container there is nothing to dump, so we
  # treat it as a fresh install and skip straight on. Resolving up front also
  # avoids prompting for a DB password we would never use (which would abort a
  # --yes/CI run at prompt_db_password before we ever reach take_backup).
  step "Backup"
  if resolve_emr_container; then
    confirm_step "Take a MySQL backup of '${DB_NAME}' from container ${EMR_CONTAINER} into ${BACKUP_SQL}"
    prompt_db_password
    take_backup
  else
    warn "No running EMR container to back up — continuing as a fresh install (nothing to migrate)."
    warn "However, if at a later stage I find the back in ${eRegister_HOME}, i'll use it  ."
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

  # --- verify & finish ----------------------------------------------------
  confirm_step "Run post-install verification and finalize the upgrade"
  post_verify
  UPGRADE_COMPLETE="1"   # disarms rollback in the error trap

  # --- load the v1 concept dictionary (optional, post-completion) ---------
  # The upgrade is already finalized here, so this is advisory: a failure warns
  # and points at the standalone runner rather than aborting or rolling back.
  # Needs only openmrsdb, which is up well before the EMR finishes booting.
  if ! import_concepts; then
    warn "Concept dictionary NOT imported. Run it again later with: ./import-concepts.sh"
  fi

  # --- schedule automatic repo updates (optional, post-completion) --------
  # Declining here is NOT an abort: the upgrade is already done, so this is a
  # plain confirm (not confirm_step, which would roll back / exit). Honors
  # --yes and EREGISTER_AUTO_PULL=0.
  if [ "$AUTO_PULL" = "1" ] && confirm "Install the auto-update job that periodically pulls the v1 asset/config repos?"; then
    install_auto_pull
  else
    info "Skipping auto-update scheduling. Enable it later by re-running with --force, or add your own cron/timer entry for ${AUTO_PULL_SCRIPT}."
  fi

  next_steps
  success "Done."
}

main "$@"
