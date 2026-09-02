# shellcheck shell=bash
# =============================================================================
# lib/core/prompt.sh — interactive confirmation that never reads from stdin
# (stdin is the script itself when piped into bash; we always use /dev/tty).
# Depends on: logging, rollback() (lib/upgrade/rollback.sh) for confirm_step.
# =============================================================================
# -----------------------------------------------------------------------------
# confirm — ask a yes/no question on /dev/tty.
#
#     confirm "Question?" [what a 'no' costs here]   ->  0 = yes, 1 = no
#
# WHY THE SECOND ARGUMENT, AND THE LOOP
#   Unrecognised input used to be silently taken as a NO. At a confirm_step that
#   ended the whole upgrade — rolling back a frozen stack — because someone hit
#   the wrong key and pressed Enter. A mistyped answer is not an answer, so it
#   no longer counts as one: the question is repeated instead, and the operator
#   is asked once whether stopping is what they actually meant.
#
#   That escape question has to be honest about what stopping DOES, and that
#   differs per caller: at a confirm_step a 'no' aborts the run, at most other
#   prompts it just skips that step. Hence the optional second argument, used to
#   fill in "Did you mean to ___?". Callers whose 'no' merely skips something can
#   leave it out.
#
# A bare Enter is still a NO. The '[y/N]' in the prompt advertises exactly that,
# and only something actually TYPED can be a typo.
# -----------------------------------------------------------------------------
confirm() {
  local prompt="$1" no_means="${2:-skip this step}" reply=""
  if [ "$ASSUME_YES" = "1" ]; then
    info "${prompt} -> yes (non-interactive)"
    return 0
  fi
  if [ ! -r /dev/tty ]; then
    error "No TTY available for prompt: '${prompt}'. Re-run with --yes for non-interactive mode."
    return 1
  fi

  while :; do
    printf '%s%s [y/N]: %s' "$C_WARN" "$prompt" "$C_RESET" >/dev/tty
    # A FAILED read is end-of-input, not an empty answer: the terminal is gone,
    # so nothing better is coming and re-asking would spin forever. Take the
    # advertised default and say so. (An empty line, by contrast, reads fine.)
    if ! read -r reply </dev/tty; then
      printf '\n' >/dev/tty
      warn "End of input on /dev/tty — taking the default (no) for: ${prompt}"
      return 1
    fi
    case "$reply" in
      [yY]|[yY][eE][sS])  return 0 ;;
      ''|[nN]|[nN][oO])   return 1 ;;
      *)
        warn "'${reply}' is neither yes nor no."
        if _confirm_meant_to_stop "$no_means"; then
          return 1
        fi
        info "Nothing done — asking again."
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# _confirm_meant_to_stop — the way out offered after unrecognised input.
#   0 = yes, the caller should take that as a 'no' after all
#   1 = go back and re-ask the original question
#
# Deliberately strict and NON-recursive: only an explicit yes stops, and
# anything else — another typo, a blank line, end of input — returns to the
# question. Two prompts that can each be mistyped indefinitely is not a trap
# worth building, and the conservative answer here is always "keep asking".
# -----------------------------------------------------------------------------
_confirm_meant_to_stop() {
  local no_means="$1" reply=""
  printf '%sPlease answer y or n. Did you mean to %s? [y/N]: %s' \
    "$C_WARN" "$no_means" "$C_RESET" >/dev/tty
  read -r reply </dev/tty || { printf '\n' >/dev/tty; return 1; }
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

confirm_step() {
  # Gate a single migration step. Declining aborts cleanly — and if the old
  # stack was already frozen, it rolls back first so you are never left in a
  # half-upgraded state. Honors --yes / EREGISTER_ASSUME_YES (auto-confirms).
  local what="$1"
  if confirm "Next step: ${what} — proceed?" "stop the upgrade here"; then
    return 0
  fi
  warn "Step declined by user: ${what}"
  if [ "$OLD_STACK_STOPPED" = "1" ] && [ "$UPGRADE_COMPLETE" != "1" ]; then
    rollback
  fi
  error "Upgrade aborted by user before completion. No further changes made."
  exit 1
}

prompt_db_password() {
  # Obtain the OpenMRS DB password without ever reading from the script's stdin.
  # Priority: 1) EREGISTER_DB_PASS env var, 2) silent prompt from /dev/tty.
  if [ -n "${DB_PASS:-}" ]; then
    info "Using OpenMRS DB password from environment (EREGISTER_DB_PASS)."
    return 0
  fi
  if [ "$ASSUME_YES" = "1" ]; then
    error "Non-interactive mode but no DB password set. Provide it via EREGISTER_DB_PASS."
    exit 1
  fi
  if [ ! -r /dev/tty ]; then
    error "No TTY available to prompt for the DB password. Set EREGISTER_DB_PASS instead."
    exit 1
  fi
  local p1 p2
  while :; do
    printf '%sEnter OpenMRS (%s) password for user '\''%s'\'': %s' \
      "$C_WARN" "$DB_NAME" "$DB_USER" "$C_RESET" >/dev/tty
    IFS= read -rs p1 </dev/tty; printf '\n' >/dev/tty   # -s: no echo
    if [ -z "$p1" ]; then warn "Password cannot be empty."; continue; fi
    printf '%sConfirm password: %s' "$C_WARN" "$C_RESET" >/dev/tty
    IFS= read -rs p2 </dev/tty; printf '\n' >/dev/tty
    if [ "$p1" != "$p2" ]; then warn "Passwords do not match — try again."; continue; fi
    DB_PASS="$p1"; break
  done
  success "Password captured."
}
