#!/usr/bin/env bash
###############################################################################
# eRegister Lesotho — catch-up / reconcile (v1 sites)
#
# Re-checks everything install.sh is meant to have set up, and redoes ONLY what
# is missing or out of date. Written for sites installed from an earlier version
# of these scripts: they never got the steps added since, and re-running
# install.sh on them is the wrong tool — it freezes the old stack, restores a
# backup and restarts everything.
#
#   Read-mostly: every check is read-only and no repo with local changes is ever
#   reset. FIVE steps write. The first retires the forms this release replaces —
#   every live row of the 'form' table in the 'openmrs' database whose name
#   matches '%2026%' — immediately before the new ones are imported over them, so
#   the outgoing set stops being offered the moment the incoming one lands. The
#   rows are retired, never deleted, so the observations recorded against them
#   are untouched and one UPDATE undoes it — skip it with --no-retire-forms. The
#   second decodes the HTML entities in the form JSON the EMR holds in
#   /home/bahmni/clinical_forms — skip it with --no-decode. The
#   third imports the OpenMRS report definitions (openmrs_reporting_release ->
#   the serialized_object table of the 'openmrs' database), after dumping that
#   table to bahmni-backup so it can be undone — skip it with --no-reporting. The
#   fourth retires one row of idgen_identifier_source in that same database,
#   reversibly and only while it is still in use — skip it with --no-idgen. The
#   last is the final job: it recreates the EMR service so everything refreshed
#   above is actually loaded:
#
#       docker compose up -d --force-recreate --renew-anon-volumes openmrs
#
#   That takes the EMR down for its usual 30+ minute boot and renews the
#   service's ANONYMOUS volumes (named volumes and the database service are not
#   touched). It is confirmed before it runs; --no-recreate skips it.
#
#   Immediately before it, the compose files the stack repo just delivered are
#   applied to every service with a plain `docker compose up -d`. That is a
#   reconcile: only a service whose definition actually moved is recreated, and
#   named volumes are never touched. It is confirmed too; --no-compose-up skips
#   it. Without it, pulling bahmni-docker-ls changes files nothing ever reads.
#
# It:
#   1. updates this repo itself (git pull, then re-runs from the fresh copy)
#   2. clones/fast-forwards every dependency repo the installer pulls:
#      clinical-obs-forms, eregister_concepts_release_v1,
#      implementer-interface-release, standard-config-ls, bahmni-docker-ls,
#      dhisconnector_mappings_v1, openmrs-v1-modules,
#      openmrs_reporting_release — and the site's own upgrade-to-v1 checkout
#   3. reinstalls the generated helper scripts from the current release
#   4. checks all FOUR scheduled jobs (repo auto-pull, daily clinical form
#      import, daily concept-dictionary import, daily database backup) and
#      installs whichever is missing
#   5. retires the forms this release replaces (every live form whose name
#      matches '%2026%' by default — reversibly; --no-retire-forms skips it),
#      runs the form import (only forms whose content changed are deployed), then
#      decodes the HTML entities (&amp; &lt; &gt;) in the form JSON the EMR keeps
#      in /home/bahmni/clinical_forms — repeatedly, because the escaping nests,
#      until a pass finds nothing left to decode. --no-decode skips it
#   5b. imports the OpenMRS report definitions from openmrs_reporting_release
#      into the 'openmrs' database of the openmrsdb service. This is the ONE
#      import catch-up performs itself: it replaces a single table
#      (serialized_object — the report library), takes a pre-import backup of it
#      first, and does nothing at all when the dump in the clone is already the
#      one in the database. --no-reporting skips it
#   5c. retires the disused identifier source — one row of idgen_identifier_source
#      in the 'openmrs' database (id 14 by default), so it stops being offered
#      for new identifiers. The row and the identifiers it already issued are
#      kept, and the report prints the statement that undoes it. It matches only
#      a source that is still in use, so a second run changes nothing.
#      --no-idgen skips it
#   6. reports on the concept dictionary: which dump is on disk, and whether it
#      is the one actually imported. Catch-up never imports it itself — that is
#      the daily concept job's business (or ./import-concepts.sh by hand)
#   6b. reports on the nightly database dumps: how many there are and how old
#      the newest one is, so a job that has been quietly failing is visible
#   7. reports the health of the running services and endpoints (as found)
#   7b. applies the compose files to the WHOLE stack (docker compose up -d in
#      the stack dir), so the bahmni-docker-ls update from step 2 actually takes
#      effect. It is a reconcile, not a restart: a service whose definition did
#      not change is left running untouched, so on a site whose stack repo did
#      not move this is a no-op. --no-compose-up skips it; --pull-images adds
#      `--pull always` for a release that moves an image tag in place
#   8. recreates the EMR service, last, so the refreshed config/omods/forms are
#      loaded — skip with --no-recreate
#
# --decode short-circuits all of that: it runs the decode from step 5 and
# nothing else, for a site that only needs that clean-up.
#
# and ends with a single table: what was already OK, what it redid, what it
# deliberately left alone, and what still needs a human. Exit status is 0 when
# there are no gaps, so it doubles as a monitoring check.
#
# USAGE
#   curl -fsSL --retry 8 --retry-max-time 180 <raw>/catch-up.sh | bash
#   ./catch-up.sh [--decode]
#   ./catch-up.sh [--yes] [--no-stack] [--no-forms] [--no-retire-forms]
#                 [--no-publish] [--no-decode] [--no-concepts] [--no-reporting]
#                 [--no-idgen] [--fix-report-roles] [--no-db-backup] [--no-compose-up] [--pull-images]
#                 [--no-recreate] [--force-repos]
#                 [--install-dir DIR] [--no-color] [--help]
#
#   --decode         DECODE AND NOTHING ELSE, then stop. For a site whose forms
#                    are already deployed and only need the entity clean-up in
#                    /home/bahmni/clinical_forms. No repo is updated, nothing is
#                    imported or scheduled, no health probe runs, and the EMR is
#                    left running — so it costs seconds instead of the usual run.
#                    Spelled --decode-only too, since it is the opposite of a
#                    skip flag and sits next to --no-decode. The two contradict
#                    each other and passing both is an error.
#   -y, --yes        Non-interactive; assume "yes" at every prompt.
#   --no-stack       Do not fast-forward bahmni-docker-ls (the compose files the
#                    running stack reads). Everything else is still updated.
#   --no-forms       Leave the clinical form import and its schedule alone.
#                    Implies --no-decode, --no-retire-forms and --no-publish.
#   --no-retire-forms  Do not retire the forms the release replaces. By default,
#                    straight before the import, every LIVE form whose name
#                    matches EREGISTER_FORM_RETIRE_NAME_LIKE ('%2026%') is
#                    marked retired in 'openmrs' so the outgoing set stops being
#                    offered the moment the incoming one lands. The rows and the
#                    observations recorded against them are kept — it is undone
#                    by one UPDATE, which the run prints. The import still runs.
#   --no-publish     Leave the deployed forms in DRAFT. By default each form is
#                    published as it is deployed — the Implementer Interface's
#                    Import button does not do this, so without it a freshly
#                    imported form is not offered in the clinical app at all.
#                    Publication is RE-ASSERTED: a form skipped as unchanged is
#                    still checked and published if it is not, which is what
#                    fixes a site whose forms were deployed as drafts. A form
#                    you unpublish by hand therefore comes back — use this flag
#                    there.
#   --no-decode      Do not decode the HTML entities in the form JSON the EMR
#                    holds in /home/bahmni/clinical_forms. The import still runs;
#                    only the clean-up pass over what it wrote is skipped.
#   --no-concepts    Leave the concept dictionary alone: skip the concept-count
#                    query, and neither install nor refresh the daily
#                    concept-import job.
#   --no-reporting   Do not import the OpenMRS report definitions from the
#                    openmrs_reporting_release clone. The repo is still cloned
#                    and fast-forwarded; only the database import is skipped.
#   --no-idgen       Do not retire the disused identifier source (row
#                    EREGISTER_IDGEN_RETIRE_ID of idgen_identifier_source,
#                    default 14). Use this on a site where that source is still
#                    wanted: the step RE-ASSERTS, so a hand-made un-retire is
#                    otherwise undone by the next run.
#   --fix-report-roles  OPT-IN. Create the 14 Reports-<Sub-Group> roles the
#                    customised ReportsController requires before it shows a
#                    report group (without them the Reports dashboard is blank),
#                    make each inherit Reports-App, and give them all to
#                    EREGISTER_REPORT_ROLES_USER (default superman). INSERT IGNORE
#                    throughout, with role/role_role/user_role dumped to
#                    bahmni-backup first. Users see the roles at next login.
#                    Also runs `docker compose up -d reports` (the service
#                    named by EREGISTER_REPORTS_SERVICE) as the very last job.
#   --no-db-backup   Leave the daily database backup alone: neither install nor
#                    refresh it, and do not report on the dumps it has taken.
#   --no-compose-up  Do NOT apply the compose files to the stack. By default the
#                    run ends with `docker compose up -d` over EVERY service, so
#                    the bahmni-docker-ls update from step 2 actually takes
#                    effect. That is a reconcile, not a restart: a service whose
#                    definition did not change is left running untouched. With
#                    this flag the stack keeps running whatever its containers
#                    were created from, and you apply it yourself later.
#   --pull-images    Add `--pull always` to that command, so a release that
#                    moves an image tag in place is picked up too. Off by
#                    default because it re-downloads over the site's link.
#   --no-recreate    Do NOT recreate the EMR service at the end. Nothing then
#                    touches a running container, but the refreshed config,
#                    omods and forms are not loaded until it is restarted.
#   --force-repos    Update dependency repos even when they have uncommitted
#                    local changes or sit on a branch other than the one this
#                    release pins, DISCARDING those changes (git reset --hard /
#                    checkout -f). Without it such a repo is reported and left
#                    exactly as it is — hand-edited site config is never thrown
#                    away behind your back.
#   --install-dir DIR  Install base (default /var/lib) -> <base>/v1/...
#
# ENV
#   EREGISTER_INSTALL_BASE      install base (default /var/lib)
#   EREGISTER_UPGRADE_REPO      this repo's URL (for the self-update)
#   EREGISTER_UPGRADE_REF       branch to track (default main)
#   EREGISTER_UPGRADE_REPO_DIR  where the managed checkout lives
#                               (default <base>/v1/upgrade-to-v1)
#   EREGISTER_BAHMNI_PASS       EMR password for the form import; saved when the
#                               EMR accepts it and the stored one is missing or
#                               rejected (otherwise you are prompted)
#   EREGISTER_FORM_PUBLISH=0          same as --no-publish
#   EREGISTER_FORM_RETIRE=0           same as --no-retire-forms
#   EREGISTER_FORM_RETIRE_NAME_LIKE   SQL LIKE pattern matched against form.name
#                                     (default '%2026%')
#   EREGISTER_FORM_RETIRE_REASON      the retire_reason written to those rows
#   EREGISTER_FORM_RETIRE_BY          users.user_id to record (default 1, admin)
#   EREGISTER_FORM_DECODE=0           same as --no-decode
#   EREGISTER_FORM_DECODE_DIR         folder to decode INSIDE the EMR service
#                                     (default /home/bahmni/clinical_forms)
#   EREGISTER_FORM_DECODE_MAX_PASSES  ceiling on the decode passes (default 5);
#                                     it stops early as soon as a pass is clean
#   EREGISTER_CATCHUP_DECODE_ONLY=1   same as --decode
#   EREGISTER_CATCHUP_STACK_REPO=0    same as --no-stack
#   EREGISTER_CATCHUP_DB_CHECK=0      skip the concept-count query
#   EREGISTER_CATCHUP_COMPOSE_UP=0    same as --no-compose-up
#   EREGISTER_CATCHUP_COMPOSE_PULL=1  same as --pull-images
#   EREGISTER_CATCHUP_RECREATE=0      same as --no-recreate
#   EREGISTER_IMPORT_REPORTING=0      same as --no-reporting
#   EREGISTER_IDGEN_RETIRE=0          same as --no-idgen
#   EREGISTER_IDGEN_RETIRE_ID         idgen_identifier_source row to retire
#                                     (default 14; ids are per-site)
#   EREGISTER_IDGEN_RETIRE_REASON     its retire_reason (default 'No longer in use')
#   EREGISTER_IDGEN_RETIRE_BY         users.user_id to record (default 1, admin)
#   EREGISTER_REPORT_ROLES_FIX=1      same as --fix-report-roles
#   EREGISTER_REPORT_ROLES_USER       user given every report group role
#                                     (default superman)
#   EREGISTER_REPORTING_SQL_NAME      import only this file from the reporting
#                                     clone (default: every *.sql in it)
#   EREGISTER_REF_REPORTING           its branch (default master)
#   EREGISTER_CONCEPT_IMPORT=0        do not install/refresh the concept job
#   EREGISTER_CONCEPT_IMPORT_CRON     its schedule (default '30 4 * * *')
#   EREGISTER_DB_BACKUP=0             do not install/refresh the daily DB backup
#   EREGISTER_DB_BACKUP_CRON          its schedule (default '30 1 * * *')
#   EREGISTER_DB_BACKUP_KEEP          dumps to retain (default 14)
#   EREGISTER_CATCHUP_FORCE_REPOS=1   same as --force-repos
#   EREGISTER_EMR_SERVICE             compose service to recreate (default openmrs)
#   EREGISTER_CATCHUP_HTTP_TIMEOUT    seconds per health probe (default 15)
#
# A repo with uncommitted local changes is reported and left completely alone —
# hand-edited site config is never discarded. Pass --force-repos to override
# that and bring every repo onto its pinned ref regardless.
###############################################################################

set -euo pipefail

EREGISTER_RAW_BASE="${EREGISTER_RAW_BASE:-https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main}"
EREGISTER_UPGRADE_REPO="${EREGISTER_UPGRADE_REPO:-https://github.com/Lesotho-eRegister-v1/upgrade-to-v1}"
EREGISTER_UPGRADE_REF="${EREGISTER_UPGRADE_REF:-main}"
BOOTSTRAP_DIR=""   # temp dir holding downloaded modules; cleaned up on EXIT

# Everything the reconcile touches: the repo updater (verify), the DB probe
# (concepts), the report definition import (reporting — it reuses the DB
# plumbing in concepts.sh, so that must be sourced first), the scheduled jobs
# (autopull, dbbackup, forms) and the checks themselves. idgen — the identifier
# source retirement — and reportroles — the opt-in report group roles — reuse
# that same DB plumbing, so they follow concepts.sh too.
EREGISTER_MODULES=(
  core/config.sh
  core/logging.sh
  core/prompt.sh
  core/cli.sh
  system/privilege.sh
  system/deps.sh
  upgrade/verify.sh
  upgrade/concepts.sh
  upgrade/reporting.sh
  upgrade/idgen.sh
  upgrade/reportroles.sh
  upgrade/autopull.sh
  upgrade/dbbackup.sh
  upgrade/forms.sh
  upgrade/catchup.sh
)

# =============================================================================
# Phase 1 — self-update. Runs before any module is sourced, so it may use only
# shell built-ins, git and curl, and carries its own tiny privilege helper.
# =============================================================================

# Minimal as_root for this phase: direct when we can write, sudo when we can't.
# boot_root <path-we-want-to-write> <command...>
# The path may not exist yet (we are often about to create it), so the
# writability test walks up to its nearest existing ancestor — testing the
# not-yet-created path itself would always say "no" and reach for sudo.
# Phase-1 git, with the same ownership guard the modules use (see git_here in
# lib/upgrade/verify.sh): the checkout may well be root-owned while you are not.
boot_git() { git -c safe.directory='*' "$@"; }

boot_root() {
  local probe="${1:-/}"; shift
  while [ -n "$probe" ] && [ "$probe" != "/" ] && [ ! -e "$probe" ]; do
    probe="$(dirname "$probe")"
  done
  if [ "$(id -u)" -eq 0 ] || [ -w "$probe" ]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else "$@"; fi
}

# Where <base>/v1/upgrade-to-v1 is, without the config module: honor
# --install-dir / EREGISTER_INSTALL_BASE, else the same /var/lib default.
boot_repo_dir() {
  local base="${EREGISTER_INSTALL_BASE:-/var/lib}" prev="" a
  for a in "$@"; do
    [ "$prev" = "--install-dir" ] && base="$a"
    prev="$a"
  done
  printf '%s' "${EREGISTER_UPGRADE_REPO_DIR:-${base}/v1/upgrade-to-v1}"
}

# -----------------------------------------------------------------------------
# self_update — bring the scripts themselves up to date and hand over to the
# fresh copy.
#
# Two cases:
#   * running from a git checkout (a developer/site clone): fast-forward it in
#     place, unless it has local changes — those are never discarded.
#   * piped from curl, or a stray copy: clone/update the managed checkout at
#     <base>/v1/upgrade-to-v1 and re-exec from there.
# Either way we exec the up-to-date catch-up.sh exactly once (guarded by
# EREGISTER_CATCHUP_REEXEC) so the rest of the run uses the new modules.
# Sets EREGISTER_CATCHUP_SELF_* for the report.
# -----------------------------------------------------------------------------
self_update() {
  local self self_dir top managed before after

  if [ "${EREGISTER_CATCHUP_REEXEC:-0}" = "1" ]; then
    return 0   # already the fresh copy — phase 1 is done
  fi

  if ! command -v git >/dev/null 2>&1; then
    export EREGISTER_CATCHUP_SELF_STATUS="GAP"
    export EREGISTER_CATCHUP_SELF_DETAIL="git is not installed — could not self-update"
    printf 'WARNING: git not found; continuing with the copy that is running.\n' >&2
    return 0
  fi

  self="${BASH_SOURCE[0]:-}"
  self_dir=""
  [ -n "$self" ] && [ -f "$self" ] && self_dir="$(cd "$(dirname "$self")" && pwd)"

  # --- case 1: we are inside a checkout ------------------------------------
  if [ -n "$self_dir" ] && top="$(boot_git -C "$self_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    if [ -n "$(boot_git -C "$top" status --porcelain 2>/dev/null)" ]; then
      export EREGISTER_CATCHUP_SELF_STATUS="SKIP"
      export EREGISTER_CATCHUP_SELF_DIR="$top"
      export EREGISTER_CATCHUP_SELF_DETAIL="checkout ${top} has local changes — not updated"
      printf 'Local checkout has uncommitted changes; skipping self-update.\n' >&2
      return 0
    fi
    before="$(boot_git -C "$top" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'Updating this checkout (%s) …\n' "$top" >&2
    if boot_root "$top" git -c safe.directory='*' -C "$top" pull --ff-only >/dev/null 2>&1; then
      after="$(boot_git -C "$top" rev-parse --short HEAD 2>/dev/null || echo unknown)"
      if [ "$before" = "$after" ]; then
        export EREGISTER_CATCHUP_SELF_STATUS="OK"
        export EREGISTER_CATCHUP_SELF_DIR="$top"
        export EREGISTER_CATCHUP_SELF_DETAIL="already current (${top} @ ${after})"
        return 0
      fi
      export EREGISTER_CATCHUP_SELF_STATUS="FIXED"
      export EREGISTER_CATCHUP_SELF_DIR="$top"
      export EREGISTER_CATCHUP_SELF_DETAIL="${before} -> ${after} (${top})"
      printf 'Updated %s -> %s; restarting with the new copy.\n' "$before" "$after" >&2
      EREGISTER_CATCHUP_REEXEC=1 exec bash "${top}/catch-up.sh" "$@"
    fi
    export EREGISTER_CATCHUP_SELF_STATUS="GAP"
    export EREGISTER_CATCHUP_SELF_DIR="$top"
    export EREGISTER_CATCHUP_SELF_DETAIL="git pull failed in ${top} — running the copy that is here"
    printf 'WARNING: could not update %s; continuing with the current copy.\n' "$top" >&2
    return 0
  fi

  # --- case 2: piped, or run from outside a checkout ------------------------
  managed="$(boot_repo_dir "$@")"
  if [ -d "${managed}/.git" ]; then
    before="$(boot_git -C "$managed" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'Updating the managed checkout (%s) …\n' "$managed" >&2
    boot_root "$managed" git -c safe.directory='*' -C "$managed" fetch --depth 1 origin "$EREGISTER_UPGRADE_REF" >/dev/null 2>&1 || true
    boot_root "$managed" git -c safe.directory='*' -C "$managed" reset --hard "origin/${EREGISTER_UPGRADE_REF}" >/dev/null 2>&1 || true
    after="$(boot_git -C "$managed" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    export EREGISTER_CATCHUP_SELF_DIR="$managed"
    if [ "$before" = "$after" ]; then
      export EREGISTER_CATCHUP_SELF_STATUS="OK"
      export EREGISTER_CATCHUP_SELF_DETAIL="already current (${managed} @ ${after})"
    else
      export EREGISTER_CATCHUP_SELF_STATUS="FIXED"
      export EREGISTER_CATCHUP_SELF_DETAIL="${before} -> ${after} (${managed})"
    fi
  else
    printf 'Cloning %s -> %s …\n' "$EREGISTER_UPGRADE_REPO" "$managed" >&2
    boot_root "$(dirname "$managed")" mkdir -p "$(dirname "$managed")"
    if boot_root "$(dirname "$managed")" git clone --depth 1 --branch "$EREGISTER_UPGRADE_REF" \
         "$EREGISTER_UPGRADE_REPO" "$managed" >/dev/null 2>&1; then
      export EREGISTER_CATCHUP_SELF_STATUS="FIXED"
      export EREGISTER_CATCHUP_SELF_DIR="$managed"
      export EREGISTER_CATCHUP_SELF_DETAIL="cloned to ${managed} @ $(boot_git -C "$managed" rev-parse --short HEAD 2>/dev/null)"
    else
      export EREGISTER_CATCHUP_SELF_STATUS="GAP"
      export EREGISTER_CATCHUP_SELF_DETAIL="could not clone ${EREGISTER_UPGRADE_REPO} — modules fetched over HTTP instead"
      printf 'WARNING: clone failed; falling back to downloading the modules.\n' >&2
      return 0
    fi
  fi

  if [ -x "${managed}/catch-up.sh" ] || [ -f "${managed}/catch-up.sh" ]; then
    EREGISTER_CATCHUP_REEXEC=1 exec bash "${managed}/catch-up.sh" "$@"
  fi
}

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
      # --retry covers the raw host's transient 429/5xx (a 503 from the CDN is
      # the single most common cause of a failed run); the code is still checked.
      code="$(curl -sSL --retry 6 --retry-max-time 120 \
                    --connect-timeout 15 \
                    -o "${dest}/${m}" -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
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
  _boot_log "An HTTP 503 or 429 here is the raw CDN throttling or briefly"
  _boot_log "unavailable — it is not your setup. Every download above already"
  _boot_log "retries with backoff; just run the same command again in a minute, or"
  _boot_log "use the checkout below, which fetches over git instead."
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

# `return 0` matters: this is an EXIT trap, and a trap handler whose last command
# fails REPLACES the script's exit status. Without it, `[ -n "" ]` on the normal
# path (nothing was bootstrapped) turned every successful run into exit 1.
cleanup() { [ -n "${BOOTSTRAP_DIR:-}" ] && rm -rf "$BOOTSTRAP_DIR"; return 0; }

# catch-up has flags install.sh does not (--no-stack), so it parses its own
# arguments rather than widening the installer's CLI.
parse_catchup_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -y|--yes)       ASSUME_YES="1" ;;
      --no-stack)     CATCHUP_STACK_REPO="0" ;;
      # The retirement is half of the import (retire the outgoing set, deploy the
      # incoming one), so leaving the import alone leaves the retirement alone.
      --no-forms)     IMPORT_FORMS="0"; FORM_RETIRE="0"; FORM_PUBLISH="0" ;;
      # Leaves the outgoing form set live. The import still deploys the new one,
      # so both generations are offered until someone retires the old by hand.
      --no-retire-forms) FORM_RETIRE="0" ;;
      # Leaves every deployed form in Draft, exactly as the Implementer
      # Interface's Import button does. The step re-asserts, so this is also how
      # you keep a hand-unpublished form unpublished.
      --no-publish)   FORM_PUBLISH="0" ;;
      # Only the entity clean-up over what the EMR wrote; the import still runs.
      --no-decode)    FORM_DECODE="0" ;;
      # The inverse: the clean-up and nothing else. --decode-only is accepted
      # because "--decode" next to "--no-decode" reads like a toggle, and this
      # is not one — it changes what the whole run does.
      --decode|--decode-only) CATCHUP_DECODE_ONLY="1" ;;
      # Leaves the stack running whatever its containers were created from,
      # even when bahmni-docker-ls moved this run.
      --no-compose-up) CATCHUP_COMPOSE_UP="0" ;;
      # Re-pull images before applying the compose files, for a release that
      # moves a tag in place rather than naming a new one.
      --pull-images)  CATCHUP_COMPOSE_PULL="1" ;;
      --no-db-backup) DB_BACKUP="0" ;;
      --no-recreate)  CATCHUP_RECREATE_EMR="0" ;;
      --force-repos)  CATCHUP_FORCE_REPOS="1" ;;
      # Same meaning as in install.sh: leave the concept dictionary alone —
       # no DB probe, and do not install or refresh its daily job.
      --no-concepts)  CATCHUP_DB_CHECK="0"; CONCEPT_IMPORT="0" ;;
      # The report definitions ARE imported by this script (see catchup_reporting
      # in lib/upgrade/catchup.sh for why that is safe); this opts out of it.
      --no-reporting) IMPORT_REPORTING="0" ;;
      # Leaves the identifier source in use. Worth spelling out because the step
      # re-asserts: without this, a deliberate un-retire is undone next run.
      --no-idgen)     IDGEN_RETIRE="0" ;;
      # Opt-in, unlike the writes above: creates the Reports-<Sub-Group> roles
      # the Reports dashboard needs and gives them to REPORT_ROLES_USER, and
      # brings the reports service up at the end.
      --fix-report-roles) REPORT_ROLES_FIX="1" ;;
      --install-dir)  INSTALL_BASE="${2:?--install-dir needs a value}"; shift ;;
      --no-color)     USE_COLOR="no" ;;
      -h|--help)      usage; exit 0 ;;
      *) printf 'Unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
    shift
  done

  # "Do only the decode" and "do everything except the decode" cannot both be
  # meant. Saying so beats picking one and leaving the operator to work out why
  # their run did nothing. EREGISTER_FORM_DECODE=0 lands here the same way.
  if [ "$CATCHUP_DECODE_ONLY" = "1" ] && [ "$FORM_DECODE" != "1" ]; then
    printf '%s\n' \
      "--decode and --no-decode (or EREGISTER_FORM_DECODE=0) contradict each other:" \
      "  --decode     run the entity decode and nothing else" \
      "  --no-decode  run everything except the entity decode" \
      "Pick one." >&2
    exit 2
  fi
}

main() {
  self_update "$@"     # may exec a newer copy of this script and never return
  load_modules
  trap cleanup EXIT
  parse_catchup_args "$@"
  setup_colors
  banner_catchup
  resolve_config       # V1_DIR, FORMS_DIR, FORM_IMPORT_*, UPGRADE_REPO_DIR …
  detect_pkg_mgr       # so a missing jq can be offered for installation
  detect_privilege     # sets SUDO for as_root
  catch_up             # non-zero when gaps remain
}

banner_catchup() {
  if [ "$CATCHUP_DECODE_ONLY" = "1" ]; then
    info "eRegister v1 catch-up — DECODE ONLY (--decode)."
    info "The one thing this run does is decode the HTML entities in the form JSON"
    info "the '${EMR_SERVICE}' container holds in ${FORM_DECODE_DIR}."
    info "No repo is updated, nothing is imported or scheduled, and '${EMR_SERVICE}' keeps running."
    return 0
  fi
  info "eRegister v1 catch-up — reconciling this site with the current release."
  info "Read-mostly, with six exceptions: the form JSON in the '${EMR_SERVICE}' container is"
  info "decoded (--no-decode skips it), the forms named like '${FORM_RETIRE_NAME_LIKE}' are retired in"
  info "'${DB_NAME}' just before the new ones are imported (reversibly; --no-retire-forms"
  info "skips it), the report definitions are imported into that same database"
  info "(backed up first; --no-reporting skips it), identifier source ${IDGEN_RETIRE_ID} is"
  info "retired there too (reversibly; --no-idgen skips it), the compose files are"
  info "applied to the whole stack with '${DOCKER_COMPOSE:-docker compose} up -d' so the bahmni-docker-ls"
  info "update takes effect (--no-compose-up skips it), and the '${EMR_SERVICE}' service is"
  info "recreated at the end so the refreshed config, omods and forms are loaded"
  info "(--no-recreate skips it). The last two are confirmed before they run."
  if [ "$REPORT_ROLES_FIX" = "1" ]; then
    info "Also, as asked (--fix-report-roles): the Reports-<Sub-Group> roles are created in"
    info "'${DB_NAME}' and given to '${REPORT_ROLES_USER}' (backed up first), and"
    info "'${DOCKER_COMPOSE:-docker compose} up -d ${REPORTS_SERVICE}' runs as the very last job."
  fi
}

main "$@"
