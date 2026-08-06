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
#   curl -fsSL <raw>/import-concepts.sh | bash
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
EREGISTER_RAW_BASE="${EREGISTER_RAW_BASE:-https://raw.githubusercontent.com/eRegister/upgrade-to-v1/refs/heads/main}"
BOOTSTRAP_DIR=""   # temp dir holding downloaded modules; cleaned up on EXIT

# Only the modules this helper needs (a subset of install.sh's set).
CONCEPTS_MODULES=(
  core/config.sh
  core/logging.sh
  core/prompt.sh
  core/cli.sh
  system/privilege.sh
  upgrade/concepts.sh
)

bootstrap_modules() {
  local tmp m url
  command -v curl >/dev/null 2>&1 || { printf 'FATAL: curl required to fetch modules.\n' >&2; return 1; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/eregister-lib.XXXXXX")" || return 1
  printf 'lib/ not found locally — downloading modules from %s …\n' "$EREGISTER_RAW_BASE" >&2
  for m in "${CONCEPTS_MODULES[@]}"; do
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
  for m in "${CONCEPTS_MODULES[@]}"; do
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
  resolve_config       # sets RESTORE_DIR / CONCEPTS_SQL from INSTALL_BASE
  detect_privilege     # sets SUDO for as_root
  # --no-concepts is meaningless here (running this script IS the import), so
  # ignore the config default and always attempt it.
  IMPORT_CONCEPTS="1"
  import_concepts
  success "Done."
}

main "$@"
