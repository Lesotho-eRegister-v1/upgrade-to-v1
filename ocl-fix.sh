#!/usr/bin/env bash
###############################################################################
# eRegister Lesotho — OCL concept-name fix (post-upgrade, post-startup)
#
# Run this ONCE, AFTER the v1 instance has fully started and finished its OCL
# import (~30+ min after the stack starts). It:
#   1. Unvoids the concept names OCL voided ("Removed from OCL") and voids OCL's
#      replacement names, in the v1 'openmrs' database (openmrsdb service).
#   2. Renames CIEL_*.zip -> .DONE in the OCL dir of the openmrs (EMR) service so
#      the import does not run again on the next startup.
# Safe to re-run (idempotent).
#
# USAGE
#   ./ocl-fix.sh [--yes] [--install-dir DIR] [--no-color] [--help]
#   curl -fsSL <raw>/ocl-fix.sh | bash
#
# ENV
#   EREGISTER_INSTALL_BASE  install base (default /var/lib) -> <base>/v1/...
#   EREGISTER_DB_SERVICE    db compose service   (default openmrsdb)
#   EREGISTER_EMR_SERVICE   emr compose service  (default openmrs)
#   EREGISTER_DB_PASS       mysql password (else the container's MYSQL_ROOT_PASSWORD)
###############################################################################

set -euo pipefail

# Raw base used to self-bootstrap modules when lib/ isn't present locally.
EREGISTER_RAW_BASE="${EREGISTER_RAW_BASE:-https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main}"
BOOTSTRAP_DIR=""   # temp dir holding downloaded modules; cleaned up on EXIT

# Only the modules this helper needs (a subset of install.sh's set).
OCLFIX_MODULES=(
  core/config.sh
  core/logging.sh
  core/prompt.sh
  core/cli.sh
  system/privilege.sh
  upgrade/oclfix.sh
)

bootstrap_modules() {
  local tmp m url
  command -v curl >/dev/null 2>&1 || { printf 'FATAL: curl required to fetch modules.\n' >&2; return 1; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/eregister-lib.XXXXXX")" || return 1
  printf 'lib/ not found locally — downloading modules from %s …\n' "$EREGISTER_RAW_BASE" >&2
  for m in "${OCLFIX_MODULES[@]}"; do
    mkdir -p "${tmp}/$(dirname "$m")"
    url="${EREGISTER_RAW_BASE}/lib/${m}"
    if ! curl -fsSL "$url" -o "${tmp}/${m}"; then
      printf 'FATAL: could not download module: %s\n' "$url" >&2
      rm -rf "$tmp"; return 1
    fi
  done
  printf '%s' "$tmp"
}

load_modules() {
  local self_dir lib_dir m
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || self_dir=""
  lib_dir="${EREGISTER_LIB_DIR:-${self_dir:+${self_dir}/lib}}"
  if [ -z "$lib_dir" ] || [ ! -d "$lib_dir" ]; then
    lib_dir="$(bootstrap_modules)" || exit 1
    BOOTSTRAP_DIR="$lib_dir"
  fi
  for m in "${OCLFIX_MODULES[@]}"; do
    if [ ! -r "${lib_dir}/${m}" ]; then
      printf 'FATAL: missing module: %s/%s\n' "$lib_dir" "$m" >&2
      exit 1
    fi
    # shellcheck source=/dev/null
    . "${lib_dir}/${m}"
  done
}

cleanup() { [ -n "$BOOTSTRAP_DIR" ] && rm -rf "$BOOTSTRAP_DIR"; }

main() {
  load_modules
  trap cleanup EXIT
  parse_args "$@"
  setup_colors
  resolve_config       # sets RESTORE_DIR from INSTALL_BASE
  detect_privilege     # sets SUDO for as_root
  ocl_fix
  success "Done."
}

main "$@"
