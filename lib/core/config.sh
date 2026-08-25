# shellcheck shell=bash
# =============================================================================
# lib/core/config.sh — defaults & resolved configuration
# Overridable via flags (see lib/core/cli.sh) or environment variables.
# Sourced by install.sh; sets module-global variables at source time.
# =============================================================================
APP_NAME="eRegister Lesotho"
CURRENT_VERSION_DEFAULT="0.92"        # assumed version of an existing install
TARGET_VERSION="v1"

INSTALL_BASE="${EREGISTER_INSTALL_BASE:-/var/lib}"   # default install dir
# Global ref override: a comma-separated preference list tried against EVERY
# repo, in order, falling back to that repo's default ref below if none exist.
# Because the repos don't share a branch name, "Bokang-changes,main" resolves to
# Bokang-changes on the stack repos and main on the asset repos.
# Empty = use the per-repo defaults below.
TARGET_REF="${EREGISTER_TARGET_REF:-}"
ASSUME_YES="${EREGISTER_ASSUME_YES:-0}"
FORCE="0"
USE_COLOR="auto"

# Existing (0.92) deployment layout
OLD_DOCKER_DIR="${EREGISTER_OLD_DOCKER_DIR:-${HOME}/bahmni_docker}"
EMR_CONTAINER="${EREGISTER_EMR_CONTAINER:-bahmni_docker-emr-service-1}"
# Fallback container name tried when EMR_CONTAINER isn't running. Some
# deployments name the service with underscores instead of the compose default
# (hyphen). If neither is up, the installer asks the user for the name.
EMR_CONTAINER_ALT="${EREGISTER_EMR_CONTAINER_ALT:-bahmni_docker_emr_service_1}"

# OpenMRS DB credentials (used inside the running EMR container for the dump).
# The password is NOT hard-coded: it is prompted interactively at runtime, or
# taken from EREGISTER_DB_PASS for non-interactive/CI use.
DB_NAME="${EREGISTER_DB_NAME:-openmrs}"
DB_USER="${EREGISTER_DB_USER:-root}"
DB_PASS="${EREGISTER_DB_PASS:-}"

# v1 (target) stack — compose service names + the OCL config dir *inside* the
# EMR service. Used by the post-startup OCL concept-name fix (ocl-fix.sh).
# The v1 DB password is normally the container's own MYSQL_ROOT_PASSWORD; set
# EREGISTER_DB_PASS only if it differs.
DB_SERVICE="${EREGISTER_DB_SERVICE:-openmrsdb}"
EMR_SERVICE="${EREGISTER_EMR_SERVICE:-openmrs}"
OCL_DIR="${EREGISTER_OCL_DIR:-/openmrs/data/configuration/ocl}"
# Reports runs as its own compose service (often behind a 'reports' profile);
# started explicitly after the main stack comes up.
REPORTS_SERVICE="${EREGISTER_REPORTS_SERVICE:-reports}"

# --- Concept dictionary import ----------------------------------------------
# After the v1 stack is up, the concept dictionary shipped in the
# eregister_concepts_release_v1 clone is loaded into the 'openmrs' database of
# the openmrsdb service. See lib/upgrade/concepts.sh.
IMPORT_CONCEPTS="${EREGISTER_IMPORT_CONCEPTS:-1}"     # 0 (or --no-concepts) disables it
# Which dump inside the concepts repo to import. The repo's own tooling names
# each release with a timestamp — run_concept_dump.sh writes
# omrs_concept_dictionary_$(date +%Y%m%d_%H%M%S).sql — so there is no fixed
# filename to pin: today's is omrs_concept_dictionary_20260804.sql, and the next
# release lands beside it under a new name. Leave CONCEPTS_SQL_NAME EMPTY to
# pick the newest file matching CONCEPTS_SQL_PATTERN (the normal case); set it
# to pin one exact filename.
CONCEPTS_SQL_NAME="${EREGISTER_CONCEPTS_SQL_NAME:-}"
CONCEPTS_SQL_PATTERN="${EREGISTER_CONCEPTS_SQL_PATTERN:-omrs_concept_dictionary*.sql}"
# Raw base for self-bootstrapping the standalone helpers (kept in sync with the
# same default in install.sh / ocl-fix.sh / import-concepts.sh).
RAW_BASE="${EREGISTER_RAW_BASE:-https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main}"

# --- Clinical observation form import ---------------------------------------
# The clinical-obs-forms clone holds Bahmni Form Builder JSON exports. They are
# deployed over the REST API by bin/bahmni_form_import.sh — the scripted
# equivalent of the Implementer Interface's "Import" button — once at the end of
# the upgrade and DAILY thereafter. See lib/upgrade/forms.sh.
IMPORT_FORMS="${EREGISTER_IMPORT_FORMS:-1}"           # 0 (or --no-forms) disables it
# EMR endpoint and account the importer authenticates with. The password is NOT
# hard-coded: it is prompted at runtime, or taken from EREGISTER_BAHMNI_PASS for
# non-interactive/CI use, and stored 0600 in FORM_IMPORT_ENV for the daily job.
BAHMNI_URL="${EREGISTER_BAHMNI_URL:-https://localhost}"
BAHMNI_USER="${EREGISTER_BAHMNI_USER:-superman}"
BAHMNI_PASS="${EREGISTER_BAHMNI_PASS:-${BAHMNI_PASS:-}}"
# The stack ships a self-signed certificate, so curl needs -k by default.
FORM_IMPORT_INSECURE="${EREGISTER_FORM_IMPORT_INSECURE:-1}"
# Where the importer, the scheduled wrapper, its credentials, its log and its
# scratch dir live, plus the unit/file basename shared by the systemd units and
# the cron.d file.
FORM_IMPORT_SCRIPT="${EREGISTER_FORM_IMPORT_SCRIPT:-/usr/local/bin/bahmni-form-import.sh}"
FORM_IMPORT_RUNNER="${EREGISTER_FORM_IMPORT_RUNNER:-/usr/local/bin/eregister-form-import.sh}"
FORM_IMPORT_ENV="${EREGISTER_FORM_IMPORT_ENV:-/etc/eregister/form-import.env}"
FORM_IMPORT_LOG="${EREGISTER_FORM_IMPORT_LOG:-/var/log/eregister-form-import.log}"
FORM_IMPORT_UNIT="${EREGISTER_FORM_IMPORT_UNIT:-eregister-form-import}"
# Daily, deliberately AFTER the auto-pull run (02:30) so each night's import
# sees the forms that were pulled the same night.
FORM_IMPORT_ONCALENDAR="${EREGISTER_FORM_IMPORT_ONCALENDAR:-*-*-* 03:30:00}"
FORM_IMPORT_CRON="${EREGISTER_FORM_IMPORT_CRON:-30 3 * * *}"
# The scheduled runner refreshes the clinical-obs-forms clone itself before
# importing, so the daily import still picks up new forms on a host where
# auto-pull was declined. Set to 0 to import strictly what is on disk.
FORM_IMPORT_SELF_PULL="${EREGISTER_FORM_IMPORT_SELF_PULL:-1}"

# --- Scheduled concept-dictionary import ------------------------------------
# A job of its own, separate from the daily form import: it keeps the
# eregister_concepts_release_v1 clone current and imports the dump it holds into
# the 'openmrs' database of the openmrsdb container — but only when the dump has
# actually changed since the last import (sha256, recorded in
# CONCEPT_IMPORT_STATE). See lib/upgrade/concepts.sh.
CONCEPT_IMPORT="${EREGISTER_CONCEPT_IMPORT:-1}"       # 0 disables the job
CONCEPT_IMPORT_RUNNER="${EREGISTER_CONCEPT_IMPORT_RUNNER:-/usr/local/bin/eregister-concept-import.sh}"
CONCEPT_IMPORT_LOG="${EREGISTER_CONCEPT_IMPORT_LOG:-/var/log/eregister-concept-import.log}"
CONCEPT_IMPORT_UNIT="${EREGISTER_CONCEPT_IMPORT_UNIT:-eregister-concept-import}"
# Daily, after the auto-pull (02:30) and the form import (03:30) — the three
# jobs are independent, but this order means each sees the night's fresh repos.
CONCEPT_IMPORT_ONCALENDAR="${EREGISTER_CONCEPT_IMPORT_ONCALENDAR:-*-*-* 04:30:00}"
CONCEPT_IMPORT_CRON="${EREGISTER_CONCEPT_IMPORT_CRON:-30 4 * * *}"
# The runner refreshes the concepts clone itself before looking at it, so the job
# still works on a host where auto-pull was declined. 0 = import what is on disk.
CONCEPT_IMPORT_SELF_PULL="${EREGISTER_CONCEPT_IMPORT_SELF_PULL:-1}"
# The FIRST import is deferred rather than done inline at the end of the upgrade.
# A stack that has just been started is not ready for it: openmrsdb answers long
# before the EMR is up, but the dictionary only makes sense once the instance has
# finished booting and the OCL import has run — hours, not minutes, on the
# hardware these sites use. So the installer schedules one delayed run and lets
# the daily job take over from there. 0 = no delayed run (the daily job is then
# the first one). The delay is in SECONDS so every backend can use it verbatim.
CONCEPT_IMPORT_FIRST_RUN="${EREGISTER_CONCEPT_IMPORT_FIRST_RUN:-1}"
CONCEPT_IMPORT_FIRST_DELAY_SEC="${EREGISTER_CONCEPT_IMPORT_FIRST_DELAY_SEC:-10800}"   # 3h
# OpenMRS caches concepts, so a fresh dictionary is invisible until the EMR is
# restarted. Off by default: that is 30+ minutes of downtime, which is not a
# thing to do unattended without saying so. When 0, the log and the catch-up
# report say a restart is pending.
CONCEPT_IMPORT_RESTART_EMR="${EREGISTER_CONCEPT_IMPORT_RESTART_EMR:-0}"

# --- Catch-up / reconcile (catch-up.sh) -------------------------------------
# catch-up.sh re-checks everything install.sh is meant to have set up and redoes
# only what is missing or out of date. Its checks are read-only; the one thing it
# acts on is the EMR service, recreated as the last job (see CATCHUP_RECREATE_EMR
# below). See lib/upgrade/catchup.sh.
# Update bahmni-docker-ls (the stack itself) along with the asset repos. The
# files change on disk only — nothing is restarted — so the new compose/config
# takes effect at the site's next maintenance window.
CATCHUP_STACK_REPO="${EREGISTER_CATCHUP_STACK_REPO:-1}"
# Query the openmrs DB for a concept count in the health report (read-only).
CATCHUP_DB_CHECK="${EREGISTER_CATCHUP_DB_CHECK:-1}"
# Seconds each HTTP health probe may take before it is called unreachable.
CATCHUP_HTTP_TIMEOUT="${EREGISTER_CATCHUP_HTTP_TIMEOUT:-15}"
# Final job of a catch-up run: recreate the EMR service so it picks up the
# config, omods and forms that were just refreshed —
#   docker compose up -d --force-recreate --renew-anon-volumes <EMR_SERVICE>
# This is the ONE part of catch-up that touches a running container: the EMR
# goes down and needs its usual 30+ minutes to come back, and the service's
# ANONYMOUS volumes are discarded and re-seeded (named volumes, and the separate
# openmrsdb service, are untouched). 0 (or --no-recreate) skips it.
CATCHUP_RECREATE_EMR="${EREGISTER_CATCHUP_RECREATE:-1}"
# Bring dependency repos onto their pinned ref even when they carry uncommitted
# local changes or sit on another branch — i.e. `git checkout -f` + `reset
# --hard`, DISCARDING that work. Off by default: sites do hand-edit config, and
# silently throwing that away is the one destructive thing catch-up could do.
CATCHUP_FORCE_REPOS="${EREGISTER_CATCHUP_FORCE_REPOS:-0}"

# --- Auto-update (periodic git pull of the v1 asset/config repos) ------------
# After a successful upgrade, a scheduled job keeps the asset/config repos
# (standard-config-ls, implementer-interface-release, openmrs-v1-modules,
# clinical-obs-forms, dhisconnector_mappings_v1, eregister_concepts_release_v1)
# in sync with their remotes.
# Implemented as a systemd timer
# where systemd is available, else an /etc/cron.d entry. See lib/upgrade/autopull.sh.
AUTO_PULL="${EREGISTER_AUTO_PULL:-1}"                 # 0 disables the whole feature
# Schedule. systemd uses OnCalendar; cron uses a 5-field crontab expression.
# Defaults are kept roughly equivalent (daily at 02:30, local time).
AUTO_PULL_ONCALENDAR="${EREGISTER_AUTO_PULL_ONCALENDAR:-*-*-* 02:30:00}"
AUTO_PULL_CRON="${EREGISTER_AUTO_PULL_CRON:-30 2 * * *}"
# Where the standalone updater is installed, where it logs, and the unit/file
# basename shared by the systemd units and the cron.d file.
AUTO_PULL_SCRIPT="${EREGISTER_AUTO_PULL_SCRIPT:-/usr/local/bin/eregister-autopull.sh}"
AUTO_PULL_LOG="${EREGISTER_AUTO_PULL_LOG:-/var/log/eregister-autopull.log}"
AUTO_PULL_UNIT="${EREGISTER_AUTO_PULL_UNIT:-eregister-autopull}"

# Source repositories
# This repo (the installer itself). catch-up.sh keeps a checkout at
# UPGRADE_REPO_DIR and updates it before doing anything else, so a site always
# reconciles against the latest version of these scripts.
REPO_UPGRADE="${EREGISTER_UPGRADE_REPO:-https://github.com/Lesotho-eRegister-v1/upgrade-to-v1}"
REF_UPGRADE="${EREGISTER_UPGRADE_REF:-main}"
REPO_BAHMNI_DOCKER="https://github.com/Lesotho-eRegister-v1/bahmni-docker-ls"
REPO_STANDARD_CONFIG="https://github.com/Lesotho-eRegister-v1/standard-config-ls"
REPO_CONFIG_092="https://github.com/eRegister/bahmni_config092"
# v1 assets cloned alongside the stack under <base>/v1: OpenMRS omods, the
# implementer-interface build, and the clinical observation form definitions.
REPO_OPENMRS_MODULES="https://github.com/Lesotho-eRegister-v1/openmrs-v1-modules"
REPO_IMPL_INTERFACE="https://github.com/Lesotho-eRegister-v1/implementer-interface-release"
REPO_OBS_FORMS="https://github.com/Lesotho-eRegister-v1/clinical-obs-forms"
# DHIS2 connector mappings — content that keeps changing after deployment, so
# it is cloned with the other assets and kept in sync by the auto-pull job.
REPO_DHIS_MAPPINGS="https://github.com/Lesotho-eRegister-v1/dhisconnector_mappings_v1"
# Concept dictionary release — also evolves after deployment, so it is cloned
# with the other assets and kept in sync by the auto-pull job.
REPO_CONCEPTS="https://github.com/Lesotho-eRegister-v1/eregister_concepts_release_v1"

# Per-repo git refs (branch/tag/sha). The Lesotho repos have no 'main' branch;
# their v1 line lives on 'Bokang-changes'. config092 uses 'main'.
# A non-empty TARGET_REF (global override) supersedes all of these.
REF_BAHMNI_DOCKER="${EREGISTER_REF_BAHMNI_DOCKER:-Bokang-changes}"
REF_STANDARD_CONFIG="${EREGISTER_REF_STANDARD_CONFIG:-Bokang-changes}"
REF_CONFIG_092="${EREGISTER_REF_CONFIG_092:-main}"
# The three asset repos below do publish 'main'.
REF_OPENMRS_MODULES="${EREGISTER_REF_OPENMRS_MODULES:-main}"
REF_IMPL_INTERFACE="${EREGISTER_REF_IMPL_INTERFACE:-main}"
REF_OBS_FORMS="${EREGISTER_REF_OBS_FORMS:-main}"
# dhisconnector_mappings_v1 has no 'main'; its default branch is 'master'.
REF_DHIS_MAPPINGS="${EREGISTER_REF_DHIS_MAPPINGS:-master}"
# eregister_concepts_release_v1 publishes 'main'.
REF_CONCEPTS="${EREGISTER_REF_CONCEPTS:-main}"

# Derived paths (finalized in resolve_config once INSTALL_BASE is known)
V1_DIR=""             # <base>/v1
eRegister_HOME=""     # exported alias of V1_DIR, for child processes/scripts
BACKUP_DIR=""         # <base>/v1/bahmni-backup
BACKUP_SQL=""         # <base>/v1/bahmni-backup/openmrsdb_backup.sql
DONE_MARKER=""        # <base>/v1/.eregister-upgrade-complete
RESTORE_DIR=""        # <base>/v1/bahmni-docker-ls/bahmni-standard
CONCEPTS_DIR=""       # <base>/v1/eregister_concepts_release_v1
CONCEPTS_SQL=""       # <base>/v1/eregister_concepts_release_v1/<CONCEPTS_SQL_NAME>
FORMS_DIR=""          # <base>/v1/clinical-obs-forms  (the JSON form exports)
FORM_IMPORT_STATE=""  # <base>/v1/.bahmni_form_import_state.json (per-form sha256+version)
FORM_IMPORT_WORKDIR="" # <base>/v1/form-import  (importErrors.txt from unattended runs)
UPGRADE_REPO_DIR=""   # <base>/v1/upgrade-to-v1  (this repo, kept current by catch-up.sh)
CONCEPT_IMPORT_STATE="" # <base>/v1/.eregister_concept_import_state (sha256 of the imported dump)

# Runtime state (for rollback) — touched as the upgrade progresses
WORKDIR=""
OS=""
ARCH=""
PKG_MGR=""
SUDO=""
DOCKER_COMPOSE=""     # "docker compose" or "docker-compose"
OLD_STACK_STOPPED="0"
UPGRADE_COMPLETE="0"
# Set to 1 when the DB backup is skipped because no old EMR container was
# running (i.e. a fresh install with nothing to migrate). Downstream steps
# (restore, verify) read this to demote their own failures to warnings.
BACKUP_SKIPPED="0"
# Set by the concept import to the pre-import dump it took, so a failure can
# point at the file that undoes it.
CONCEPTS_PREIMPORT_SQL=""
# What THIS run actually did — read by next_steps, which is printed after three
# different kinds of run and must not report work it did not do.
#   SUMMARY_MODE      upgrade | existing (see next_steps)
#   INSTALL_STAGE     the stage the marker recorded on entry: "" | migrated | complete
#   STACK_STARTED     1 once start_v1_stack has brought the stack up in this run
#   CONCEPTS_IMPORTED 1 once a dictionary has actually been loaded in this run
SUMMARY_MODE="upgrade"
INSTALL_STAGE=""
STACK_STARTED="0"
CONCEPTS_IMPORTED="0"
