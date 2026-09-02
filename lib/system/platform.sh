# shellcheck shell=bash
# =============================================================================
# lib/system/platform.sh — OS / architecture detection & artifact-name mapping
# =============================================================================
detect_platform() {
  local raw_os raw_arch
  raw_os="$(uname -s)"
  raw_arch="$(uname -m)"

  case "$raw_os" in
    Linux)  OS="linux"  ;;
    Darwin) OS="darwin" ;;
    *) error "Unsupported OS: ${raw_os}. Supported: Linux, macOS."; exit 1 ;;
  esac

  case "$raw_arch" in
    x86_64|amd64)        ARCH="amd64" ;;
    aarch64|arm64)       ARCH="arm64" ;;
    *) error "Unsupported CPU architecture: ${raw_arch}. Supported: amd64, arm64."; exit 1 ;;
  esac

  # The upgrade flow itself is container-based (platform-agnostic), but the
  # full Bahmni stack is only exercised on Linux. Warn loudly on macOS.
  if [ "$OS" = "darwin" ]; then
    warn "macOS detected: the Bahmni Docker stack is supported only on Linux ${ARCH}."
    confirm "Continue anyway?" "quit here" || { error "Aborted by user."; exit 1; }
  fi
}
