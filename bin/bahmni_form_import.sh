#!/usr/bin/env bash
#
# bahmni_form_import.sh — import a Bahmni Form Builder JSON export from the terminal.
#
# Reproduces exactly what the Implementer Interface "Import" button does:
#
#   1. concept UUID fix-up    GET  /openmrs/ws/rest/v1/concept?q=<name>
#                                  &source=byFullySpecifiedName&v=custom:(uuid,name:(name))
#   2. create the form        POST /openmrs/ws/rest/v1/form
#   3. save the form body     POST /openmrs/ws/rest/v1/bahmniie/form/save
#   4. save translations      POST /openmrs/ws/rest/v1/bahmniie/form/saveTranslation
#   5. save name translations POST /openmrs/ws/rest/v1/bahmniie/form/name/saveTranslation
#                                  (only when resources[1] exists)
#   6. publish the form       POST /openmrs/ws/rest/v1/bahmniie/form/publish?formUuid=<uuid>
#
# Step 6 is the one thing the "Import" button does NOT do. In the Implementer
# Interface, importing leaves the form in Draft — you then click "Publish"
# separately, and until you do, the form is not offered in the clinical app.
# Deploying dozens of forms and then clicking Publish dozens of times is exactly
# the work this script exists to remove, so it publishes by default.
# --no-publish leaves the forms as drafts, reproducing the button exactly.
#
# Publishing is RE-ASSERTED, not done once: a form that is skipped as unchanged
# is still checked, and published if it is not. That is what fixes a site whose
# forms were deployed before this script published anything. It also means a
# form you deliberately unpublish by hand is published again by the next run —
# use --no-publish on a site where that matters.
#
# Difference from the browser: concept lookups are de-duplicated, sequential and
# retried instead of fired as ~1700 parallel fetches, which is what produces the
# "Failed to fetch" wall of errors in importErrors.txt.
#
# Requires: bash 4+, curl, jq.
#
# Usage:
#   export BAHMNI_URL=https://localhost
#   export BAHMNI_USER=superman
#   export BAHMNI_PASS='...'          # or omit and be prompted
#   ./bahmni_form_import.sh -k "HIV Treatment and Care Follow Up_2.json"
#
# Arguments may be files or folders. A folder imports every *.json file it
# holds, in name order; add -r to descend into subfolders as well.
#
#   ./bahmni_form_import.sh -k clinical-obs-forms/    # every form in the folder
#
# To publish forms that are already deployed, without re-importing any of them:
#
#   ./bahmni_form_import.sh -k --publish-only -r clinical-obs-forms/
#   ./bahmni_form_import.sh -k -r clinical-obs-forms/ # ...and its subfolders
#   ./bahmni_form_import.sh -k --dry-run form.json    # validate concepts only
#
# The deployed form folder (no arguments)
#
# Called with no path at all it imports the clinical-obs-forms clone of the v1
# deployment — the repo the auto-pull job keeps in sync — recursively:
#
#   ${BAHMNI_FORMS_DIR:-${eRegister_HOME:-/var/lib/v1}/clinical-obs-forms}
#
# That is the form of the call the daily cron job / systemd timer makes, so a
# form pushed to clinical-obs-forms lands in the EMR on the next run and
# nothing else does.
#
#   ./bahmni_form_import.sh -k                        # import the deployed folder
#   BAHMNI_FORMS_DIR=/some/other/forms ./bahmni_form_import.sh -k
#
# Versioning and change detection
#
# Every successful import is recorded in a state file — an existing
# .bahmni_import_state.json beside this script when there is one (so a checkout
# keeps its history), otherwise .bahmni_form_import_state.json in the parent of
# the form folder (i.e. /var/lib/v1/.bahmni_form_import_state.json for the
# deployed folder above, out of reach of the auto-pull job's `git reset --hard`).
# It is keyed by server URL + form name, and holds the version that was
# deployed and a sha256 of the source file:
#
#   * file unchanged since its last import -> skipped, nothing is deployed
#   * file changed                         -> deployed as a NEW version,
#                                             max(recorded, server) + 1
#
# So a whole folder can be re-run as often as you like and only the forms you
# actually edited move. --force imports regardless, --no-bump restores the old
# overwrite-the-current-version behaviour, and an explicit --version pins the
# number instead of computing it.
#
#   ./bahmni_form_import.sh -k                        # deploy only what changed
#   ./bahmni_form_import.sh -k --force                # ignore the state file
#   ./bahmni_form_import.sh -k --state ci.json        # per-environment state
#
# The hash is of the file's CONTENT, not its name or timestamp, so a form
# replaced by a same-named file with different content is treated as new work
# and deployed as the next version, while a file that is merely re-checked-out,
# re-downloaded or renamed is recognised as already deployed and skipped.

# Deliberately POSIX so that `sh bahmni_form_import.sh` reaches this line and
# reports something readable instead of "Illegal option -o pipefail".
if [ -z "${BASH_VERSION:-}" ]; then
  echo "this script needs bash, not sh/dash." >&2
  echo "run it as ./bahmni_form_import.sh or 'bash bahmni_form_import.sh'" >&2
  exit 1
fi

set -uo pipefail

BASE_URL="${BAHMNI_URL:-https://localhost}"
USERNAME="${BAHMNI_USER:-superman}"
PASSWORD="${BAHMNI_PASS:-}"
INSECURE=""
FORM_VERSION="1"
VERSION_EXPLICIT=0
DELAY="0.02"
DRY_RUN=0
FORCE=0
BUMP=1
STATE_FILE="${BAHMNI_STATE_FILE:-}"
SKIP_VALIDATION=0
VERBOSE=0
RECURSIVE=0
# Publish each form after deploying it, and re-assert publication on forms that
# were skipped as unchanged. 0 (or --no-publish) leaves them as drafts.
PUBLISH="${BAHMNI_PUBLISH:-1}"
# Publish and NOTHING else: no concept resolution, no POST /form, no version
# bump. For a site whose forms are deployed but sitting in Draft.
PUBLISH_ONLY=0
INPUTS=()

# Folder used when the script is called with no path at all: the clinical-obs-forms
# clone of the v1 deployment. eRegister_HOME is exported by the installer
# (<install-base>/v1); the literal default keeps a hand/cron invocation working
# without it.
FORMS_DIR="${BAHMNI_FORMS_DIR:-${eRegister_HOME:-/var/lib/v1}/clinical-obs-forms}"

CONCEPT_URL="/openmrs/ws/rest/v1/concept"
FORM_URL="/openmrs/ws/rest/v1/form"
FORM_SAVE_URL="/openmrs/ws/rest/v1/bahmniie/form/save"
SAVE_TRANSLATION_URL="/openmrs/ws/rest/v1/bahmniie/form/saveTranslation"
SAVE_NAME_TRANSLATION_URL="/openmrs/ws/rest/v1/bahmniie/form/name/saveTranslation"
PUBLISH_URL="/openmrs/ws/rest/v1/bahmniie/form/publish"

# Print the header comment block, so the docs above can grow without the line
# numbers here going stale.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)             BASE_URL="$2"; shift 2 ;;
    --user)            USERNAME="$2"; shift 2 ;;
    --password)        PASSWORD="$2"; shift 2 ;;
    -k|--insecure)     INSECURE="-k"; shift ;;
    --version)         FORM_VERSION="$2"; VERSION_EXPLICIT=1; shift 2 ;;
    --delay)           DELAY="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --skip-validation) SKIP_VALIDATION=1; shift ;;
    --state)           STATE_FILE="$2"; shift 2 ;;
    -f|--force)        FORCE=1; shift ;;
    --publish)         PUBLISH=1; shift ;;
    --no-publish)      PUBLISH=0; shift ;;
    --publish-only)    PUBLISH_ONLY=1; PUBLISH=1; shift ;;
    --no-bump)         BUMP=0; shift ;;
    -v|--verbose)      VERBOSE=1; shift ;;
    -r|--recursive)    RECURSIVE=1; shift ;;
    -h|--help)         usage 0 ;;
    -*)                echo "unknown option: $1" >&2; usage 1 ;;
    *)                 INPUTS+=("$1"); shift ;;
  esac
done

# No path given: fall back to the deployed clinical-obs-forms folder, scanned
# recursively so forms filed under subfolders are picked up too.
if [[ ${#INPUTS[@]} -eq 0 ]]; then
  if [[ -d "$FORMS_DIR" ]]; then
    echo "no path given — importing the deployed form folder $FORMS_DIR"
    INPUTS=("$FORMS_DIR")
    RECURSIVE=1
  else
    echo "no path given, and the default form folder does not exist: $FORMS_DIR" >&2
    echo "pass a file/folder, or set BAHMNI_FORMS_DIR / eRegister_HOME" >&2
    usage 1
  fi
fi

# Preflight. Fail here with a clear message rather than half way through an
# import: macOS ships bash 3.2 as /bin/bash (no globstar, no associative
# arrays), and a minimal Ubuntu server often has neither curl nor jq.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "bash 4+ required, running under $BASH_VERSION" >&2
  echo "  macOS:  brew install bash   (then re-run; the shebang picks it up)" >&2
  echo "  Ubuntu: should already be bash 5 — check the shebang / how it was invoked" >&2
  exit 1
fi

for bin in curl jq awk; do
  command -v "$bin" >/dev/null || {
    echo "missing dependency: $bin" >&2
    echo "  Ubuntu: sudo apt-get install -y curl jq" >&2
    echo "  macOS:  brew install curl jq" >&2
    exit 1; }
done

# sha256: coreutils on Ubuntu, perl's shasum on macOS. Either will do.
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || {
  echo "missing dependency: sha256sum or shasum (needed for change detection)" >&2
  echo "  Ubuntu: sudo apt-get install -y coreutils" >&2
  exit 1; }

# ------------------------------------------------------------------ inputs
#
# An argument may be a form file or a folder of them. Folders expand to their
# *.json files in name order (--recursive descends into subfolders too), so a
# whole export directory can be imported in one run.

EXIT_CODE=0
FILES=()
shopt -s nullglob
[[ $RECURSIVE -eq 1 ]] && shopt -s globstar

for ARG in "${INPUTS[@]}"; do
  if [[ -d "$ARG" ]]; then
    DIR="${ARG%/}"
    if [[ $RECURSIVE -eq 1 ]]; then
      MATCHES=("$DIR"/**/*.json)
    else
      MATCHES=("$DIR"/*.json)
    fi
    FOUND=()
    for M in "${MATCHES[@]}"; do
      [[ -f "$M" ]] && FOUND+=("$M")
    done
    if [[ ${#FOUND[@]} -eq 0 ]]; then
      echo "no *.json files in $DIR" >&2
      EXIT_CODE=1
      continue
    fi
    echo "$DIR: ${#FOUND[@]} form file(s)"
    FILES+=("${FOUND[@]}")
  else
    FILES+=("$ARG")
  fi
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "nothing to import" >&2
  exit 1
fi

BASE_URL="${BASE_URL%/}"
if [[ -z "$PASSWORD" ]]; then
  read -rsp "Password for $USERNAME: " PASSWORD; echo
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
COOKIES="$WORK/cookies.txt"
CURL=(curl -sS $INSECURE -u "$USERNAME:$PASSWORD" -b "$COOKIES" -c "$COOKIES")

# ------------------------------------------------------------------ jq library
#
# crefs   — equivalent of jsonpath $..concept, $..setMembers[*], $..answers[*]
# cname   — mirror of getConceptNameWithoutUnit(): name.name || name, minus "(units)"
# fixnode — walks the same three positions and stamps the resolved uuid
#
read -r -d '' JQLIB <<'JQ'
def cname:
  ( if (.name? | type) == "object" then .name.name else .name end ) as $n
  | ( .units? // "" ) as $u
  | if ($n | type) != "string" then empty
    elif $u == "" then $n
    else ($n | split("(" + $u + ")") | join("")) end;

def crefs:
  [ .. | objects
    | ( if (.concept?    | type) == "object" then .concept    else empty end ),
      ( if (.setMembers? | type) == "array"  then .setMembers[] | select(type == "object") else empty end ),
      ( if (.answers?    | type) == "array"  then .answers[]    | select(type == "object") else empty end )
  ];

def stamp($map):
  ( cname ) as $n
  | if ($n != null) and ($map[$n] != null) then .uuid = $map[$n] else . end;

def fixnode($map):
  if type == "object" then
      ( if (.concept?    | type) == "object" then .concept    |= stamp($map) else . end )
    | ( if (.setMembers? | type) == "array"  then .setMembers |= map(if type == "object" then stamp($map) else . end) else . end )
    | ( if (.answers?    | type) == "array"  then .answers    |= map(if type == "object" then stamp($map) else . end) else . end )
    | with_entries(.value |= fixnode($map))
  elif type == "array" then map(fixnode($map))
  else . end;
JQ

# ------------------------------------------------------------------ helpers

# api_get / api_post print the response body on stdout and record the HTTP status
# in $WORK/code. They are normally called inside $( ), which runs them in a
# subshell — a plain variable would not survive that, so the status goes to a file
# and callers read it back with last_code.
last_code() { cat "$WORK/code" 2>/dev/null || echo 000; }

api_get() {  # api_get <path> [curl args...]
  local path="$1"; shift
  local out
  out="$("${CURL[@]}" -w '\n%{http_code}' "$@" "${BASE_URL}${path}" 2>/dev/null)" || out=$'\n000'
  printf '%s' "${out##*$'\n'}" > "$WORK/code"
  printf '%s' "${out%$'\n'*}"
}

api_post() { # api_post <path> <json-file>
  local path="$1" body="$2" out
  out="$("${CURL[@]}" -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
        --data-binary "@$body" "${BASE_URL}${path}" 2>/dev/null)" || out=$'\n000'
  printf '%s' "${out##*$'\n'}" > "$WORK/code"
  printf '%s' "${out%$'\n'*}"
}

# A POST that carries its query in the URL and no body at all — which is what
# the Publish button sends. Not api_post: that one always attaches a JSON file,
# and an endpoint expecting no body can reject one.
api_post_nobody() { # api_post_nobody <path-including-query>
  local path="$1" out
  out="$("${CURL[@]}" -w '\n%{http_code}' -X POST -H 'Content-Length: 0' \
        "${BASE_URL}${path}" 2>/dev/null)" || out=$'\n000'
  printf '%s' "${out##*$'\n'}" > "$WORK/code"
  printf '%s' "${out%$'\n'*}"
}

# newest_form <name> [includeAll] -> "<uuid>\t<version>\t<published>\t<retired>"
# for the highest version of that form on the server; empty when there is none.
#
# The name is matched exactly, because `q=` is a substring search and
# "ANC Intake" would otherwise also match "ANC Intake (Nurse)".
#
# The reason a lookup could not be performed at all goes to a FILE, read back
# with last_form_err — exactly like last_code above, and for the same reason:
# this function is called inside $( ), which is a subshell, so a plain variable
# assignment would not survive. The caller needs it to say "the search failed"
# rather than the much more alarming — and quite different — "the server does
# not have this form".
#
# A second argument asks for retired forms too: the default search hides them,
# which is exactly why a retired form reads as "missing" without it.
last_form_err() { cat "$WORK/formerr" 2>/dev/null || true; }

newest_form() { # newest_form <name> [include-retired]
  local name="$1" all="${2:-}" body code rep
  : > "$WORK/formerr"

  # custom reps are cheap but a server that rejects one answers 400, not 200.
  # Fall back to the full representation rather than reporting the form absent.
  for rep in "custom:(uuid,name,version,published,retired)" "full"; do
    if [[ -n "$all" ]]; then
      body="$(api_get "$FORM_URL" --get \
        --data-urlencode "q=$name" --data-urlencode "includeAll=true" \
        --data-urlencode "v=${rep}")"
    else
      body="$(api_get "$FORM_URL" --get \
        --data-urlencode "q=$name" --data-urlencode "v=${rep}")"
    fi
    code="$(last_code)"
    [[ "$code" == "200" ]] && break
  done
  if [[ "$code" != "200" ]]; then
    printf 'form search returned HTTP %s' "$code" > "$WORK/formerr"
    return 1
  fi

  jq -r --arg n "$name" '
    [ .results[]? | select(.name == $n) ]
    | sort_by(.version | tostring | tonumber? // 0)
    | last
    | if . == null then "" else
        [ .uuid, (.version | tostring),
          (.published | tostring), ((.retired // false) | tostring) ] | @tsv
      end' <<<"$body" 2>/dev/null
}

# form_state <name> — one lookup, answering every question the run has about a
# form that is already deployed. Sets:
#   FS_FOUND   0/1        is it on the server at all (retired included)
#   FS_UUID    uuid of the newest version
#   FS_VERSION that version
#   FS_PUB     0/1        published
#   FS_RETIRED 0/1        retired
#   FS_ERR     non-empty  the lookup itself failed; the other fields mean nothing
form_state() { # form_state <name>
  local name="$1" row
  FS_FOUND=0; FS_UUID=""; FS_VERSION=""; FS_PUB=0; FS_RETIRED=0; FS_ERR=""

  row="$(newest_form "$name")" || { FS_ERR="$(last_form_err)"; return 1; }
  if [[ -z "$row" ]]; then
    # Not in the default listing. That is "absent" OR "retired" — and the two
    # call for opposite responses, so ask again rather than guess.
    row="$(newest_form "$name" includeAll)" || { FS_ERR="$(last_form_err)"; return 1; }
    [[ -z "$row" ]] && return 0        # genuinely not there
  fi

  local pub ret
  IFS=$'\t' read -r FS_UUID FS_VERSION pub ret <<<"$row"
  FS_FOUND=1
  [[ "$pub" == "true" ]] && FS_PUB=1
  [[ "$ret" == "true" ]] && FS_RETIRED=1
  return 0
}

# publish_form <uuid> -> 0 published, 1 could not.
#
# The bahmniie endpoint is what the Implementer Interface's Publish button
# calls, so using it inherits whatever else Bahmni does on publish rather than
# just flipping a column. Where that endpoint is missing — an older bahmnicore,
# or a stack without the module — fall back to the core OpenMRS form resource,
# which at least sets the flag.
publish_form() { # publish_form <uuid>
  local uuid="$1" code
  api_post_nobody "${PUBLISH_URL}?formUuid=${uuid}" >/dev/null
  code="$(last_code)"
  case "$code" in
    200|201) return 0 ;;
    404|405|501)
      [[ $VERBOSE -eq 1 ]] && echo "    publish endpoint answered HTTP $code — trying the core form resource"
      printf '{"published": true}' > "$WORK/publish.json"
      api_post "${FORM_URL}/${uuid}" "$WORK/publish.json" >/dev/null
      code="$(last_code)"
      [[ "$code" == "200" || "$code" == "201" ]] && return 0
      echo "  ERROR publishing: bahmniie said 404/405 and /form/<uuid> said HTTP $code"
      return 1 ;;
    *)
      echo "  ERROR publishing: HTTP $code"
      return 1 ;;
  esac
}

# ensure_published <name> [uuid] — publish the newest version of a form unless it
# already is. Reads the state back from the server rather than trusting the POST,
# and counts what it changed. Never fatal on its own: a form that is deployed but
# unpublished is a smaller problem than a run that stopped half way through.
ensure_published() { # ensure_published <name> [known-uuid]
  local name="$1" known="${2:-}" uuid version

  if ! form_state "$name"; then
    echo "  WARNING: cannot publish '$name' — ${FS_ERR}"
    return 1
  fi

  if [[ $FS_FOUND -eq 0 ]]; then
    if [[ -n "$known" ]]; then
      uuid="$known"; version=""
    else
      echo "  WARNING: cannot publish '$name' — no form of that name on the server"
      return 1
    fi
  else
    uuid="$FS_UUID"; version="$FS_VERSION"
    if [[ $FS_RETIRED -eq 1 ]]; then
      # Publishing a retired form would put a form nobody can reach back on the
      # published list. The fix is a new version, which the import above does.
      echo "  newest version (${version}) is RETIRED — not publishing it"
      return 1
    fi
    if [[ $FS_PUB -eq 1 ]]; then
      [[ $VERBOSE -eq 1 ]] && echo "  already published (version ${version})"
      return 0
    fi
  fi

  if ! publish_form "$uuid"; then
    EXIT_CODE=1
    return 1
  fi

  # Read it back: a 200 from the endpoint is not the same as a published form.
  if form_state "$name" && [[ $FS_FOUND -eq 1 ]]; then
    version="$FS_VERSION"
    if [[ $FS_PUB -ne 1 ]]; then
      echo "  ERROR: publish returned OK but '$name' is still unpublished"
      EXIT_CODE=1
      return 1
    fi
  fi
  echo "  published version ${version:-?}"
  PUBLISHED=$((PUBLISHED + 1))
  return 0
}

# concept_query <name> <jq-filter> <curl args...> -> uuid on stdout
#   0 = answered: the uuid, or empty when the server has no match
#   2 = no usable answer; the reason is in $WORK/lookup_err
# The filter runs over .results with the concept name bound to $n. Only a 200
# whose body is JSON with a results array counts as an answer. A proxy error
# page, a dropped session or a timeout used to come back as an empty uuid, so
# an EMR that was merely busy produced "Concept name not found" for concepts
# that exist — and a different set of them on every run.
concept_query() {
  local name="$1" filter="$2"; shift 2
  local attempt body code
  for attempt in 1 2 3 4 5 6; do
    body="$(api_get "$CONCEPT_URL" --get --max-time 60 "$@")"
    code="$(last_code)"
    if [[ "$code" == "200" ]]; then
      if jq -e '.results | type == "array"' <<<"$body" >/dev/null 2>&1; then
        jq -r --arg n "$name" ".results | $filter" <<<"$body"
        return 0
      fi
      code="200 (response was not concept JSON)"
    fi
    printf 'HTTP %s' "$code" > "$WORK/lookup_err"
    [[ "$code" == "401" || "$code" == "403" ]] && return 2
    (( attempt < 6 )) && sleep "$(awk -v a="$attempt" 'BEGIN{print 2 ^ (a - 1)}')"
  done
  return 2
}

# concept_uuid <name> -> uuid on stdout
#   0 = found, 1 = the server has no such concept, 2 = lookup failed ($WORK/lookup_err)
# First the query the Implementer Interface sends (q= search, exact match on the
# returned name). When that finds nothing, ask Bahmni's byFullySpecifiedName
# handler, which matches the name exactly in the database: q= goes through the
# search index and returns one page at the default limit, so a concept that
# exists can be absent from it — while the index is rebuilt after a restart, or
# when a short name like "Negative" matches more concepts than fit on a page.
concept_uuid() {
  local name="$1" uuid
  uuid="$(concept_query "$name" \
      '[.[] | select(.name.name == $n) | .uuid][0] // ""' \
      --data-urlencode "q=$name" \
      --data-urlencode "source=byFullySpecifiedName" \
      --data-urlencode "v=custom:(uuid,name:(name))")" || return 2
  if [[ -z "$uuid" ]]; then
    uuid="$(concept_query "$name" \
        '[.[] | .uuid][0] // ""' \
        --data-urlencode "s=byFullySpecifiedName" \
        --data-urlencode "name=$name" \
        --data-urlencode "v=custom:(uuid)")" || return 2
  fi
  [[ -n "$uuid" ]] || return 1
  printf '%s\n' "$uuid"
}

# ------------------------------------------------------------------ state
#
# One JSON object, keyed "<base-url>|<form name>", recording what this script
# last deployed:
#
#   { "https://localhost|HIV Treatment and Care Follow Up": {
#       "version": "3", "sha256": "ab12...", "form_uuid": "...",
#       "file": "forms/HIV....json", "imported_at": "2026-08-24T09:12:03Z" } }
#
# Keying on the URL as well as the name keeps a dev run from convincing a later
# prod run that a form is already up to date.

# Default location, in order of preference:
#   1. --state / BAHMNI_STATE_FILE
#   2. the v1 install root (<install-base>/v1), i.e. NEXT TO the clinical-obs-forms
#      clone rather than inside it — a `git reset --hard` from the auto-pull job
#      must never be able to wipe the record of what has been deployed
#   3. beside this script (stand-alone/checkout use)
if [[ -z "$STATE_FILE" ]]; then
  LEGACY_STATE="$(cd "$(dirname "$0")" && pwd)/.bahmni_import_state.json"
  FORMS_ROOT="$(dirname "$FORMS_DIR")"
  if [[ -f "$LEGACY_STATE" ]]; then
    STATE_FILE="$LEGACY_STATE"          # a checkout that already has a history
  elif [[ -d "$FORMS_ROOT" ]]; then
    STATE_FILE="${FORMS_ROOT}/.bahmni_form_import_state.json"
  else
    STATE_FILE="$LEGACY_STATE"
  fi
fi

# Two overlapping runs would both read the same "last version" and deploy the
# same number, so serialise them. flock is util-linux, present on Ubuntu and
# absent on stock macOS; where it is missing the lock is simply skipped, which
# is fine for the interactive use it is missing on.
#
# The braces matter: `exec 9>file 2>/dev/null` would apply BOTH redirections to
# the shell itself and silence stderr for the whole run. Wrapping the exec in a
# group scopes 2>/dev/null to the group while fd 9 still lands on this shell.
if command -v flock >/dev/null 2>&1; then
  if { exec 9>"${STATE_FILE}.lock"; } 2>/dev/null; then
    if ! flock -n 9; then
      echo "another import is already running (lock: ${STATE_FILE}.lock)" >&2
      echo "wait for it to finish, or remove the lock file if it is stale" >&2
      exit 1
    fi
  fi
fi

file_hash() { # file_hash <path> -> sha256 on stdout
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi | awk '{print $1}'
}

state_key() { printf '%s|%s' "$BASE_URL" "$1"; }

state_get() { # state_get <key> <field> -> value, empty when unrecorded
  [[ -f "$STATE_FILE" ]] || { echo ""; return 0; }
  jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // ""' "$STATE_FILE" 2>/dev/null || echo ""
}

state_put() { # state_put <key> <version> <sha256> <form-uuid> <file>
  # The scratch file lives in the state file's own directory rather than $WORK.
  # On Ubuntu /tmp is normally a separate tmpfs mount, and mv across
  # filesystems is copy-then-unlink — interrupt it and the state file is left
  # truncated. Same directory means rename(2), which is atomic.
  local tmp="${STATE_FILE}.$$.tmp"
  [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE" 2>/dev/null
  if jq --arg k "$1" --arg v "$2" --arg h "$3" --arg u "$4" --arg f "$5" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.[$k] = {version: $v, sha256: $h, form_uuid: $u, file: $f, imported_at: $t}' \
        "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  # Silently losing this means every later run re-imports and re-bumps, so make
  # it loud and let it colour the exit code — a cron job should notice.
  echo "  WARNING: cannot write $STATE_FILE" >&2
  echo "           version tracking will not persist; pass --state FILE or set" >&2
  echo "           BAHMNI_STATE_FILE to a writable path" >&2
  EXIT_CODE=1
}

# ------------------------------------------------------------------ login

# A 200 here only means something answered; Bahmni returns 200 with
# authenticated:false for bad credentials, and a proxy or wrong host answers 200
# with an HTML login page. Report which of the three it was.
session="$(api_get /openmrs/ws/rest/v1/session)"
CODE="$(last_code)"
AUTHED="$(jq -r '.authenticated // false' <<<"$session" 2>/dev/null)"

if [[ "$CODE" != "200" || "$AUTHED" != "true" ]]; then
  if [[ "$CODE" != "200" ]]; then
    echo "Authentication failed: HTTP $CODE from $BASE_URL/openmrs/ws/rest/v1/session" >&2
  elif ! jq -e . <<<"$session" >/dev/null 2>&1; then
    echo "Authentication failed: $BASE_URL/openmrs/ws/rest/v1/session did not return JSON." >&2
    echo "Check --url / BAHMNI_URL — this looks like a web server or proxy, not the OpenMRS API." >&2
  else
    echo "Authentication failed: server said authenticated=$AUTHED for user '$USERNAME'." >&2
    echo "Check BAHMNI_USER / BAHMNI_PASS (a wrong password returns HTTP 200 with authenticated:false)." >&2
  fi
  echo "--- first 400 bytes of the response ---" >&2
  printf '%.400s\n' "$session" >&2
  exit 1
fi
echo "Logged in as $(jq -r '.user.display' <<<"$session") on $BASE_URL"
echo "${#FILES[@]} form file(s) to import"

IMPORTED=0
FAILED=0
SKIPPED=0
PUBLISHED=0
IGNORED=0       # files in the folder that are not form exports at all
EMR_WRITTEN=0   # …of which, ones the EMR itself wrote (see the loop)

# ------------------------------------------------------------------ per file

for FILE in "${FILES[@]}"; do
  echo
  echo "=== $(basename "$FILE")"
  [[ -r "$FILE" ]] || { echo "  cannot read file"; EXIT_CODE=1; FAILED=$((FAILED + 1)); continue; }

  # Is this a Form Builder EXPORT at all?
  #
  # The folder can hold other JSON. In particular the EMR writes one
  # <form-uuid>.json per DEPLOYED form — top-level uuid/resources, no formJson
  # wrapper — and on a site where that output lands in the same folder as the
  # exports, those files outnumber the real ones. They are not broken exports
  # and must not be reported as failures: a run whose exit status is dominated
  # by files that were never meant to be imported tells the operator nothing.
  if ! jq -e 'type == "object" and has("formJson")' "$FILE" >/dev/null 2>&1; then
    if jq -e 'type == "object" and has("uuid") and has("resources")' "$FILE" >/dev/null 2>&1; then
      echo "  skipped: a form the EMR itself wrote (no formJson wrapper) — not an export"
      EMR_WRITTEN=$((EMR_WRITTEN + 1))
    else
      echo "  skipped: not a Bahmni form export (no formJson key)"
    fi
    IGNORED=$((IGNORED + 1)); continue
  fi

  # It claims to be an export, so a missing body IS a real problem.
  if ! jq -e '.formJson.resources[0].value' "$FILE" >/dev/null 2>&1; then
    echo "  parse error: form export is missing formJson.resources[0].value"
    EXIT_CODE=1; FAILED=$((FAILED + 1)); continue
  fi

  FORM_NAME="$(jq -r '.formJson.name' "$FILE")"

  # --publish-only: publish what is already deployed and move on. No concept
  # resolution, no POST /form, no version bump — so it is seconds per form
  # rather than minutes, and it cannot change what any form contains.
  if [[ $PUBLISH_ONLY -eq 1 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      if ! form_state "$FORM_NAME"; then
        echo "  cannot tell — ${FS_ERR}"
      elif [[ $FS_FOUND -eq 0 ]]; then
        echo "  not on the server"
      else
        echo "  version ${FS_VERSION} published=${FS_PUB} retired=${FS_RETIRED}"
      fi
    else
      ensure_published "$FORM_NAME" || true
    fi
    continue
  fi

  jq -r '.formJson.resources[0].value' "$FILE" | jq '.' > "$WORK/value.json"
  jq '.translations // []' "$FILE" > "$WORK/translations.json"
  jq -r '.formJson.resources[1].value // empty' "$FILE" > "$WORK/nametrans.json"

  # ---------------------------------------------------------- 0. changed?
  #
  # Compare a hash of the source file against what was recorded for this form
  # name on this server. Hashing the export rather than the fixed-up payload
  # means the question asked is "did the author change the form?", which is
  # independent of concepts being re-resolved on every run.

  HASH="$(file_hash "$FILE")"
  KEY="$(state_key "$FORM_NAME")"
  PREV_HASH="$(state_get "$KEY" sha256)"
  PREV_VERSION="$(state_get "$KEY" version)"
  [[ "$PREV_VERSION" =~ ^[0-9]+$ ]] || PREV_VERSION=0

  if [[ -n "$PREV_HASH" && "$PREV_HASH" == "$HASH" && $FORCE -eq 0 ]]; then
    # "The file has not changed" is not the same as "the site has this form".
    # Ask the server before skipping. Two states demand a redeploy even though
    # the export is byte-identical:
    #
    #   * the newest version is RETIRED — which is what the release retirement
    #     does to the outgoing set. Skip here and the site is left with no live
    #     copy of a form whose file will never change again.
    #   * the form is missing outright — restored database, hand-deleted form,
    #     or a state file carried over from another server.
    #
    # Anything else is a genuine no-op, except that an unpublished form still
    # gets published (one GET per form, a POST only when there is a fix to make).
    REDEPLOY_WHY=""
    if [[ $DRY_RUN -eq 0 ]] && form_state "$FORM_NAME"; then
      if [[ $FS_FOUND -eq 0 ]]; then
        REDEPLOY_WHY="it is not on the server"
      elif [[ $FS_RETIRED -eq 1 ]]; then
        REDEPLOY_WHY="its newest version (${FS_VERSION}) is retired"
      fi
    fi

    if [[ -z "$REDEPLOY_WHY" ]]; then
      echo "  unchanged since version $PREV_VERSION — skipping (--force to import anyway)"
      SKIPPED=$((SKIPPED + 1))
      if [[ $PUBLISH -eq 1 && $DRY_RUN -eq 0 ]]; then
        ensure_published "$FORM_NAME" || true
      fi
      continue
    fi
    echo "  unchanged since version $PREV_VERSION, but ${REDEPLOY_WHY} — redeploying"
  fi

  # ---------------------------------------------------------- 0b. next version
  #
  # The state file is the record of what this script deployed, but the server is
  # the authority — someone may have saved a newer version in the Implementer
  # Interface, or the state file may have been lost. Take whichever is higher so
  # the new version never collides with one that already exists.

  lookup="$(api_get "$FORM_URL" --get \
    --data-urlencode "q=$FORM_NAME" --data-urlencode "v=custom:(uuid,name,version)")"
  SERVER_VERSION="$(jq -r --arg n "$FORM_NAME" \
    '[.results[]? | select(.name == $n) | (.version | tostring | tonumber? // 0)]
     | max // 0 | floor' <<<"$lookup" 2>/dev/null)"
  [[ "$SERVER_VERSION" =~ ^[0-9]+$ ]] || SERVER_VERSION=0

  if [[ $VERSION_EXPLICIT -eq 1 ]]; then
    TARGET_VERSION="$FORM_VERSION"
    echo "  version $TARGET_VERSION (pinned by --version)"
  elif [[ $BUMP -eq 0 ]]; then
    TARGET_VERSION="$FORM_VERSION"
    echo "  version $TARGET_VERSION (--no-bump)"
  else
    LAST=$(( PREV_VERSION > SERVER_VERSION ? PREV_VERSION : SERVER_VERSION ))
    TARGET_VERSION=$((LAST + 1))
    if [[ $LAST -eq 0 ]]; then
      echo "  not deployed before — version $TARGET_VERSION"
    else
      echo "  last version $LAST (state $PREV_VERSION, server $SERVER_VERSION) — deploying $TARGET_VERSION"
    fi
  fi

  # ---------------------------------------------------------- 1. concepts
  if [[ $SKIP_VALIDATION -eq 1 ]]; then
    echo "  skipping concept validation"
    cp "$WORK/value.json" "$WORK/value.fixed.json"
  else
    jq -r "$JQLIB"' [crefs[] | cname] | length' "$WORK/value.json" > "$WORK/total"
    jq -r "$JQLIB"' [crefs[] | cname] | unique | .[]' "$WORK/value.json" > "$WORK/names"
    TOTAL="$(cat "$WORK/total")"
    UNIQUE="$(wc -l < "$WORK/names" | tr -d ' ')"
    echo "  $TOTAL concept references, $UNIQUE unique names"

    : > "$WORK/missing"
    : > "$WORK/map.jsonl"
    n=0
    while IFS= read -r NAME; do
      [[ -z "$NAME" ]] && continue
      n=$((n + 1))
      rc=0; UUID="$(concept_uuid "$NAME")" || rc=$?
      if [[ $rc -eq 0 ]]; then
        jq -cn --arg k "$NAME" --arg v "$UUID" '{($k): $v}' >> "$WORK/map.jsonl"
        [[ $VERBOSE -eq 1 ]] && printf '    %-60.60s %s\n' "$NAME" "$UUID"
      elif [[ $rc -eq 1 ]]; then
        echo "Concept name not found $NAME" >> "$WORK/missing"
        [[ $VERBOSE -eq 1 ]] && printf '    %-60.60s NOT FOUND\n' "$NAME"
      else
        why="$(cat "$WORK/lookup_err" 2>/dev/null || echo 'no response')"
        echo "Concept lookup failed ($why) $NAME" >> "$WORK/missing"
        [[ $VERBOSE -eq 1 ]] && printf '    %-60.60s LOOKUP FAILED (%s)\n' "$NAME" "$why"
      fi
      if [[ $VERBOSE -eq 0 ]] && (( n % 25 == 0 )) && [[ -t 1 ]]; then
        printf '\r    resolving %d/%d' "$n" "$UNIQUE"
      fi
      [[ "$DELAY" != "0" ]] && sleep "$DELAY"
    done < "$WORK/names"
    [[ $VERBOSE -eq 0 ]] && printf '\r    resolved %d/%d unique names   \n' "$n" "$UNIQUE"

    if [[ -s "$WORK/missing" ]]; then
      ERR_FILE="$(basename "${FILE%.json}").importErrors.txt"
      sort -u "$WORK/missing" > "$ERR_FILE"
      n_missing="$(grep -c '^Concept name not found' "$ERR_FILE")"
      n_failed="$(grep -c '^Concept lookup failed' "$ERR_FILE")"
      echo "  ${n_missing} concepts missing, ${n_failed} lookups failed — see $ERR_FILE"
      (( n_failed > 0 )) && echo "  (failed lookups are server/proxy errors, not missing concepts — re-run once the EMR is responding)"
      EXIT_CODE=1; FAILED=$((FAILED + 1)); continue
    fi

    jq -s 'add // {}' "$WORK/map.jsonl" > "$WORK/map.json"
    jq --slurpfile m "$WORK/map.json" "$JQLIB"' fixnode($m[0])' \
       "$WORK/value.json" > "$WORK/value.fixed.json"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  dry run: concepts OK, nothing written"
    continue
  fi

  # ---------------------------------------------------------- 2. create form
  jq -n --arg name "$FORM_NAME" --arg ver "$TARGET_VERSION" \
    '{name: $name, version: $ver, published: false}' > "$WORK/form.json"
  body="$(api_post "$FORM_URL" "$WORK/form.json")"
  CODE="$(last_code)"

  RESOURCE_UUID=""
  if [[ "$CODE" == "200" || "$CODE" == "201" ]]; then
    FORM_UUID="$(jq -r '.uuid' <<<"$body")"
  else
    # This name+version already exists (normal under --no-bump, or when the
    # state file disagrees with the server): overwrite that version's resource.
    # $lookup was fetched above, before the POST, so it already lists it.
    FORM_UUID="$(jq -r --arg n "$FORM_NAME" --arg v "$TARGET_VERSION" \
      '[.results[]? | select(.name == $n and (.version | tostring) == $v)] | last.uuid // ""' \
      <<<"$lookup")"
    [[ -z "$FORM_UUID" ]] && FORM_UUID="$(jq -r --arg n "$FORM_NAME" \
      '[.results[]? | select(.name == $n)] | last.uuid // ""' <<<"$lookup")"
    if [[ -z "$FORM_UUID" ]]; then
      echo "  ERROR: POST /form returned HTTP $CODE and no existing form named '$FORM_NAME'"
      echo "  ${body:0:400}"
      EXIT_CODE=1; FAILED=$((FAILED + 1)); continue
    fi
    detail="$(api_get "$FORM_URL/$FORM_UUID" --get --data-urlencode \
      "v=custom:(id,uuid,name,version,published,auditInfo,resources:(value,dataType,uuid))")"
    RESOURCE_UUID="$(jq -r '.resources[0].uuid // ""' <<<"$detail")"
  fi
  echo "  form uuid $FORM_UUID"

  # ---------------------------------------------------------- 3. save body
  jq --arg uuid "$FORM_UUID" '.uuid = $uuid' "$WORK/value.fixed.json" > "$WORK/value.final.json"
  jq -n --arg name "$FORM_NAME" --arg uuid "$FORM_UUID" --arg ruuid "$RESOURCE_UUID" \
     --slurpfile v "$WORK/value.final.json" \
     '{form: {name: $name, uuid: $uuid}, value: ($v[0] | tojson), uuid: $ruuid}' \
     > "$WORK/resource.json"

  body="$(api_post "$FORM_SAVE_URL" "$WORK/resource.json")"
  CODE="$(last_code)"
  if [[ "$CODE" != "200" && "$CODE" != "201" ]]; then
    echo "  ERROR saving form body: HTTP $CODE ${body:0:400}"
    EXIT_CODE=1; FAILED=$((FAILED + 1)); continue
  fi
  SAVED_UUID="$(jq -r --arg d "$FORM_UUID" '.form.uuid // $d' <<<"$body")"
  SAVED_VERSION="$(jq -r --arg d "$FORM_VERSION" '.form.version // $d' <<<"$body")"
  echo "  saved body, version $SAVED_VERSION"

  # ---------------------------------------------------------- 4. translations
  if [[ "$(jq 'length' "$WORK/translations.json")" -gt 0 ]]; then
    jq --arg u "$SAVED_UUID" --arg ver "$SAVED_VERSION" \
      '[.[] | .formUuid = $u | .version = $ver]' "$WORK/translations.json" > "$WORK/trans.json"
    body="$(api_post "$SAVE_TRANSLATION_URL" "$WORK/trans.json")"
    CODE="$(last_code)"
    echo "  translations: HTTP $CODE"
    [[ "$CODE" == "200" || "$CODE" == "201" ]] || EXIT_CODE=1
  fi

  # ---------------------------------------------------------- 5. name translations
  if [[ -s "$WORK/nametrans.json" ]]; then
    body="$(api_post "$SAVE_NAME_TRANSLATION_URL" "$WORK/nametrans.json")"
    echo "  name translations: HTTP $(last_code)"
  fi

  # ---------------------------------------------------------- 6. publish
  # The Import button stops at step 5 and leaves the form in Draft. Everything
  # above is wasted until someone publishes it, so do that here rather than
  # asking for dozens of clicks. The state is written either way: the form IS
  # deployed, and a failed publish should not make the next run re-import it.
  if [[ $PUBLISH -eq 1 ]]; then
    ensure_published "$FORM_NAME" "$SAVED_UUID" || true
  fi

  state_put "$KEY" "$SAVED_VERSION" "$HASH" "$SAVED_UUID" "$FILE"
  echo "  imported '$FORM_NAME' as version $SAVED_VERSION"
  IMPORTED=$((IMPORTED + 1))
done

echo
# Exports are what this script is counted against. Files that were never form
# exports are reported separately: folding them into the denominator turned
# "8 forms, all fine" into the alarming "imported 0/76".
EXPORTS=$(( ${#FILES[@]} - IGNORED ))

if [[ $DRY_RUN -eq 1 ]]; then
  echo "dry run finished: ${EXPORTS} export(s) checked, $SKIPPED unchanged, $FAILED with problems"
elif [[ $PUBLISH_ONLY -eq 1 ]]; then
  echo "published $PUBLISHED/${EXPORTS} form(s); nothing was imported (--publish-only)"
else
  echo "imported $IMPORTED/${EXPORTS} form(s), $SKIPPED unchanged, $PUBLISHED published, $FAILED failed"
  [[ $IMPORTED -gt 0 ]] && echo "state: $STATE_FILE"
fi

if [[ $IGNORED -gt 0 ]]; then
  echo "ignored $IGNORED file(s) in the folder that are not form exports"
fi

# The one that needs explaining, because it silently breaks two other things:
# the folder is a git clone, and files the EMR drops into it make that clone
# dirty — so the nightly refresh stops pulling new forms.
if [[ $EMR_WRITTEN -gt 0 ]]; then
  cat <<MSG

  ${EMR_WRITTEN} of those are forms the EMR itself wrote (<form-uuid>.json).
  They are in the folder this script imports FROM, which is a git clone of the
  form exports. That is worth fixing rather than living with:

    * it makes the clone permanently dirty, so the nightly refresh reports
      "SKIP refresh (… has uncommitted local changes)" and NEW FORMS STOP
      ARRIVING — which looks exactly like the import being broken;
    * every run re-reads them for nothing.

  They are almost certainly the EMR's own clinical_forms directory showing
  through a bind mount. Check what the openmrs service mounts there:

    cd <stack dir> && docker compose config | grep -A2 clinical_forms

  If it is bind-mounted onto this folder, point one of the two somewhere else.
  Otherwise just remove them — the EMR keeps its own copy inside the container:

    git -C ${FORMS_DIR} clean -n '*.json'     # list first
    git -C ${FORMS_DIR} clean -f  '*.json'    # then delete
MSG
fi

exit "$EXIT_CODE"
