# shellcheck shell=bash
# =============================================================================
# lib/upgrade/verify.sh — download integrity (checksum + optional GPG) and
# idempotent git clone/update with ref pinning.
# Depends on: logging, as_root() (privilege).
# =============================================================================
verify_checksum() {
  # verify_checksum <file> <expected_sha256>   (fail-closed)
  local file="$1" expected="$2" actual
  [ -n "$expected" ] || { error "No expected checksum provided for ${file}; refusing (fail-closed)."; return 1; }
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    error "Checksum mismatch for ${file}"
    error "  expected: ${expected}"
    error "  actual:   ${actual}"
    return 1
  fi
  success "Checksum OK: $(basename "$file")"
}

verify_gpg() {
  # verify_gpg <file> <sig>   — optional; only enforced if a sig is supplied.
  local file="$1" sig="$2"
  [ -n "$sig" ] || { info "No GPG signature supplied for $(basename "$file"); skipping."; return 0; }
  command -v gpg >/dev/null 2>&1 || { error "gpg required to verify ${sig} but not installed."; return 1; }
  gpg --verify "$sig" "$file" || { error "GPG verification failed for ${file}."; return 1; }
  success "GPG signature OK: $(basename "$file")"
}

is_sha() {
  # A full 40-char hex object id — ls-remote can't match it as a ref pattern,
  # and 'clone --branch' won't accept it, so both paths special-case it.
  case "$1" in
    *[!0-9a-fA-F]*) return 1 ;;
    *) [ "${#1}" -eq 40 ] ;;
  esac
}

resolve_ref() {
  # resolve_ref <repo_url> <candidate>... — echo the first candidate that the
  # remote actually publishes (as a branch or a tag); non-zero if none match.
  # Lets one --target-ref span repos that don't share a branch name.
  local url="$1"; shift
  local c
  for c in "$@"; do
    [ -n "$c" ] || continue
    if is_sha "$c"; then printf '%s' "$c"; return 0; fi
    if git ls-remote --exit-code "$url" "refs/heads/${c}" "refs/tags/${c}" >/dev/null 2>&1; then
      printf '%s' "$c"; return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# git_here — run git against a repo that may be owned by someone else.
#
# Site clones end up owned by whoever created them: root when the installer ran
# under sudo, the operator when it did not. Since git 2.35 a repo whose owner is
# not the current user is refused outright:
#
#     fatal: detected dubious ownership in repository at '/var/lib/v1/...'
#
# That is how a root-run cron job quietly stops updating a user-owned clone —
# every command fails, and the caller reads it as "no branch" or "not a repo".
# safe.directory=* relaxes ONLY that ownership check, for this invocation;
# file permissions still apply exactly as before.
# -----------------------------------------------------------------------------
git_here() { as_root git -c safe.directory='*' "$@"; }

git_clone_or_update() {
  # Idempotent clone; verifies the remote and checks out the requested ref.
  # git_clone_or_update <repo_url> <dest_dir> <default_ref>
  # A non-empty global TARGET_REF (comma-separated preference list) is tried
  # first, in order; <default_ref> is the last resort. The ref is resolved
  # against the remote BEFORE cloning, so a bad ref fails loudly here rather
  # than silently landing on the repo's default branch.
  local url="$1" dest="$2" default_ref="$3" ref
  if [ -n "$TARGET_REF" ]; then
    local cands
    IFS=',' read -r -a cands <<< "$TARGET_REF"
    ref="$(resolve_ref "$url" "${cands[@]}" "$default_ref")" || {
      error "None of '${TARGET_REF}' (nor the default '${default_ref}') exist on ${url}."
      return 1
    }
    [ "$ref" = "${cands[0]}" ] || warn "${url}: no '${cands[0]}'; using '${ref}' instead."
  else
    ref="$default_ref"
  fi
  [ -n "$ref" ] || { error "No git ref specified for ${url}."; return 1; }

  if [ -d "$dest/.git" ]; then
    info "Repo exists, updating: ${dest} @ ${ref}"
    git_here -C "$dest" remote set-url origin "$url"
    git_here -C "$dest" fetch --depth 1 origin "$ref"
    git_here -C "$dest" checkout -f "$ref"
    git_here -C "$dest" reset --hard "origin/${ref}" 2>/dev/null || true
  elif is_sha "$ref"; then
    # --branch rejects a raw SHA, so clone in full and check the commit out.
    info "Cloning ${url} @ ${ref} (full clone; SHA pin) -> ${dest}"
    as_root git clone "$url" "$dest"
    git_here -C "$dest" checkout -f "$ref"
  else
    info "Cloning ${url} @ ${ref} -> ${dest}"
    as_root git clone --depth 1 --branch "$ref" "$url" "$dest"
  fi
  [ -d "$dest/.git" ] || { error "Clone failed: ${dest}"; return 1; }
  success "Ready: ${dest} @ ${ref} ($(git_here -C "$dest" rev-parse --short HEAD))"
}
