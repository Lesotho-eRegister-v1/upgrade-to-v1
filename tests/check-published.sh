#!/usr/bin/env bash
###############################################################################
# tests/check-published.sh — is everything the one-liners need actually
# published?
#
# The `curl … | bash` entry points fetch their modules from a branch on GitHub.
# If a file is referenced by a script but not pushed to that branch, the site
# running the one-liner gets:
#
#     curl: (56) The requested URL returned error: 404
#
# which names neither the file nor the reason. This script asks the question up
# front: for every entry script, does every module it lists exist at the raw
# base — and does the local checkout have anything that has not been pushed?
#
# RUN IT AFTER EVERY PUSH THAT ADDS OR RENAMES A FILE UNDER lib/ OR bin/.
#
# USAGE
#   ./tests/check-published.sh [ref]      # ref defaults to main
#
# ENV
#   EREGISTER_RAW_BASE   raw prefix to probe (default: this repo @ <ref>)
#
# Exit status: 0 when everything resolves, 1 when anything is missing or
# unpushed, 2 when the raw host would not answer (503/429 even after retries) —
# inconclusive, not a missing file.
###############################################################################
set -uo pipefail

REF="${1:-main}"
REPO_RAW="https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/${REF}"
RAW="${EREGISTER_RAW_BASE:-$REPO_RAW}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Entry scripts that self-bootstrap, plus the standalone helpers a site may curl.
ENTRIES=(install.sh import-concepts.sh import-forms.sh catch-up.sh ocl-fix.sh)
# Files fetched by modules rather than listed in an EREGISTER_MODULES array.
EXTRA=(bin/bahmni_form_import.sh)

fail=0        # a file is genuinely not published (404) -> the one-liners break
flaky=0       # the raw host would not answer (503/429/timeout) -> unknown
probe() { # probe <path> -> prints a row, returns non-zero when not 200
  local path="$1" code
  # --retry rides out the raw CDN's transient 429/5xx; without it a flapping
  # edge reads as "not published". Exponential backoff (no --retry-delay).
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
                --retry 4 --retry-max-time 60 \
                "${RAW}/${path}" 2>/dev/null)" || code="000"
  case "$code" in
    200)
      printf '  ok   %-38s %s\n' "$path" "$code" ;;
    429|5??|000)
      # Not a verdict on the file: the host never served an answer. Kept
      # separate from fail so a CDN wobble is not reported as a missing file.
      printf '  WARN %-38s %s (raw host unavailable — retried)\n' "$path" "$code"
      flaky=1 ;;
    *)
      printf '  MISS %-38s %s\n' "$path" "$code"
      return 1 ;;
  esac
}

printf 'Checking %s\n\n' "$RAW"

printf 'Entry scripts\n'
for e in "${ENTRIES[@]}"; do
  [ -f "${ROOT}/${e}" ] || continue
  probe "$e" || fail=1
done

# Each entry script's module list must resolve, or its one-liner dies mid-run.
for e in "${ENTRIES[@]}"; do
  [ -f "${ROOT}/${e}" ] || continue
  mods="$(sed -n '/^EREGISTER_MODULES=(/,/^)/p' "${ROOT}/${e}" | grep -oE '[a-z]+/[a-z]+\.sh')"
  [ -n "$mods" ] || continue
  printf '\nModules required by %s\n' "$e"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    probe "lib/${m}" || fail=1
  done <<<"$mods"
done

printf '\nOther fetched files\n'
for x in "${EXTRA[@]}"; do probe "$x" || fail=1; done

# The usual root cause: it exists locally, it just was never pushed.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  printf '\nLocal checkout\n'
  dirty="$(git -C "$ROOT" status --porcelain -- lib bin ./*.sh 2>/dev/null)"
  ahead="$(git -C "$ROOT" log --oneline "origin/${REF}..HEAD" 2>/dev/null | wc -l | tr -d ' ')"
  if [ -n "$dirty" ]; then
    printf '  uncommitted / untracked files that the one-liners would need:\n'
    printf '%s\n' "$dirty" | sed 's/^/    /'
    fail=1
  fi
  if [ "${ahead:-0}" != "0" ]; then
    printf '  %s commit(s) not pushed to origin/%s\n' "$ahead" "$REF"
    fail=1
  fi
  [ -z "$dirty" ] && [ "${ahead:-0}" = "0" ] && printf '  clean and in sync with origin/%s\n' "$REF"
fi

printf '\n'
if [ "$fail" != "0" ]; then
  printf 'FAIL — the one-liners would 404 for a site right now.\n'
  printf 'Push the missing files (git add -A && git commit && git push), wait a\n'
  printf 'minute for the raw CDN, then re-run this check.\n'
elif [ "$flaky" != "0" ]; then
  printf 'INCONCLUSIVE — nothing is missing (no 404s), but the raw host answered\n'
  printf '503/429 for some files even after retrying. That is GitHub throttling its\n'
  printf 'edge, not your repo; the scripts retry the same way, so installs mostly\n'
  printf 'ride it out. Re-run this check in a few minutes to confirm.\n'
else
  printf 'PASS — every file the one-liners fetch is published on %s.\n' "$REF"
fi
# 0 = published and reachable, 1 = something is missing or unpushed,
# 2 = inconclusive (the raw host would not answer; nothing is known to be wrong).
[ "$fail" = "0" ] || exit 1
[ "$flaky" = "0" ] || exit 2
exit 0
