# shellcheck shell=bash
# =============================================================================
# lib/upgrade/autopull.sh — install a scheduled job that keeps the v1 asset and
# config repos in sync with their git remotes (fetch + fast-forward reset).
#
# Covers exactly the repos that receive ongoing content updates after the stack
# is deployed:
#     standard-config-ls
#     implementer-interface-release
#     openmrs-v1-modules
#     clinical-obs-forms
#     dhisconnector_mappings_v1
#     eregister_concepts_release_v1
#     openmrs_reporting_release
#
# Deliberately EXCLUDES bahmni-docker-ls (the stack itself) and the 0.92
# bahmni_config under bahmni-backup — those are pinned to the deployed release
# and must not drift underneath a running instance.
#
# Scheduling uses a systemd .service + .timer where systemd is present
# (Ubuntu's default); otherwise it falls back to a /etc/cron.d entry. Both run
# the SAME standalone updater script, installed to AUTO_PULL_SCRIPT and runnable
# by hand for a one-off sync.
#
# Depends on: logging, as_root() (privilege), confirm() (prompt).
# =============================================================================

# The v1 repos kept up to date, as absolute paths resolved from V1_DIR. One per
# line so callers can iterate with `while read`.
auto_pull_dirs() {
  printf '%s\n' \
    "${V1_DIR}/standard-config-ls" \
    "${V1_DIR}/implementer-interface-release" \
    "${V1_DIR}/openmrs-v1-modules" \
    "${V1_DIR}/clinical-obs-forms" \
    "${V1_DIR}/dhisconnector_mappings_v1" \
    "${V1_DIR}/eregister_concepts_release_v1" \
    "${V1_DIR}/openmrs_reporting_release"
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# -----------------------------------------------------------------------------
# write_updater_script — generate and install the standalone updater.
# It must NOT depend on lib/ (cron/systemd run it in a bare environment), so it
# carries its own tiny logger and a baked-in repo list. The sync mirrors the
# installer's own git_clone_or_update: fetch --depth 1 + hard reset onto the
# tracked branch, so the checkout keeps matching its remote and stays shallow.
# A dirty working tree is left untouched (never clobber uncommitted local work).
# -----------------------------------------------------------------------------
write_updater_script() {
  local tmp d
  tmp="$(mktemp)"
  {
    cat <<'HEADER'
#!/usr/bin/env bash
# eRegister v1 auto-pull — keeps the deployed asset/config repos in sync with
# their git remotes. Installed by install.sh; safe to run by hand. Idempotent.
# Generated file: re-running the installer overwrites it.
set -uo pipefail
HEADER
    printf 'LOG=%q\n' "$AUTO_PULL_LOG"
    printf 'REPOS=(\n'
    while IFS= read -r d; do printf '  %q\n' "$d"; done < <(auto_pull_dirs)
    printf ')\n'
    cat <<'BODY'

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG"; }

# Clones under the install base may be owned by root or by the operator,
# depending on how the installer was run. git refuses a repo it thinks belongs
# to someone else ("detected dubious ownership"), which for a root-run cron job
# means every command below fails and nothing ever updates. safe.directory=*
# relaxes only that ownership check; file permissions still apply.
git_here() { git -c safe.directory='*' "$@"; }

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log "=== auto-pull run start (pid $$) ==="

rc=0
for repo in "${REPOS[@]}"; do
  if [ ! -d "$repo/.git" ]; then
    log "SKIP  $repo (not a git repo)"
    continue
  fi
  if ! branch="$(git_here -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
    # Told apart from a detached HEAD on purpose: this one is a permissions or
    # ownership problem, and saying "detached HEAD" would send you hunting for
    # the wrong thing.
    log "SKIP  $repo (git cannot read it — ownership or permissions; run as root)"
    rc=1
    continue
  fi
  if [ "$branch" = "HEAD" ]; then
    log "SKIP  $repo (detached HEAD; no branch to track)"
    continue
  fi
  if [ -n "$(git_here -C "$repo" status --porcelain 2>/dev/null)" ]; then
    log "SKIP  $repo (uncommitted local changes; left untouched)"
    rc=1
    continue
  fi
  if ! git_here -C "$repo" fetch --depth 1 origin "$branch" >>"$LOG" 2>&1; then
    log "ERROR $repo fetch failed"
    rc=1
    continue
  fi
  before="$(git_here -C "$repo" rev-parse --short HEAD 2>/dev/null)"
  if git_here -C "$repo" reset --hard "origin/$branch" >>"$LOG" 2>&1; then
    after="$(git_here -C "$repo" rev-parse --short HEAD 2>/dev/null)"
    if [ "$before" = "$after" ]; then
      log "OK    $repo already current ($branch @ $after)"
    else
      log "PULL  $repo $branch $before -> $after"
    fi
  else
    log "ERROR $repo reset onto origin/$branch failed"
    rc=1
  fi
done

log "=== auto-pull run end (rc=$rc) ==="
exit $rc
BODY
  } >"$tmp"

  as_root install -m 0755 "$tmp" "$AUTO_PULL_SCRIPT"
  rm -f "$tmp"
  success "Installed updater script: ${AUTO_PULL_SCRIPT}"
}

# -----------------------------------------------------------------------------
# install_systemd_timer — oneshot .service + .timer, enabled and started.
# -----------------------------------------------------------------------------
install_systemd_timer() {
  local svc="/etc/systemd/system/${AUTO_PULL_UNIT}.service"
  local tim="/etc/systemd/system/${AUTO_PULL_UNIT}.timer"

  printf '%s\n' \
    "# Written by the eRegister v1 installer — re-running it overwrites this file." \
    "[Unit]" \
    "Description=eRegister v1 — pull latest asset/config repos" \
    "After=network-online.target" \
    "Wants=network-online.target" \
    "" \
    "[Service]" \
    "Type=oneshot" \
    "ExecStart=${AUTO_PULL_SCRIPT}" \
    | as_root tee "$svc" >/dev/null
  as_root chmod 0644 "$svc"

  printf '%s\n' \
    "# Written by the eRegister v1 installer — re-running it overwrites this file." \
    "[Unit]" \
    "Description=eRegister v1 — schedule for asset/config repo pull" \
    "" \
    "[Timer]" \
    "OnCalendar=${AUTO_PULL_ONCALENDAR}" \
    "Persistent=true" \
    "RandomizedDelaySec=300" \
    "" \
    "[Install]" \
    "WantedBy=timers.target" \
    | as_root tee "$tim" >/dev/null
  as_root chmod 0644 "$tim"

  as_root systemctl daemon-reload
  as_root systemctl enable --now "${AUTO_PULL_UNIT}.timer"
  success "systemd timer enabled: ${AUTO_PULL_UNIT}.timer (OnCalendar=${AUTO_PULL_ONCALENDAR})"
  info "Status: systemctl status ${AUTO_PULL_UNIT}.timer   Run now: systemctl start ${AUTO_PULL_UNIT}.service"
}

# -----------------------------------------------------------------------------
# install_cron_job — /etc/cron.d entry (used when systemd is unavailable).
# -----------------------------------------------------------------------------
install_cron_job() {
  local cronfile="/etc/cron.d/${AUTO_PULL_UNIT}"
  # /etc/cron.d entries carry a user field (root) and their own PATH.
  printf '%s\n' \
    "# Written by the eRegister v1 installer — remove this file to disable auto-pull." \
    "SHELL=/bin/bash" \
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "${AUTO_PULL_CRON} root ${AUTO_PULL_SCRIPT}" \
    | as_root tee "$cronfile" >/dev/null
  as_root chmod 0644 "$cronfile"
  success "cron job installed: ${cronfile} (${AUTO_PULL_CRON})"
}

# -----------------------------------------------------------------------------
# install_auto_pull — top-level entry called from main().
# -----------------------------------------------------------------------------
install_auto_pull() {
  step "Scheduling automatic updates for the v1 repos"
  if [ "$AUTO_PULL" != "1" ]; then
    info "Auto-pull disabled (EREGISTER_AUTO_PULL=0); skipping."
    return 0
  fi

  info "Repos kept in sync with their remotes:"
  local d
  while IFS= read -r d; do info "  • ${d}"; done < <(auto_pull_dirs)

  write_updater_script

  if has_systemd; then
    install_systemd_timer
  elif [ -d /etc/cron.d ]; then
    warn "systemd not detected — falling back to a /etc/cron.d entry."
    install_cron_job
  else
    warn "Neither systemd nor /etc/cron.d is available. The updater was installed"
    warn "at ${AUTO_PULL_SCRIPT} but NOT scheduled — add your own cron/timer entry,"
    warn "or run it periodically by hand."
  fi
}
