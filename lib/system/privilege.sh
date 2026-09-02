# shellcheck shell=bash
# =============================================================================
# lib/system/privilege.sh — root / sudo handling
# =============================================================================
detect_privilege() {
  # Determine whether we need elevation to write under INSTALL_BASE.
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    return 0
  fi
  if [ -w "$INSTALL_BASE" ] && [ -w "$(dirname "$INSTALL_BASE")" ]; then
    SUDO=""
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    info "Elevation required for ${INSTALL_BASE}; will use sudo."
    # Prime sudo so later steps don't stall mid-flow.
    if ! sudo -n true 2>/dev/null; then
      confirm "Authorize sudo now?" "quit — sudo is required to continue" \
        || { error "Aborted: sudo required."; exit 1; }
      sudo -v </dev/tty || { error "Could not obtain sudo."; exit 1; }
    fi
  else
    error "Root is required to write to ${INSTALL_BASE} but 'sudo' is not available."
    error "Re-run as root, or pass --install-dir to a writable location."
    exit 1
  fi
}

as_root() { if [ -n "$SUDO" ]; then "$SUDO" "$@"; else "$@"; fi; }
