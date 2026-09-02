# shellcheck shell=bash
# =============================================================================
# lib/upgrade/backup.sh — directory scaffolding + OpenMRS MySQL dump from the
# running EMR container, taken BEFORE anything is changed.
# Depends on: logging, as_root() (privilege).
# =============================================================================
ensure_dir() {
  # ensure_dir <path> <label>  — idempotent, logs "folder created"
  local path="$1" label="$2"
  if [ -d "$path" ]; then
    info "${label} already exists: ${path}"
  else
    as_root mkdir -p "$path"
    success "${label} created: ${path}"
  fi
}

# True when a container with EXACTLY the given name is running.
container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"
}

# Turn a literal container name into an anchored regex that treats '-' and '_'
# as interchangeable separators, so compose v1 (underscore), v2 (hyphen) and
# mixed variants all match the same configured name. For example
# 'bahmni_docker-emr-service-1' also matches 'bahmni_docker_emr_service_1' and
# 'bahmni_docker_emr-service_1'. Dots are escaped; container names carry no
# other regex metacharacters.
container_name_regex() {
  local re
  re="$(printf '%s' "$1" | sed -e 's/\./\\./g' -e 's/[-_]/[-_]/g')"
  printf '^%s$' "$re"
}

# Echo the name of the first RUNNING container matching the given name with
# separators treated flexibly (see container_name_regex). Empty output when
# nothing matches.
find_running_container() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 -E "$(container_name_regex "$1")"
}

# Resolve which container hosts the EMR service and set EMR_CONTAINER to it.
# Tries the configured name, then the known alternate (EMR_CONTAINER_ALT), each
# matched with flexible separators so hyphen/underscore variants are found
# automatically. If neither is up, asks the user for the running service's name
# — unless we're non-interactive, in which case we can't ask and simply report
# failure. Returns 0 with EMR_CONTAINER pointing at a RUNNING container, or 1
# when none is available / the user entered nothing (caller then skips backup).
resolve_emr_container() {
  local name match
  for name in "$EMR_CONTAINER" "$EMR_CONTAINER_ALT"; do
    [ -n "$name" ] || continue
    match="$(find_running_container "$name")"
    if [ -n "$match" ]; then
      EMR_CONTAINER="$match"
      info "Found running EMR container: ${EMR_CONTAINER}"
      return 0
    fi
  done

  warn "None of the known EMR docker services are running:"
  warn "  • ${EMR_CONTAINER}"
  warn "  • ${EMR_CONTAINER_ALT}"

  # Can't prompt without a TTY (or when auto-confirming); skip rather than hang.
  if [ "$ASSUME_YES" = "1" ] || [ ! -r /dev/tty ]; then
    warn "Non-interactive (or no TTY): cannot ask for a container name — skipping backup."
    return 1
  fi

  # Looped, for the same reason confirm() is: a mistyped container name used to
  # cost the pre-upgrade backup outright, with nothing but a warning to say so.
  # A blank line still means "skip" — the prompt says as much — but a name that
  # does not resolve now gets a second chance.
  local entered=""
  while :; do
    printf '%sEnter the name of the running docker service hosting the EMR (leave blank to skip): %s' \
      "$C_WARN" "$C_RESET" >/dev/tty
    # A failed read is end-of-input: treat it as the blank-line skip rather than
    # re-asking a terminal that has nothing left to give.
    read -r entered </dev/tty || entered=""
    if [ -z "$entered" ]; then
      warn "Nothing entered — proceeding to the next step without a backup."
      return 1
    fi
    if container_running "$entered"; then
      EMR_CONTAINER="$entered"
      success "Using EMR container: ${EMR_CONTAINER}"
      return 0
    fi
    warn "Container '${entered}' is not running."
    if confirm "Carry on WITHOUT a backup of the ${CURRENT_VERSION_DEFAULT} database?" \
               "carry on with no backup"; then
      warn "Proceeding to the next step without a backup."
      return 1
    fi
    # Plain `docker ps`, matching container_running above — the name has to come
    # from the same listing that check reads, or the retry is guesswork.
    info "Running containers, so you can copy the name exactly:"
    docker ps --format '  {{.Names}}  ({{.Image}})' 2>/dev/null >&2 || true
  done
}

take_backup() {
  log ""
  info "taking backup first…….."
  # Defensive: resolve_emr_container should have set EMR_CONTAINER to a running
  # container before we get here. If it somehow isn't (e.g. stopped in between),
  # don't abort — flag it and let the run continue as a fresh install.
  if ! container_running "$EMR_CONTAINER"; then
    warn "EMR container '${EMR_CONTAINER}' is not running — skipping backup (nothing to migrate)."
    BACKUP_SKIPPED="1"
    return 0
  fi
  if [ -f "$BACKUP_SQL" ] && [ "$FORCE" != "1" ]; then
    warn "Backup already exists: ${BACKUP_SQL} (use --force to overwrite). Keeping it."
  else
    # MYSQL_PWD keeps the password off the container's process list.
    # Dump EVERYTHING in the openmrs db so the restore is self-contained:
    #   --single-transaction  consistent InnoDB snapshot without locking writers
    #   --routines            stored procedures & functions
    #   --triggers            table triggers
    #   --events              scheduled events
    #   --databases           emit CREATE DATABASE / USE so the db is recreated
    #   --hex-blob            binary-safe encoding of BLOB/BINARY columns
    #   --default-character-set=utf8mb4  no truncation/corruption of unicode text
    # Stream the dump out and write it host-side (as root for /var/lib).
    docker exec -e "MYSQL_PWD=${DB_PASS}" "$EMR_CONTAINER" \
      mysqldump --single-transaction --routines --triggers --events \
                --hex-blob --default-character-set=utf8mb4 \
                --databases -u "$DB_USER" "$DB_NAME" \
      | as_root tee "$BACKUP_SQL" >/dev/null
    [ -s "$BACKUP_SQL" ] || { error "Backup file is empty: ${BACKUP_SQL}"; return 1; }
  fi
  success "backup created and placed in ${BACKUP_DIR}"
}
