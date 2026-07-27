# shellcheck shell=bash
# =============================================================================
# lib/core/cli.sh — argument parsing, config resolution, summary
# Depends on: logging, read_current_version() (lib/upgrade/detect.sh).
# =============================================================================
# Print the header comment block verbatim: from the line after the opening
# banner up to the closing one (line-range-free, so the header can grow).
usage() { sed -n '3,/^####/p' "$0" 2>/dev/null || true; }

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -y|--yes)       ASSUME_YES="1" ;;
      --force)        FORCE="1" ;;
      --install-dir)  INSTALL_BASE="${2:?--install-dir needs a value}"; shift ;;
      --target-ref)   TARGET_REF="${2:?--target-ref needs a value}"; shift ;;
      --no-color)     USE_COLOR="no" ;;
      -h|--help)      usage; exit 0 ;;
      *) error "Unknown argument: $1"; usage; exit 2 ;;
    esac
    shift
  done
}

resolve_config() {
  V1_DIR="${INSTALL_BASE}/v1"
  # Exported so the restore/run scripts and any child process can find the v1
  # tree without re-deriving it. Tracks --install-dir, so it is /var/lib/v1
  # by default and <base>/v1 when the install base is overridden.
  export eRegister_HOME="$V1_DIR"
  BACKUP_DIR="${V1_DIR}/bahmni-backup"
  BACKUP_SQL="${BACKUP_DIR}/openmrsdb_backup.sql"
  DONE_MARKER="${V1_DIR}/.eregister-upgrade-complete"
  RESTORE_DIR="${V1_DIR}/bahmni-docker-ls/bahmni-standard"
}

print_config() {
  local current; current="$(read_current_version)"
  step "Resolved configuration"
  cat >&2 <<EOF
  ${C_DIM}App${C_RESET}            : ${APP_NAME}
  ${C_DIM}Time${C_RESET}           : $(date '+%Y-%m-%d %H:%M:%S (%Z)')
  ${C_DIM}Current ver${C_RESET}    : ${current}
  ${C_DIM}Target ver${C_RESET}     : ${TARGET_VERSION}
  ${C_DIM}Ref override${C_RESET}   : ${TARGET_REF:-(none — using the per-repo defaults below)}$( [ -n "$TARGET_REF" ] && echo "  (tried in order; per-repo default is the last resort)" )
  ${C_DIM}Default refs${C_RESET}   : docker=${REF_BAHMNI_DOCKER}  config=${REF_STANDARD_CONFIG}  092=${REF_CONFIG_092}
  ${C_DIM}     ${C_RESET}            modules=${REF_OPENMRS_MODULES}  impl-interface=${REF_IMPL_INTERFACE}  obs-forms=${REF_OBS_FORMS}
  ${C_DIM}OS / Arch${C_RESET}      : ${OS} / ${ARCH}
  ${C_DIM}Pkg manager${C_RESET}    : ${PKG_MGR:-none}
  ${C_DIM}Install base${C_RESET}   : ${INSTALL_BASE}
  ${C_DIM}v1 dir${C_RESET}         : ${V1_DIR}
  ${C_DIM}eRegister_HOME${C_RESET} : ${eRegister_HOME}
  ${C_DIM}Old stack${C_RESET}      : ${OLD_DOCKER_DIR}
  ${C_DIM}EMR container${C_RESET}  : ${EMR_CONTAINER}
  ${C_DIM}Privilege${C_RESET}      : $( [ -n "$SUDO" ] && echo "sudo" || echo "direct" )
  ${C_DIM}Non-interactive${C_RESET}: $( [ "$ASSUME_YES" = "1" ] && echo "yes" || echo "no" )
EOF
}
