#!/usr/bin/env bash
###############################################################################
# eRegister Lesotho — clinical observation form import (post-upgrade)
#
# Deploys the Bahmni Form Builder JSON exports held in the clinical-obs-forms
# clone (<base>/v1/clinical-obs-forms) into the running EMR over its REST API —
# the scripted equivalent of clicking "Import" in the Implementer Interface for
# every form file.
#
# install.sh already does this once at the end of an upgrade, and installs a
# DAILY job to keep doing it. Use this script to (re-)install that machinery, or
# to run an import by hand — after new forms are pushed to clinical-obs-forms,
# or if the import was skipped/failed during the install.
#
# It installs:
#   /usr/local/bin/bahmni-form-import.sh    the importer itself
#   /usr/local/bin/eregister-form-import.sh the wrapper cron/systemd runs
#   /etc/eregister/form-import.env          credentials for it (mode 0600)
#   eregister-form-import.timer  (systemd)  or /etc/cron.d/eregister-form-import
#
# Only forms whose CONTENT changed since the last run are deployed: a sha256 of
# each file is recorded per form name in <base>/v1/.bahmni_form_import_state.json,
# so a same-named file holding a NEW export is deployed (as the next version,
# leaving the live one intact) while an unchanged file that was merely re-pulled
# is skipped. Safe to re-run as often as you like.
#
# USAGE
#   ./import-forms.sh [--yes] [--install-dir DIR] [--no-color] [--help]
#   curl -fsSL <raw>/import-forms.sh | bash
#
#   To import without touching the schedule, call the runner directly:
#     sudo /usr/local/bin/eregister-form-import.sh
#
# ENV
#   EREGISTER_INSTALL_BASE     install base (default /var/lib) -> <base>/v1/...
#   EREGISTER_FORMS_DIR        folder of form JSON (default <base>/v1/clinical-obs-forms)
#   EREGISTER_BAHMNI_URL       EMR base URL         (default https://localhost)
#   EREGISTER_BAHMNI_USER      EMR user             (default superman)
#   EREGISTER_BAHMNI_PASS      EMR password         (prompted when unset)
#   EREGISTER_FORM_IMPORT_CRON        cron schedule        (default '30 3 * * *')
#   EREGISTER_FORM_IMPORT_ONCALENDAR  systemd OnCalendar   (default '*-*-* 03:30:00')
###############################################################################

set -euo pipefail

# Raw base used to self-bootstrap modules when lib/ isn't present locally.
EREGISTER_RAW_BASE="${EREGISTER_RAW_BASE:-https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main}"
BOOTSTRAP_DIR=""   # temp dir holding downloaded modules; cleaned up on EXIT

# Only the modules this helper needs (a subset of install.sh's set).
# autopull.sh comes along for has_systemd(); deps.sh for pkg_install() (jq).
FORMS_MODULES=(
  core/config.sh
  core/logging.sh
  core/prompt.sh
  core/cli.sh
  system/privilege.sh
  system/deps.sh
  upgrade/autopull.sh
  upgrade/forms.sh
)

bootstrap_modules() {
  local tmp m url
  command -v curl >/dev/null 2>&1 || { printf 'FATAL: curl required to fetch modules.\n' >&2; return 1; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/eregister-lib.XXXXXX")" || return 1
  printf 'lib/ not found locally — downloading modules from %s …\n' "$EREGISTER_RAW_BASE" >&2
  for m in "${FORMS_MODULES[@]}"; do
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
  for m in "${FORMS_MODULES[@]}"; do
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
  resolve_config       # sets V1_DIR / FORMS_DIR / FORM_IMPORT_STATE from INSTALL_BASE
  detect_pkg_mgr       # so a missing jq can be offered for installation
  detect_privilege     # sets SUDO for as_root
  # --no-forms is meaningless here (running this script IS the import), so
  # ignore the config default and always attempt it.
  IMPORT_FORMS="1"
  # Guarded rather than bare, so a failing import reports the log instead of
  # dying silently on set -e.
  if ! install_form_import; then
    error "Form import did not complete cleanly — see ${FORM_IMPORT_LOG}."
    exit 1
  fi
  success "Done."
}

main "$@"
