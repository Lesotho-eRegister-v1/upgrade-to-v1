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
# Exit status: 0 when everything resolves, 1 when anything is missing.
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

fail=0
probe() { # probe <path> -> prints a row, returns non-zero when not 200
  local path="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${RAW}/${path}" 2>/dev/null)" || code="000"
  if [ "$code" = "200" ]; then
    printf '  ok   %-38s %s\n' "$path" "$code"
  else
    printf '  MISS %-38s %s\n' "$path" "$code"
    return 1
  fi
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
if [ "$fail" = "0" ]; then
  printf 'PASS — every file the one-liners fetch is published on %s.\n' "$REF"
else
  printf 'FAIL — the one-liners would 404 for a site right now.\n'
  printf 'Push the missing files (git add -A && git commit && git push), wait a\n'
  printf 'minute for the raw CDN, then re-run this check.\n'
fi
exit "$fail"
