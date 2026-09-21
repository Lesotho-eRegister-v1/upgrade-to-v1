# shellcheck shell=bash
# =============================================================================
# lib/upgrade/forms.sh — deploy the clinical observation forms and schedule the
# daily job that keeps them deployed.
#
# WHO LOADS THIS
#   ./catch-up.sh (via lib/upgrade/catchup.sh, which calls the _forms_* helpers
#   below one at a time so it can report on each) and ./import-forms.sh (via
#   install_form_import, the all-in-one entry at the bottom).
#
#   NOT install.sh. The forms are deployed over the EMR's REST API, and the EMR
#   needs 30+ minutes — hours on site hardware — before it answers one; at the
#   moment the upgrade finishes there is nothing to import into. The whole step
#   therefore belongs to catch-up, which is run once the stack is actually up.
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
  code="$(curl -sSL --retry 6 --retry-max-time 120 \
                --connect-timeout 15 \
                -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
  if [ "$code" != "200" ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    error "Could not download the form importer: HTTP ${code} for ${url}"
    error "A 503 or 429 is the raw CDN throttling — re-run this step in a minute."
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
      confirm "Try again? (answering 'n' skips the form import)" \
        "skip the form import" || return 1
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
# _forms_check_credentials <password> — ask the EMR whether BAHMNI_USER and this
# password log in.  0 = accepted, 1 = rejected, 2 = could not tell.
#
# "Could not tell" covers everything short of a real answer: the EMR still
# booting (it needs 30+ minutes), a proxy error page, curl failing outright. A
# password must never be thrown away on one of those — only an explicit
# authenticated:false, which OpenMRS sends with HTTP 200, counts as rejected.
#
# The credentials go to curl on stdin (-K -) rather than as -u, so the password
# never shows up in `ps` for the other users on the host.
# -----------------------------------------------------------------------------
_forms_check_credentials() {
  local cred="${BAHMNI_USER}:$1" out code body insecure=()
  [ "$FORM_IMPORT_INSECURE" = "1" ] && insecure=(-k)
  # curl config syntax: inside double quotes, \ and " must be escaped.
  cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"
  out="$(printf 'user = "%s"\n' "$cred" |
         curl -sS ${insecure[@]+"${insecure[@]}"} --connect-timeout 10 --max-time 60 \
              -K - -w '\n%{http_code}' "${BAHMNI_URL%/}/openmrs/ws/rest/v1/session" 2>/dev/null)" \
    || return 2
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  [ "$code" = "200" ] || return 2
  # Matched with a regex, not jq: jq may not be installed yet at this point.
  [[ "$body" =~ \"authenticated\"[[:space:]]*:[[:space:]]*(true|false) ]] || return 2
  [ "${BASH_REMATCH[1]}" = "true" ] && return 0
  return 1
}

# -----------------------------------------------------------------------------
# _forms_ensure_credentials — make FORM_IMPORT_ENV hold a password the EMR
# actually accepts, prompting for a new one when it does not.
#
#   0 = the env file is usable and was left untouched
#   3 = the env file was written (it was missing, or its password was rejected)
#   1 = no usable password — the scheduled import will fail
#
# FORMS_CRED_NOTE is set to a one-line description for the caller's report.
#
# Candidates, in order: EREGISTER_BAHMNI_PASS, then the stored password, then a
# prompt. A rejected candidate falls through to the next one; the prompt is
# retried a few times, but not endlessly — OpenMRS locks an account out after
# repeated failures. When the EMR is not answering nothing can be verified, so
# a stored file is kept as it is and the prompt is not re-asked.
# -----------------------------------------------------------------------------
_forms_ensure_credentials() {
  local had_env=0 stored_url="" stored_user="" stored_pass="" rc attempt
  FORMS_CRED_NOTE=""

  if as_root test -s "$FORM_IMPORT_ENV"; then
    had_env=1
    # Read the values the way the runner does — by sourcing the file — so a
    # password mangled by an older unquoted env file is tested as mangled.
    { IFS= read -r -d '' stored_url; IFS= read -r -d '' stored_user; IFS= read -r -d '' stored_pass; } < <(
      as_root bash -c 'set -a; . "$1" >/dev/null 2>&1
                       printf "%s\0%s\0%s\0" "${BAHMNI_URL:-}" "${BAHMNI_USER:-}" "${BAHMNI_PASS:-}"' \
        _ "$FORM_IMPORT_ENV" 2>/dev/null) || true
    # Test against the endpoint and account the daily job really uses.
    [ -n "$stored_url" ]  && BAHMNI_URL="$stored_url"
    [ -n "$stored_user" ] && BAHMNI_USER="$stored_user"
  fi

  # 1. A password handed in through the environment.
  if [ -n "${BAHMNI_PASS:-}" ]; then
    rc=0; _forms_check_credentials "$BAHMNI_PASS" || rc=$?
    if [ "$rc" = "0" ] && [ "$had_env" = "1" ] && [ "$BAHMNI_PASS" = "$stored_pass" ]; then
      FORMS_CRED_NOTE="present, password accepted by the EMR"
      return 0
    elif [ "$rc" = "0" ]; then
      _forms_write_env || return 1
      FORMS_CRED_NOTE="written for ${BAHMNI_USER}@${BAHMNI_URL} (password from EREGISTER_BAHMNI_PASS, accepted by the EMR)"
      return 3
    elif [ "$rc" = "1" ]; then
      warn "The EMR rejected the password in EREGISTER_BAHMNI_PASS for '${BAHMNI_USER}' at ${BAHMNI_URL}."
      BAHMNI_PASS=""
    elif [ "$had_env" = "1" ]; then
      FORMS_CRED_NOTE="present, left as-is (not verified — the EMR is not answering yet)"
      return 0
    else
      _forms_write_env || return 1
      FORMS_CRED_NOTE="written for ${BAHMNI_USER}@${BAHMNI_URL} (not verified — the EMR is not answering yet)"
      return 3
    fi
  fi

  # 2. The password already stored for the daily job.
  if [ "$had_env" = "1" ]; then
    rc=0; _forms_check_credentials "$stored_pass" || rc=$?
    case "$rc" in
      0) FORMS_CRED_NOTE="present, password accepted by the EMR"; return 0 ;;
      2) FORMS_CRED_NOTE="present, left as-is (not verified — the EMR is not answering yet)"; return 0 ;;
    esac
    warn "The EMR rejected the password stored in ${FORM_IMPORT_ENV} for '${BAHMNI_USER}' at ${BAHMNI_URL}."
    warn "The daily form import cannot log in until it is replaced."
  fi

  # 3. Ask. _forms_prompt_credentials refuses (returns 1) under --yes or with no TTY.
  for attempt in 1 2 3; do
    _forms_prompt_credentials || break
    rc=0; _forms_check_credentials "$BAHMNI_PASS" || rc=$?
    [ "$rc" = "1" ] || break
    warn "The EMR rejected that password for '${BAHMNI_USER}' (attempt ${attempt} of 3)."
    BAHMNI_PASS=""
  done

  if [ -z "${BAHMNI_PASS:-}" ]; then
    if [ "$had_env" = "1" ]; then
      FORMS_CRED_NOTE="stored password rejected by the EMR and no working one given — the daily form import will fail"
    else
      FORMS_CRED_NOTE="missing and no password given — the daily form import cannot run"
    fi
    return 1
  fi

  _forms_write_env || return 1
  if [ "$had_env" = "1" ]; then
    FORMS_CRED_NOTE="stored password was rejected by the EMR — replaced"
  else
    FORMS_CRED_NOTE="was missing — written for ${BAHMNI_USER}@${BAHMNI_URL}"
  fi
  [ "$rc" = "2" ] && FORMS_CRED_NOTE="${FORMS_CRED_NOTE} (not verified — the EMR is not answering yet)"
  return 3
}

# -----------------------------------------------------------------------------
# _forms_write_env — credentials + settings for the unattended runs.
# 0600 and root-owned: it holds a password, and both the timer and the cron
# entry run as root.
#
# Values are written with %q because the runner SOURCES this file: an unquoted
# password containing $ # ; & quotes or spaces would reach curl altered, and the
# EMR would answer authenticated:false to a password that looks right on disk.
# -----------------------------------------------------------------------------
_forms_write_env() {
  local tmp
  tmp="$(mktemp)"
  chmod 0600 "$tmp"
  {
    printf '%s\n' "# eRegister v1 — settings for the scheduled clinical form import."
    printf '%s\n' "# Written by ./catch-up.sh or ./import-forms.sh; re-running either overwrites it."
    printf '%s\n' "# Contains a password: keep it mode 0600. This file is sourced by bash, so"
    printf '%s\n' "# quote values when editing by hand, e.g. BAHMNI_PASS='my\$ecret'."
    printf 'BAHMNI_URL=%q\n'        "$BAHMNI_URL"
    printf 'BAHMNI_USER=%q\n'       "$BAHMNI_USER"
    printf 'BAHMNI_PASS=%q\n'       "$BAHMNI_PASS"
    printf 'BAHMNI_FORMS_DIR=%q\n'  "$FORMS_DIR"
    printf 'BAHMNI_STATE_FILE=%q\n' "$FORM_IMPORT_STATE"
    printf 'BAHMNI_INSECURE=%q\n'   "$FORM_IMPORT_INSECURE"
    printf 'BAHMNI_PUBLISH=%q\n'    "${FORM_PUBLISH:-1}"
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
# this is safe to run every day. Installed by ./catch-up.sh (or ./import-forms.sh);
# safe to run by hand.
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

# See autopull's copy: the clone may be owned by root or by the operator, and
# git refuses a repo owned by "someone else" unless told otherwise.
git_here() { git -c safe.directory='*' "$@"; }

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
  if ! branch="$(git_here -C "$FORMS_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
    log "SKIP  refresh (git cannot read $FORMS_DIR — ownership or permissions)"
    branch=""
  fi
  if [ -z "$branch" ]; then
    :
  elif [ "$branch" = "HEAD" ]; then
    log "SKIP  refresh ($FORMS_DIR is on a detached HEAD)"
  elif [ -n "$(git_here -C "$FORMS_DIR" status --porcelain 2>/dev/null)" ]; then
    log "SKIP  refresh ($FORMS_DIR has uncommitted local changes)"
  elif git_here -C "$FORMS_DIR" fetch --depth 1 origin "$branch" >>"$LOG" 2>&1 &&
       git_here -C "$FORMS_DIR" reset --hard "origin/$branch" >>"$LOG" 2>&1; then
    log "OK    refreshed $FORMS_DIR ($branch @ $(git_here -C "$FORMS_DIR" rev-parse --short HEAD 2>/dev/null))"
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
    "# Written by ./catch-up.sh (or ./import-forms.sh) — re-running either overwrites it." \
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
    "# Written by ./catch-up.sh (or ./import-forms.sh) — re-running either overwrites it." \
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
    "# Written by ./catch-up.sh (or ./import-forms.sh) — remove this file to disable the daily form import." \
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
# _forms_sql_quote — make a value safe to drop inside a single-quoted MySQL
# string. Backslash first (it is MySQL's own escape character, so doubling it
# after the quotes would double the quotes' escapes too), then the quote.
# -----------------------------------------------------------------------------
_forms_sql_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\'\'}"
  printf '%s' "$s"
}

# -----------------------------------------------------------------------------
# _forms_retire_stale — retire the forms this deployment is about to replace.
#
# WHAT IT RUNS
#   UPDATE form SET retired = 1, retired_by = <FORM_RETIRE_BY>,
#          date_retired = NOW(), retire_reason = '<FORM_RETIRE_REASON>'
#   WHERE name LIKE '<FORM_RETIRE_NAME_LIKE>' AND retired = 0;
#
#   OpenMRS retires rather than deletes: the rows stay, every observation ever
#   recorded against those forms keeps resolving, and the forms simply stop
#   being offered. One statement undoes it (the report prints it).
#
# WHY IT RUNS HERE AND NOT AS A STEP OF ITS OWN
#   It is half of one operation — retire the outgoing set, deploy the incoming
#   one — and the halves must not come apart. A run that retired the 2026 forms
#   and then did not import would leave the site with nothing to fill in. So it
#   is called from _cu_forms_import, AFTER the operator has agreed to the import
#   and the credentials have been verified, immediately before the importer.
#
# WHY IT CLEARS sha256 IN THE IMPORT STATE
#   The importer deploys a form only when its file changed since the last run
#   (sha256 per form, in FORM_IMPORT_STATE). Retiring a form does not change its
#   file — so without this, the very forms just retired would be skipped as
#   "unchanged" and the site would be left with no live copy of them at all.
#   Only the hash is cleared, never the recorded version: the importer takes
#   max(state version, server version) + 1, and a retired form is not in the
#   server's answer, so dropping the version could make it redeploy a number
#   that already exists on a retired row.
#
# Sets, for the caller to report on:
#   FORMS_RETIRE_STATUS  retired | none | disabled | declined | no-db | failed
#   FORMS_RETIRE_DETAIL  one line explaining that status
#   FORMS_RETIRE_COUNT   how many live forms matched (and so were retired)
#
# Returns non-zero only when the UPDATE was attempted and failed. "Nothing
# matched", "disabled" and "the operator said no" are successes — the database
# is unchanged and the next run can try again.
#
# Depends on the DB plumbing in concepts.sh (_concepts_mysql,
# _concepts_resolve_compose, _concepts_db_ready). catch-up.sh sources that
# module; the standalone ./import-forms.sh does not, and there the step reports
# no-db and changes nothing.
# -----------------------------------------------------------------------------
_forms_retire_stale() {
  FORMS_RETIRE_STATUS=""; FORMS_RETIRE_DETAIL=""; FORMS_RETIRE_COUNT=0

  if [ "${FORM_RETIRE:-1}" != "1" ]; then
    info "Form retirement disabled (--no-retire-forms / EREGISTER_FORM_RETIRE=0); skipping."
    FORMS_RETIRE_STATUS="disabled"
    FORMS_RETIRE_DETAIL="left alone (--no-retire-forms)"
    return 0
  fi

  if ! declare -F _concepts_mysql >/dev/null 2>&1; then
    FORMS_RETIRE_STATUS="no-db"
    FORMS_RETIRE_DETAIL="database plumbing (concepts.sh) is not loaded — nothing retired"
    return 0
  fi
  if ! _concepts_resolve_compose >/dev/null 2>&1; then
    FORMS_RETIRE_STATUS="no-db"
    FORMS_RETIRE_DETAIL="docker compose is not available on this host"
    return 0
  fi
  if [ ! -d "$RESTORE_DIR" ]; then
    FORMS_RETIRE_STATUS="no-db"
    FORMS_RETIRE_DETAIL="no stack directory at ${RESTORE_DIR}"
    return 0
  fi
  # One probe, no polling — same reasoning as the concept import and idgen: a
  # database that is still booting should cost one question, not a hang.
  if ! _concepts_db_ready; then
    warn "${DB_SERVICE}:${DB_NAME} is not accepting connections right now."
    FORMS_RETIRE_STATUS="no-db"
    FORMS_RETIRE_DETAIL="${DB_SERVICE}:${DB_NAME} not reachable — nothing retired"
    return 0
  fi

  local like reason names count
  like="$(_forms_sql_quote "$FORM_RETIRE_NAME_LIKE")"
  reason="$(_forms_sql_quote "$FORM_RETIRE_REASON")"

  # Look before writing: the report should name what was retired, and the names
  # are needed afterwards to clear their hashes out of the import state.
  names="$(printf "SELECT name FROM form WHERE name LIKE '%s' AND retired = 0 ORDER BY name;\n" \
             "$like" | _concepts_mysql -N 2>/dev/null)" || names=""
  # `|| true`: grep -c exits 1 on no matches, and no match is a normal outcome.
  count="$(printf '%s\n' "$names" | grep -c . || true)"
  FORMS_RETIRE_COUNT="${count:-0}"

  if [ "${count:-0}" -eq 0 ]; then
    success "No live form matches name LIKE '${FORM_RETIRE_NAME_LIKE}'; nothing to retire."
    FORMS_RETIRE_STATUS="none"
    FORMS_RETIRE_DETAIL="no live form matches name LIKE '${FORM_RETIRE_NAME_LIKE}' in ${DB_NAME}"
    return 0
  fi

  info "${count} live form(s) in '${DB_NAME}' match name LIKE '${FORM_RETIRE_NAME_LIKE}':"
  printf '%s\n' "$names" | sed 's/^/    • /' >&2
  warn "Retiring them stops them being offered. The rows are kept and the"
  warn "observations already recorded against them are NOT touched — this is reversible."
  if ! confirm "Retire these ${count} form(s) before importing?"; then
    warn "Form retirement skipped by user; the import below still runs."
    FORMS_RETIRE_STATUS="declined"
    FORMS_RETIRE_DETAIL="declined — ${count} matching form(s) left live"
    return 0
  fi

  if ! printf "UPDATE form
SET retired = 1,
    retired_by = %s,
    date_retired = NOW(),
    retire_reason = '%s'
WHERE name LIKE '%s'
  AND retired = 0;\n" "$FORM_RETIRE_BY" "$reason" "$like" | _concepts_mysql
  then
    error "Could not retire the forms matching name LIKE '${FORM_RETIRE_NAME_LIKE}'."
    FORMS_RETIRE_STATUS="failed"
    FORMS_RETIRE_DETAIL="the UPDATE failed for name LIKE '${FORM_RETIRE_NAME_LIKE}'"
    return 1
  fi

  # Read it back rather than trusting the exit status: mysql reports success for
  # an UPDATE that matched nothing at all.
  local left
  left="$(printf "SELECT COUNT(*) FROM form WHERE name LIKE '%s' AND retired = 0;\n" \
            "$like" | _concepts_mysql -N 2>/dev/null | tr -d '[:space:]')" || left=""
  if [ "${left:-1}" != "0" ]; then
    error "The UPDATE ran but ${left:-some} form(s) matching '${FORM_RETIRE_NAME_LIKE}' are still live."
    FORMS_RETIRE_STATUS="failed"
    FORMS_RETIRE_DETAIL="${left:-some} form(s) still live after the UPDATE"
    return 1
  fi

  _forms_forget_state "$names"

  success "Retired ${count} form(s) matching name LIKE '${FORM_RETIRE_NAME_LIKE}'."
  info "Undo it with:"
  info "  UPDATE form SET retired = 0, retired_by = NULL, date_retired = NULL,"
  info "         retire_reason = NULL WHERE retire_reason = '${FORM_RETIRE_REASON}';"
  FORMS_RETIRE_STATUS="retired"
  FORMS_RETIRE_DETAIL="${count} form(s) retired (reason: ${FORM_RETIRE_REASON})"
  return 0
}

# -----------------------------------------------------------------------------
# _forms_forget_state <names-one-per-line> — blank the recorded sha256 of those
# forms in FORM_IMPORT_STATE so the importer stops calling them "unchanged".
#
# The state file is keyed "<server url>|<form name>", so the match is on the
# part after the first '|'. The recorded version is deliberately LEFT ALONE —
# see the note in _forms_retire_stale.
#
# Best effort by design: no jq, no state file, or an unwritable one are all
# reported as a warning and nothing more. The retirement above has already
# happened and is the thing that mattered; the operator can force the redeploy
# by hand with `sudo FORM_IMPORT_SCRIPT --force -r FORMS_DIR`.
# -----------------------------------------------------------------------------
_forms_forget_state() {
  local names="$1" tmp mode

  if ! command -v jq >/dev/null 2>&1; then
    warn "jq is not installed — cannot clear the import state for the retired forms."
    warn "They may be skipped as 'unchanged'. Force them with:"
    warn "  sudo ${FORM_IMPORT_SCRIPT} --force -r ${FORMS_DIR}"
    return 0
  fi
  if ! as_root test -s "$FORM_IMPORT_STATE"; then
    # Nothing recorded means nothing will be skipped. Silence is correct here.
    return 0
  fi

  # Keep the file's existing mode. It holds no secrets — form names, versions
  # and hashes — and forcing it to 0600 root would lock out a later importer run
  # started as the operator rather than through the root-owned runner.
  mode="$(as_root stat -c '%a' "$FORM_IMPORT_STATE" 2>/dev/null)" || mode=""
  case "$mode" in ([0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;; (*) mode="644" ;; esac

  tmp="$(mktemp)"
  if as_root cat "$FORM_IMPORT_STATE" 2>/dev/null \
     | jq --arg names "$names" '
         ($names | split("\n") | map(select(length > 0))) as $n
         | with_entries(
             (.key | sub("^[^|]*\\|"; "")) as $nm
             | if ($n | index($nm)) then .value.sha256 = "" else . end)' >"$tmp" 2>/dev/null \
     && [ -s "$tmp" ]
  then
    as_root install -m "$mode" "$tmp" "$FORM_IMPORT_STATE"
    rm -f "$tmp"
    info "Cleared the recorded hash of the retired forms so the import redeploys them."
  else
    rm -f "$tmp"
    warn "Could not rewrite ${FORM_IMPORT_STATE}; the retired forms may be skipped as"
    warn "'unchanged'. Force them with:  sudo ${FORM_IMPORT_SCRIPT} --force -r ${FORMS_DIR}"
  fi
  return 0
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
# _forms_decode_entities — un-escape HTML entities in the form JSON the EMR
# keeps INSIDE its own container (FORM_DECODE_DIR in the EMR_SERVICE service).
#
# WHY
#   A deployed form can come back out of the EMR with the markup in its labels
#   HTML-escaped — &amp; &lt; &gt; where the author wrote & < >. The clinical app
#   then renders the entity text itself, and forms that reference those fields
#   throw errors. The fix is textual: decode the three entities in place.
#
# WHY REPEATEDLY
#   The escaping nests. &amp;lt; is "&lt;" that was escaped a second time, and
#   one pass over it only gets back as far as &lt; — so a single pass can leave
#   a file that is still wrong, and still wrong in a way the same pass would
#   fix. It therefore runs again until a pass finds nothing left to change,
#   rather than a fixed number of times: five levels of nesting take five passes,
#   a site with one stops after the second, and FORM_DECODE_MAX_PASSES caps it
#   so a pathological file cannot spin forever.
#
# Idempotent, and cheap on a clean folder: the first pass matches nothing and it
# stops there. That is what makes it safe on every catch-up run.
#
# It runs BEFORE the EMR is recreated at the end of a catch-up, so the reloaded
# instance reads the decoded files.
#
# Sets FORMS_DECODE_NOTE (one line for the caller's report) and
# FORMS_DECODE_FILES (how many file rewrites it took). Returns:
#   0  clean — nothing left escaped
#   1  could not run (no docker compose, no stack dir, exec failed)
#   3  FORM_DECODE_DIR does not exist inside the container
#   4  still escaped after FORM_DECODE_MAX_PASSES passes
# -----------------------------------------------------------------------------
_forms_decode_entities() {
  FORMS_DECODE_NOTE=""
  FORMS_DECODE_FILES=0
  local script out rc=0 decoded passes

  # Same resolution the other container-facing modules do, so this works when
  # forms.sh is loaded without concepts.sh (./import-forms.sh).
  if [ -z "${DOCKER_COMPOSE:-}" ]; then
    if docker compose version >/dev/null 2>&1; then DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then DOCKER_COMPOSE="docker-compose"
    else
      FORMS_DECODE_NOTE="docker compose is not available on this host"
      return 1
    fi
  fi
  if [ ! -d "$RESTORE_DIR" ]; then
    FORMS_DECODE_NOTE="no stack directory at ${RESTORE_DIR}"
    return 1
  fi

  # The remote half, fed to `sh -s` on the container's stdin rather than wrapped
  # in `sh -c '…'`: the loop below is full of quotes, and one level of shell
  # quoting is enough for anybody. `find … -exec sh -c '…' _ {} +` (not -exec on
  # each match) keeps it to a couple of processes and copes with the spaces and
  # apostrophes in names like "HIV Treatment and Care Intake (Counselor's)_2.json".
  IFS= read -r -d '' script <<'REMOTE' || true
dir="${1:-}"; max="${2:-5}"
[ -n "$dir" ] || { echo "no folder given"; exit 2; }
[ -d "$dir" ] || { echo "not found: $dir"; exit 3; }

pass=1
while [ "$pass" -le "$max" ]; do
  hits="$(find "$dir" -type f -name '*.json' -exec sh -c '
            for f do
              grep -qE "&amp;|&lt;|&gt;" "$f" || continue
              sed -i -e "s/&amp;/\&/g" -e "s/&lt;/</g" -e "s/&gt;/>/g" "$f" \
                && printf "%s\n" "$f"
            done' _ {} + )"
  if [ -z "$hits" ]; then
    echo "clean after ${pass} pass(es)"
    exit 0
  fi
  printf '%s\n' "$hits" | sed 's/^/  decoded: /'
  pass=$(( pass + 1 ))
done
echo "still escaped after ${max} pass(es)"
exit 4
REMOTE

  info "Decoding HTML entities in ${EMR_SERVICE}:${FORM_DECODE_DIR} (up to ${FORM_DECODE_MAX_PASSES} passes) …"
  out="$( cd "$RESTORE_DIR" && printf '%s' "$script" \
          | as_root $DOCKER_COMPOSE exec -T "$EMR_SERVICE" \
              sh -s -- "$FORM_DECODE_DIR" "$FORM_DECODE_MAX_PASSES" 2>&1 )" || rc=$?
  # An `if`, not `[ -n … ] && log …`: as the value of the last statement that
  # would make the function return non-zero on a silent run, under `set -e`.
  if [ -n "$out" ]; then log "$out"; fi

  # `|| true`: grep -c exits 1 on no matches, and "no file was rewritten" is the
  # good outcome here, not a failure.
  decoded="$(printf '%s\n' "$out" | grep -c '^  decoded: ' || true)"
  passes="$(printf '%s\n' "$out" | sed -n 's/^clean after \([0-9]*\) .*/\1/p' | tail -1)"
  FORMS_DECODE_FILES="${decoded:-0}"

  case "$rc" in
    0)
      if [ "${decoded:-0}" -eq 0 ]; then
        FORMS_DECODE_NOTE="nothing escaped in ${EMR_SERVICE}:${FORM_DECODE_DIR}"
      else
        FORMS_DECODE_NOTE="${decoded} file rewrite(s) in ${EMR_SERVICE}:${FORM_DECODE_DIR}; clean on pass ${passes:-?}"
      fi
      return 0 ;;
    3)
      FORMS_DECODE_NOTE="${FORM_DECODE_DIR} does not exist in the '${EMR_SERVICE}' container — set EREGISTER_FORM_DECODE_DIR"
      return 3 ;;
    4)
      FORMS_DECODE_NOTE="still escaped after ${FORM_DECODE_MAX_PASSES} pass(es) — raise EREGISTER_FORM_DECODE_MAX_PASSES and re-run"
      return 4 ;;
    *)
      FORMS_DECODE_NOTE="could not run in '${EMR_SERVICE}' (rc=${rc}): $(printf '%s' "$out" | tail -1)"
      return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# install_form_import — all-in-one entry: install, credential, schedule and run.
# Used by the standalone import-forms.sh. install.sh does NOT call it (see WHO
# LOADS THIS at the top), and catch-up.sh does not either — catch-up drives the
# _forms_* helpers directly so it can report a row per piece.
# Returns non-zero on failure.
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

  # Keeps a stored password the EMR accepts; prompts when it is missing or rejected.
  local cred_rc=0
  _forms_ensure_credentials || cred_rc=$?
  if [ "$cred_rc" = "1" ]; then
    warn "No working EMR password (${FORMS_CRED_NOTE}) — skipping the form import and its schedule."
    warn "Set it up later with:  sudo EREGISTER_BAHMNI_PASS='…' ./import-forms.sh"
    return 1
  fi
  info "Credentials: ${FORMS_CRED_NOTE}"

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
