# shellcheck shell=bash
# =============================================================================
# lib/upgrade/forms.sh — deploy the clinical observation forms and schedule the
# daily job that keeps them deployed.
#
# The clinical-obs-forms repo (cloned to <base>/v1/clinical-obs-forms by
# fetch_repos, and refreshed by the auto-pull job) holds Bahmni Form Builder
# JSON exports. bin/bahmni_form_import.sh replays exactly what the Implementer
# Interface "Import" button does — concept UUID fix-up, POST /form, save body,
# save translations — over the REST API, so those exports become live forms
# without anyone clicking through the UI.
#
# WHAT THIS MODULE DOES
#   1. installs the importer to FORM_IMPORT_SCRIPT (from bin/ next to
#      install.sh, or downloaded from RAW_BASE when only install.sh was piped in)
#   2. writes FORM_IMPORT_ENV (0600, root-owned) with the EMR URL/user/password
#      the unattended runs authenticate with
#   3. installs FORM_IMPORT_RUNNER — a small bare-environment wrapper that
#      sources that env file and runs the importer over FORMS_DIR
#   4. runs it once, now
#   5. schedules it DAILY: a systemd .service + .timer where systemd is present,
#      else an /etc/cron.d entry
#
# NEW-FILE DETECTION
#   The importer keys its state file on server URL + form name and stores a
#   sha256 of the source file, so the daily run deploys a form only when its
#   CONTENT changed — a same-named file replaced with a new export counts as
#   new work and goes out as the next version, while an unchanged file that was
#   merely re-checked-out by the auto-pull job (new mtime, same bytes) is
#   skipped. The state file lives in V1_DIR, NOT inside the clone, so the
#   auto-pull `git reset --hard` cannot wipe the deployment record.
#
# Depends on: logging, prompt (confirm), as_root() (privilege),
#             has_systemd() (autopull.sh).
# Uses config: FORMS_*, FORM_IMPORT_*, V1_DIR, RAW_BASE, BAHMNI_*.
# =============================================================================

# -----------------------------------------------------------------------------
# _forms_install_importer — put bin/bahmni_form_import.sh at FORM_IMPORT_SCRIPT.
# Prefers the copy shipped next to install.sh; falls back to RAW_BASE for the
# `curl | bash` install path, which has no local checkout.
# -----------------------------------------------------------------------------
_forms_install_importer() {
  local self_dir cand tmp url code
  # Repo root relative to this module — covers both a checkout and the clone the
  # bootstrap makes when only install.sh was piped in.
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || self_dir=""

  for cand in "${self_dir:+${self_dir}/bin/bahmni_form_import.sh}" \
              "${UPGRADE_REPO_DIR:+${UPGRADE_REPO_DIR}/bin/bahmni_form_import.sh}"; do
    if [ -n "$cand" ] && [ -r "$cand" ]; then
      as_root install -m 0755 "$cand" "$FORM_IMPORT_SCRIPT"
      success "Installed form importer: ${FORM_IMPORT_SCRIPT} (from ${cand})"
      return 0
    fi
  done

  # Last resort: fetch it. The status is checked here rather than left to
  # `curl -f`, which over HTTP/2 reports a missing file as the unhelpful
  # "curl: (56) The requested URL returned error: 404".
  url="${RAW_BASE}/bin/bahmni_form_import.sh"
  info "bin/bahmni_form_import.sh not found locally — downloading it from ${RAW_BASE} …"
  tmp="$(mktemp)"
  code="$(curl -sSL -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
  if [ "$code" != "200" ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    error "Could not download the form importer: HTTP ${code} for ${url}"
    error "A 404 means bin/bahmni_form_import.sh is not on that branch yet (push it),"
    error "or the branch/repo in EREGISTER_RAW_BASE is wrong or private."
    error "Workaround: clone the repo and re-run from the checkout, so bin/ is local."
    return 1
  fi
  as_root install -m 0755 "$tmp" "$FORM_IMPORT_SCRIPT"
  rm -f "$tmp"
  success "Installed form importer: ${FORM_IMPORT_SCRIPT}"
}

# -----------------------------------------------------------------------------
# _forms_prompt_credentials — obtain the EMR password used by the scheduled job.
# Same rules as prompt_db_password: environment first, then a silent /dev/tty
# prompt; never the script's own stdin (which is the script when piped).
# Returns 1 when no password can be obtained, so the caller can skip cleanly
# rather than install a job that fails every night.
# -----------------------------------------------------------------------------
_forms_prompt_credentials() {
  if [ -n "${BAHMNI_PASS:-}" ]; then
    info "Using the EMR password from the environment (EREGISTER_BAHMNI_PASS/BAHMNI_PASS)."
    return 0
  fi
  if [ "$ASSUME_YES" = "1" ]; then
    warn "Non-interactive mode and no EMR password set (EREGISTER_BAHMNI_PASS)."
    return 1
  fi
  if [ ! -r /dev/tty ]; then
    warn "No TTY available to prompt for the EMR password. Set EREGISTER_BAHMNI_PASS instead."
    return 1
  fi
  local p1 p2
  while :; do
    printf '%sEnter the eRegister (OpenMRS) password for '\''%s'\'' at %s: %s' \
      "$C_WARN" "$BAHMNI_USER" "$BAHMNI_URL" "$C_RESET" >/dev/tty
    IFS= read -rs p1 </dev/tty; printf '\n' >/dev/tty
    if [ -z "$p1" ]; then
      warn "Password cannot be empty."
      confirm "Try again? (answering 'n' skips the form import)" || return 1
      continue
    fi
    printf '%sConfirm password: %s' "$C_WARN" "$C_RESET" >/dev/tty
    IFS= read -rs p2 </dev/tty; printf '\n' >/dev/tty
    [ "$p1" = "$p2" ] || { warn "Passwords do not match — try again."; continue; }
    BAHMNI_PASS="$p1"; break
  done
  success "EMR password captured."
}

# -----------------------------------------------------------------------------
# _forms_write_env — credentials + settings for the unattended runs.
# 0600 and root-owned: it holds a password, and both the timer and the cron
# entry run as root.
# -----------------------------------------------------------------------------
_forms_write_env() {
  local tmp
  tmp="$(mktemp)"
  chmod 0600 "$tmp"
  {
    printf '%s\n' "# eRegister v1 — settings for the scheduled clinical form import."
    printf '%s\n' "# Written by the installer; re-running it overwrites this file."
    printf '%s\n' "# Contains a password: keep it mode 0600."
    printf 'BAHMNI_URL=%s\n'        "$BAHMNI_URL"
    printf 'BAHMNI_USER=%s\n'       "$BAHMNI_USER"
    printf 'BAHMNI_PASS=%s\n'       "$BAHMNI_PASS"
    printf 'BAHMNI_FORMS_DIR=%s\n'  "$FORMS_DIR"
    printf 'BAHMNI_STATE_FILE=%s\n' "$FORM_IMPORT_STATE"
    printf 'BAHMNI_INSECURE=%s\n'   "$FORM_IMPORT_INSECURE"
  } >"$tmp"
  # 0700 on the directory: the file inside is 0600, and a 0600 directory
  # could not be traversed to reach it.
  as_root install -m 0700 -d "$(dirname "$FORM_IMPORT_ENV")"
  as_root install -m 0600 "$tmp" "$FORM_IMPORT_ENV"
  rm -f "$tmp"
  success "Wrote ${FORM_IMPORT_ENV} (mode 0600)."
}

# -----------------------------------------------------------------------------
# _forms_write_runner — the thing cron/systemd actually call.
# Bare environment: no lib/, no PATH assumptions, its own log. It sources the
# env file, optionally refreshes the clone (so the import still sees new forms
# on a host where auto-pull was declined), then runs the importer over the
# whole folder. The importer decides per file whether anything needs deploying.
# -----------------------------------------------------------------------------
_forms_write_runner() {
  local tmp
  tmp="$(mktemp)"
  {
    cat <<'HEADER'
#!/usr/bin/env bash
# eRegister v1 — scheduled clinical observation form import.
# Sources the credentials file, refreshes the clinical-obs-forms clone, and
# runs the Bahmni form importer over it. Only forms whose CONTENT changed since
# the last run are deployed (sha256 per form, recorded in the state file), so
# this is safe to run every day. Installed by install.sh; safe to run by hand.
# Generated file: re-running the installer overwrites it.
set -uo pipefail
HEADER
    printf 'ENV_FILE=%q\n'  "$FORM_IMPORT_ENV"
    printf 'IMPORTER=%q\n'  "$FORM_IMPORT_SCRIPT"
    printf 'LOG=%q\n'       "$FORM_IMPORT_LOG"
    printf 'WORKDIR=%q\n'   "$FORM_IMPORT_WORKDIR"
    printf 'SELF_PULL=%q\n' "$FORM_IMPORT_SELF_PULL"
    cat <<'BODY'

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG"; }

mkdir -p "$(dirname "$LOG")" "$WORKDIR" 2>/dev/null || true
log "=== form import run start (pid $$) ==="

if [ ! -r "$ENV_FILE" ]; then
  log "ERROR cannot read $ENV_FILE — no credentials; nothing done"
  exit 1
fi
# shellcheck source=/dev/null
set -a; . "$ENV_FILE"; set +a

FORMS_DIR="${BAHMNI_FORMS_DIR:?BAHMNI_FORMS_DIR not set in the env file}"

if [ ! -d "$FORMS_DIR" ]; then
  log "ERROR form folder not found: $FORMS_DIR"
  exit 1
fi

# Refresh the clone first when asked to (SELF_PULL=1). The auto-pull job
# normally does this earlier in the night; doing it here as well is harmless
# (same fetch + fast-forward) and keeps this job useful on its own. A dirty
# tree or a detached HEAD is left alone — never clobber local work.
if [ "$SELF_PULL" = "1" ] && [ -d "$FORMS_DIR/.git" ]; then
  branch="$(git -C "$FORMS_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  if [ "$branch" = "HEAD" ]; then
    log "SKIP  refresh ($FORMS_DIR is on a detached HEAD)"
  elif [ -n "$(git -C "$FORMS_DIR" status --porcelain 2>/dev/null)" ]; then
    log "SKIP  refresh ($FORMS_DIR has uncommitted local changes)"
  elif git -C "$FORMS_DIR" fetch --depth 1 origin "$branch" >>"$LOG" 2>&1 &&
       git -C "$FORMS_DIR" reset --hard "origin/$branch" >>"$LOG" 2>&1; then
    log "OK    refreshed $FORMS_DIR ($branch @ $(git -C "$FORMS_DIR" rev-parse --short HEAD 2>/dev/null))"
  else
    log "WARN  could not refresh $FORMS_DIR — importing what is on disk"
  fi
fi

# The importer writes <form>.importErrors.txt for unresolved concepts into the
# current directory, so give it a writable one instead of wherever cron lands.
cd "$WORKDIR" || cd /tmp || exit 1

# The stack's certificate is self-signed, so curl normally needs -k. The
# ${arr[@]+...} form keeps an empty array from tripping `set -u` on older bash.
INSECURE_FLAG=()
[ "${BAHMNI_INSECURE:-0}" = "1" ] && INSECURE_FLAG=(-k)

log "RUN   $IMPORTER ${INSECURE_FLAG[@]+${INSECURE_FLAG[*]}} -r $FORMS_DIR"
"$IMPORTER" ${INSECURE_FLAG[@]+"${INSECURE_FLAG[@]}"} -r "$FORMS_DIR" >>"$LOG" 2>&1
rc=$?
log "=== form import run end (rc=$rc) ==="
exit $rc
BODY
  } >"$tmp"

  as_root install -m 0755 "$tmp" "$FORM_IMPORT_RUNNER"
  rm -f "$tmp"
  as_root mkdir -p "$FORM_IMPORT_WORKDIR"
  success "Installed form-import runner: ${FORM_IMPORT_RUNNER}"
}

# -----------------------------------------------------------------------------
# _forms_install_systemd_timer — daily oneshot .service + .timer.
# -----------------------------------------------------------------------------
_forms_install_systemd_timer() {
  local svc="/etc/systemd/system/${FORM_IMPORT_UNIT}.service"
  local tim="/etc/systemd/system/${FORM_IMPORT_UNIT}.timer"

  printf '%s\n' \
    "# Written by the eRegister v1 installer — re-running it overwrites this file." \
    "[Unit]" \
    "Description=eRegister v1 — import changed clinical observation forms" \
    "After=network-online.target docker.service" \
    "Wants=network-online.target" \
    "" \
    "[Service]" \
    "Type=oneshot" \
    "ExecStart=${FORM_IMPORT_RUNNER}" \
    | as_root tee "$svc" >/dev/null
  as_root chmod 0644 "$svc"

  printf '%s\n' \
    "# Written by the eRegister v1 installer — re-running it overwrites this file." \
    "[Unit]" \
    "Description=eRegister v1 — daily schedule for the clinical form import" \
    "" \
    "[Timer]" \
    "OnCalendar=${FORM_IMPORT_ONCALENDAR}" \
    "Persistent=true" \
    "RandomizedDelaySec=300" \
    "" \
    "[Install]" \
    "WantedBy=timers.target" \
    | as_root tee "$tim" >/dev/null
  as_root chmod 0644 "$tim"

  as_root systemctl daemon-reload
  as_root systemctl enable --now "${FORM_IMPORT_UNIT}.timer"
  success "systemd timer enabled: ${FORM_IMPORT_UNIT}.timer (OnCalendar=${FORM_IMPORT_ONCALENDAR})"
  info "Status: systemctl status ${FORM_IMPORT_UNIT}.timer   Run now: systemctl start ${FORM_IMPORT_UNIT}.service"
}

# -----------------------------------------------------------------------------
# _forms_install_cron_job — daily /etc/cron.d entry (no systemd on this host).
# -----------------------------------------------------------------------------
_forms_install_cron_job() {
  local cronfile="/etc/cron.d/${FORM_IMPORT_UNIT}"
  printf '%s\n' \
    "# Written by the eRegister v1 installer — remove this file to disable the daily form import." \
    "SHELL=/bin/bash" \
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "${FORM_IMPORT_CRON} root ${FORM_IMPORT_RUNNER}" \
    | as_root tee "$cronfile" >/dev/null
  as_root chmod 0644 "$cronfile"
  success "Daily cron job installed: ${cronfile} (${FORM_IMPORT_CRON})"
}

# -----------------------------------------------------------------------------
# _forms_schedule — daily timer where systemd is available, else cron.d.
# -----------------------------------------------------------------------------
_forms_schedule() {
  if has_systemd; then
    _forms_install_systemd_timer
  elif [ -d /etc/cron.d ]; then
    warn "systemd not detected — falling back to a /etc/cron.d entry."
    _forms_install_cron_job
  else
    warn "Neither systemd nor /etc/cron.d is available. The runner was installed at"
    warn "${FORM_IMPORT_RUNNER} but NOT scheduled — add your own cron/timer entry:"
    warn "  ${FORM_IMPORT_CRON} root ${FORM_IMPORT_RUNNER}"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# run_form_import — one immediate run through the installed runner, so the
# forms are live now rather than after the first nightly firing.
# Advisory: the EMR often needs 30+ minutes to finish booting, so a failure
# here is reported and left for the timer (or a manual re-run) to pick up.
# -----------------------------------------------------------------------------
run_form_import() {
  info "Importing forms now from ${FORMS_DIR} (log: ${FORM_IMPORT_LOG}) …"
  if as_root "$FORM_IMPORT_RUNNER"; then
    success "Form import finished. Summary:"
    as_root tail -n 15 "$FORM_IMPORT_LOG" >&2 || true
    return 0
  fi
  warn "Form import did not complete cleanly (see ${FORM_IMPORT_LOG})."
  as_root tail -n 20 "$FORM_IMPORT_LOG" >&2 || true
  warn "This is usually just the EMR still booting — the daily job will retry,"
  warn "or run it by hand once the stack is up:  sudo ${FORM_IMPORT_RUNNER}"
  return 1
}

# -----------------------------------------------------------------------------
# install_form_import — top-level entry, called from main() after the concept
# import, and from the standalone import-forms.sh.
# Returns non-zero on failure; the caller treats that as advisory (the upgrade
# is already finalized by the time this runs).
# -----------------------------------------------------------------------------
install_form_import() {
  step "Clinical observation forms"

  if [ "${IMPORT_FORMS:-1}" != "1" ]; then
    info "Form import disabled (--no-forms / EREGISTER_IMPORT_FORMS=0); skipping."
    return 0
  fi

  if [ ! -d "$FORMS_DIR" ]; then
    error "Form folder not found: ${FORMS_DIR}"
    error "It is the clinical-obs-forms clone made by the upgrade — re-run the installer, or set EREGISTER_FORMS_DIR."
    return 1
  fi

  local count
  count="$(find "$FORMS_DIR" -name '*.json' -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')"
  info "Form definitions found in ${FORMS_DIR}: ${count}"
  info "They are imported over the REST API at ${BAHMNI_URL} as user '${BAHMNI_USER}',"
  info "exactly as the Implementer Interface's Import button would."
  info "Only forms whose content changed since the last run are deployed, and a"
  info "changed form goes out as a NEW version (the current one is never overwritten)."

  confirm "Install the form importer and import the clinical forms now?" \
    || { warn "Form import skipped by user."; return 0; }

  _forms_prompt_credentials || {
    warn "No EMR password available — skipping the form import and its schedule."
    warn "Set it up later with:  sudo EREGISTER_BAHMNI_PASS='…' ./import-forms.sh"
    return 1
  }

  # jq is not in the installer's own dependency set, but the importer needs it.
  if ! command -v jq >/dev/null 2>&1; then
    warn "The form importer needs 'jq', which is not installed."
    if [ -n "$PKG_MGR" ] && confirm "Install jq via ${PKG_MGR}?"; then
      pkg_install jq || { error "Could not install jq."; return 1; }
    else
      error "jq is required for the form import; install it and re-run ./import-forms.sh."
      return 1
    fi
  fi

  _forms_install_importer || return 1
  _forms_write_env
  _forms_write_runner

  local rc=0
  # A fresh upgrade has only just started the stack, and the EMR needs 30+
  # minutes before it answers REST calls — hence the way out here.
  if confirm "Import the forms now? ('n' leaves it to the daily job — the EMR may still be booting)"; then
    run_form_import || rc=1
  else
    info "Immediate import skipped; the scheduled job will do it (${FORM_IMPORT_CRON})."
  fi

  if confirm "Schedule the form import to run daily (${FORM_IMPORT_CRON})?"; then
    _forms_schedule || rc=1
  else
    info "Not scheduled. Run it by hand any time with: sudo ${FORM_IMPORT_RUNNER}"
  fi

  return "$rc"
}
