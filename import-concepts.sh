#!/usr/bin/env bash
###############################################################################
# eRegister Lesotho — concept dictionary import (post-upgrade)
#
# Loads the concept dictionary shipped in the eregister_concepts_release_v1
# clone (<base>/v1/eregister_concepts_release_v1/omrs_concept_dictionary_v1.sql)
# into the 'openmrs' database inside the openmrsdb container.
#
# install.sh already runs this once at the end of an upgrade. Use this script to
# re-run it on its own — after the auto-pull job picks up a newer dictionary, or
# if the import was skipped/failed during the install.
#
# It drops and recreates the concept_*/drug* tables (including drug_order), so
# their current contents are dumped to
# <base>/v1/bahmni-backup/concepts-preimport-<stamp>.sql before anything is
# replaced. Safe to re-run (each run lands the same dump again).
#
# USAGE
#   ./import-concepts.sh [--yes] [--install-dir DIR] [--no-color] [--help]
#   ./import-concepts.sh --schedule        # install the DAILY job instead of
#                                          # importing now (see below)
#   curl -fsSL <raw>/import-concepts.sh | bash
#
# THE SCHEDULED JOB
#   --schedule installs /usr/local/bin/eregister-concept-import.sh and a daily
#   systemd timer (or /etc/cron.d entry) that, in one run: fast-forwards the
#   eregister_concepts_release_v1 clone, picks the newest
#   omrs_concept_dictionary_*.sql in it, and imports it into the 'openmrs'
#   database — but only when that dump differs from the one already loaded.
#   It is independent of the daily clinical form import.
#
# ENV
#   EREGISTER_INSTALL_BASE     install base (default /var/lib) -> <base>/v1/...
#   EREGISTER_DB_SERVICE       db compose service   (default openmrsdb)
#   EREGISTER_DB_NAME          database             (default openmrs)
#   EREGISTER_DB_PASS          mysql password (else the container's MYSQL_ROOT_PASSWORD)
#   EREGISTER_CONCEPTS_SQL_NAME  dump filename inside the concepts repo
#   EREGISTER_CONCEPTS_DB_WAIT   seconds to wait for openmrsdb (default 300)
###############################################################################

set -euo pipefail

# Raw base used to self-bootstrap modules when lib/ isn't present locally.
EREGISTER_RAW_BASE="${EREGISTER_RAW_BASE:-https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main}"
BOOTSTRAP_DIR=""   # temp dir holding downloaded modules; cleaned up on EXIT

# Only the modules this helper needs (a subset of install.sh's set).
EREGISTER_MODULES=(
  core/config.sh
  core/logging.sh
  core/prompt.sh
  core/cli.sh
  system/privilege.sh
  upgrade/verify.sh      # git_clone_or_update, for the runner's toolkit checkout
  upgrade/autopull.sh    # has_systemd
  upgrade/concepts.sh
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

# `return 0` matters: this is an EXIT trap, and a trap handler whose last command
# fails REPLACES the script's exit status. Without it, `[ -n "" ]` on the normal
# path (nothing was bootstrapped) turned every successful run into exit 1.
cleanup() { [ -n "${BOOTSTRAP_DIR:-}" ] && rm -rf "$BOOTSTRAP_DIR"; return 0; }

main() {
  load_modules
  trap cleanup EXIT
  # cli.sh's parser does not know --schedule (see main), so keep it away from it.
  local args=()
  for a in "$@"; do [ "$a" = "--schedule" ] || args+=("$a"); done
  parse_args ${args[@]+"${args[@]}"}
  setup_colors
  resolve_config       # sets RESTORE_DIR / CONCEPTS_SQL from INSTALL_BASE
  detect_privilege     # sets SUDO for as_root
  # --no-concepts is meaningless here (running this script IS the import), so
  # ignore the config default and always attempt it.
  IMPORT_CONCEPTS="1"

  # --schedule installs the daily job instead of importing right now. Parsed
  # here rather than in cli.sh: it is meaningful only for this script.
  local a
  for a in "$@"; do
    if [ "$a" = "--schedule" ]; then
      install_concept_import || exit 1
      success "Done."
      return 0
    fi
  done

  import_concepts
  success "Done."
}

main "$@"
