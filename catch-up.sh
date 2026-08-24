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
#   reset. The ONE exception is the last job — it recreates the EMR service so
#   everything refreshed above is actually loaded:
#
#       docker compose up -d --force-recreate --renew-anon-volumes openmrs
#
#   That takes the EMR down for its usual 30+ minute boot and renews the
#   service's ANONYMOUS volumes (named volumes and the database service are not
#   touched). It is confirmed before it runs; --no-recreate skips it.
#
# It:
#   1. updates this repo itself (git pull, then re-runs from the fresh copy)
#   2. clones/fast-forwards every dependency repo the installer pulls:
#      clinical-obs-forms, eregister_concepts_release_v1,
#      implementer-interface-release, standard-config-ls, bahmni-docker-ls,
#      dhisconnector_mappings_v1, openmrs-v1-modules — and the site's own
#      upgrade-to-v1 checkout
#   3. reinstalls the generated helper scripts from the current release
#   4. checks both scheduled jobs (repo auto-pull, daily clinical form import)
#      and installs whichever is missing
#   5. runs the form import (only forms whose content changed are deployed)
#   6. reports on the concept dictionary — never imports it automatically
#   7. reports the health of the running services and endpoints (as found)
#   8. recreates the EMR service, last, so the refreshed config/omods/forms are
#      loaded — skip with --no-recreate
#
# and ends with a single table: what was already OK, what it redid, what it
# deliberately left alone, and what still needs a human. Exit status is 0 when
# there are no gaps, so it doubles as a monitoring check.
#
# USAGE
#   curl -fsSL <raw>/catch-up.sh | bash
#   ./catch-up.sh [--yes] [--no-stack] [--no-forms] [--no-concepts]
#                 [--no-recreate] [--force-repos] [--install-dir DIR]
#                 [--no-color] [--help]
#
#   -y, --yes        Non-interactive; assume "yes" at every prompt.
#   --no-stack       Do not fast-forward bahmni-docker-ls (the compose files the
#                    running stack reads). Everything else is still updated.
#   --no-forms       Leave the clinical form import and its schedule alone.
#   --no-concepts    Leave the concept-dictionary rows out of the report.
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
#   EREGISTER_BAHMNI_PASS       EMR password, when the form-import credentials
#                               file has to be (re)created non-interactively
#   EREGISTER_CATCHUP_STACK_REPO=0    same as --no-stack
#   EREGISTER_CATCHUP_DB_CHECK=0      skip the concept-count query
#   EREGISTER_CATCHUP_RECREATE=0      same as --no-recreate
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
# (concepts), the scheduled jobs (autopull, forms) and the checks themselves.
EREGISTER_MODULES=(
  core/config.sh
  core/logging.sh
  core/prompt.sh
  core/cli.sh
  system/privilege.sh
  system/deps.sh
  upgrade/verify.sh
  upgrade/concepts.sh
  upgrade/autopull.sh
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
      --no-forms)     IMPORT_FORMS="0" ;;
      --no-recreate)  CATCHUP_RECREATE_EMR="0" ;;
      --force-repos)  CATCHUP_FORCE_REPOS="1" ;;
      --no-concepts)  CATCHUP_DB_CHECK="0" ;;
      --install-dir)  INSTALL_BASE="${2:?--install-dir needs a value}"; shift ;;
      --no-color)     USE_COLOR="no" ;;
      -h|--help)      usage; exit 0 ;;
      *) printf 'Unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
    shift
  done
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
  info "eRegister v1 catch-up — reconciling this site with the current release."
  info "Read-mostly, with one exception: the '${EMR_SERVICE}' service is recreated at"
  info "the end so the refreshed config, omods and forms are loaded (--no-recreate skips it)."
}

main "$@"
