# shellcheck shell=bash
# =============================================================================
# lib/upgrade/reportroles.sh — create the Reports-<Sub-Group> roles.
#
# WHO LOADS THIS
#   ./catch-up.sh only, through catchup_report_roles in lib/upgrade/catchup.sh,
#   and only does anything when asked: --fix-report-roles (or
#   EREGISTER_REPORT_ROLES_FIX=1). It reuses the database plumbing in
#   concepts.sh (_concepts_mysql, _concepts_resolve_compose, _concepts_db_ready),
#   so that module must be sourced first.
#
# WHY
#   The customised ReportsController hides every report group unless the
#   logged-in user holds a role named "Reports-<Sub-Group>" (spaces -> hyphens,
#   exact case). Only "Reports-App" existed, so the Reports dashboard rendered
#   blank.
#
# WHAT IT DOES, in the 'openmrs' database of the openmrsdb service
#   1. creates the 14 group roles the controller can ask for
#   2. makes each inherit Reports-App (role_role: the child role inherits the
#      parent's privileges), so a user given only e.g. Reports-HIV can still
#      open the Reports app
#   3. gives every Reports-% role to REPORT_ROLES_USER (default 'superman')
#   4. prints how many users hold each role
#
#   Every statement is INSERT IGNORE, so it is idempotent: the step counts what
#   is missing first and does nothing at all when that is zero. The three tables
#   it writes (role, role_role, user_role) are dumped to BACKUP_DIR before the
#   first write; the report prints the statements that undo it.
#
#   Assigning group roles per cadre (nurses -> HIV/TB/Other, lab -> Lab ...) is a
#   site decision and is left to the admin UI.
#
#   Role changes are only picked up at login — the EMR reload at the end of
#   catch-up (or the user logging out and back in) is what makes them visible.
#
# Depends on: logging, prompt (confirm), privilege (as_root), concepts.sh.
# Uses config: REPORT_ROLES_*, DB_*, RESTORE_DIR, BACKUP_DIR, DOCKER_COMPOSE.
# =============================================================================

# name|description, one per group the controller can ask for.
_REPORT_ROLES=(
  'Reports-HIV|Access to HIV / ART report group in the Reports app'
  'Reports-TB|Access to TB report group in the Reports app'
  'Reports-NCDs|Access to NCD report group in the Reports app'
  'Reports-Epidemic-Care|Access to Epidemic Care report group'
  'Reports-Medical-Emergency|Access to Medical Emergency report group'
  'Reports-Maternal-Health|Access to Maternal Health report group'
  'Reports-Reproductive-Health|Access to Reproductive Health report group'
  'Reports-Child-Health|Access to Child Health report group'
  'Reports-Mental-Health|Access to Mental Health report group'
  'Reports-Health-Support-Services|Access to Health Support Services report group'
  'Reports-Lab|Access to Laboratory report group'
  'Reports-Pharmacy|Access to Pharmacy report group'
  'Reports-Supply-Chain|Access to Supply Chain report group'
  'Reports-Other|Access to ungrouped ("Other") reports'
)

# The username, doubled up for use inside a single-quoted SQL string.
_rr_user_sql() { printf '%s' "${REPORT_ROLES_USER//\'/\'\'}"; }

# -----------------------------------------------------------------------------
# _rr_missing — what the fix would still add, as
# "<roles>\t<inheritance>\t<user roles>\t<has Reports-App>\t<user exists>".
# -----------------------------------------------------------------------------
_rr_missing() {
  local names="" entry
  for entry in "${_REPORT_ROLES[@]}"; do
    names+="${names:+ UNION ALL }SELECT '${entry%%|*}' AS role"
  done
  local user; user="$(_rr_user_sql)"
  _concepts_mysql -N 2>/dev/null <<SQL
SELECT
  (SELECT COUNT(*) FROM (${names}) n
    WHERE n.role NOT IN (SELECT role FROM role)),
  (SELECT COUNT(*) FROM role r
    WHERE r.role LIKE 'Reports-%' AND r.role <> 'Reports-App'
      AND EXISTS (SELECT 1 FROM role x WHERE x.role = 'Reports-App')
      AND NOT EXISTS (SELECT 1 FROM role_role rr
                      WHERE rr.parent_role = 'Reports-App' AND rr.child_role = r.role)),
  (SELECT COUNT(*) FROM users u JOIN role r ON r.role LIKE 'Reports-%'
    WHERE u.username = '${user}'
      AND NOT EXISTS (SELECT 1 FROM user_role ur
                      WHERE ur.user_id = u.user_id AND ur.role = r.role)),
  (SELECT COUNT(*) FROM role WHERE role = 'Reports-App'),
  (SELECT COUNT(*) FROM users WHERE username = '${user}');
SQL
}

# -----------------------------------------------------------------------------
# _rr_apply — the fix itself (sections 1–3 of the script as handed over).
# -----------------------------------------------------------------------------
_rr_apply() {
  local values="" entry name desc
  for entry in "${_REPORT_ROLES[@]}"; do
    name="${entry%%|*}"; desc="${entry#*|}"
    values+="${values:+,
  }('${name}', '${desc//\'/\'\'}', UUID())"
  done
  local user; user="$(_rr_user_sql)"
  _concepts_mysql <<SQL
INSERT IGNORE INTO role (role, description, uuid) VALUES
  ${values};

INSERT IGNORE INTO role_role (parent_role, child_role)
SELECT 'Reports-App', r.role
FROM   role r
WHERE  r.role LIKE 'Reports-%'
  AND  r.role <> 'Reports-App'
  AND  EXISTS (SELECT 1 FROM role x WHERE x.role = 'Reports-App');

INSERT IGNORE INTO user_role (user_id, role)
SELECT u.user_id, r.role
FROM   users u
JOIN   role  r ON r.role LIKE 'Reports-%'
WHERE  u.username = '${user}';
SQL
}

# -----------------------------------------------------------------------------
# _rr_backup — dump role, role_role and user_role before the first write.
# -----------------------------------------------------------------------------
_rr_backup() {
  local out
  as_root mkdir -p "$BACKUP_DIR"
  out="${BACKUP_DIR}/report-roles-prechange-$(date '+%Y%m%d_%H%M%S').sql"
  info "Backing up role, role_role and user_role -> ${out}"
  # shellcheck disable=SC2086  # $DOCKER_COMPOSE may be two words
  if ( cd "$RESTORE_DIR" && as_root $DOCKER_COMPOSE exec -T "$DB_SERVICE" \
         sh -c 'pw="${3:-$MYSQL_ROOT_PASSWORD}"; user="$1"; db="$2"; shift 3
                exec mysqldump -u"$user" ${pw:+-p"$pw"} --single-transaction --no-tablespaces --skip-add-locks --complete-insert "$db" "$@"' \
            _ "$DB_USER" "$DB_NAME" "$DB_PASS" role role_role user_role ) | as_root tee "$out" >/dev/null \
     && [ -s "$out" ]
  then
    success "Backup written: ${out}"
    REPORT_ROLES_BACKUP="$out"
    return 0
  fi
  as_root rm -f "$out"
  return 1
}

# -----------------------------------------------------------------------------
# fix_report_roles — the step itself.
#
# Sets, for the caller to report on:
#   REPORT_ROLES_STATUS  one of: fixed | already | disabled | declined | partial |
#                                no-db | failed
#   REPORT_ROLES_DETAIL  a one-line explanation of that status
#
# Returns non-zero only when a write was attempted and failed.
# -----------------------------------------------------------------------------
fix_report_roles() {
  step "Report group roles (Reports-<Sub-Group>)"

  REPORT_ROLES_STATUS=""; REPORT_ROLES_DETAIL=""; REPORT_ROLES_BACKUP=""

  if [ "${REPORT_ROLES_FIX:-0}" != "1" ]; then
    info "Not requested; pass --fix-report-roles to create the report group roles."
    REPORT_ROLES_STATUS="disabled"; REPORT_ROLES_DETAIL="not requested (--fix-report-roles)"
    return 0
  fi

  _concepts_resolve_compose >/dev/null 2>&1 || {
    REPORT_ROLES_STATUS="no-db"; REPORT_ROLES_DETAIL="docker compose not available on this host"
    return 0
  }
  if [ ! -d "$RESTORE_DIR" ]; then
    REPORT_ROLES_STATUS="no-db"; REPORT_ROLES_DETAIL="no stack directory at ${RESTORE_DIR}"
    return 0
  fi
  if ! _concepts_db_ready; then
    warn "${DB_SERVICE}:${DB_NAME} is not accepting connections right now."
    warn "A freshly started v1 stack needs 30+ minutes before its database answers,"
    warn "so this is expected straight after an upgrade — it is not an error."
    REPORT_ROLES_STATUS="no-db"
    REPORT_ROLES_DETAIL="${DB_SERVICE}:${DB_NAME} not reachable — re-run catch-up once the stack is up"
    return 0
  fi

  local row roles inherit assign has_app has_user
  row="$(_rr_missing)" || row=""
  if [ -z "$row" ]; then
    error "Could not read the role tables in '${DB_NAME}'."
    REPORT_ROLES_STATUS="failed"; REPORT_ROLES_DETAIL="could not query role/role_role/user_role"
    return 1
  fi
  IFS=$'\t' read -r roles inherit assign has_app has_user <<<"$row"

  [ "$has_app" = "1" ] || warn "There is no 'Reports-App' role in '${DB_NAME}': the group roles cannot inherit it."
  [ "$has_user" = "1" ] || warn "There is no user '${REPORT_ROLES_USER}' in '${DB_NAME}': no roles will be assigned (set EREGISTER_REPORT_ROLES_USER)."

  if [ "$roles" = "0" ] && [ "$inherit" = "0" ] && [ "$assign" = "0" ]; then
    _rr_settle "already" "all ${#_REPORT_ROLES[@]} group roles present and held by '${REPORT_ROLES_USER}'" \
               "$has_app" "$has_user"
    return 0
  fi

  info "Missing: ${roles} group role(s), ${inherit} Reports-App inheritance link(s),"
  info "${assign} role assignment(s) for '${REPORT_ROLES_USER}'."
  if ! confirm "Create the report group roles and assign them to '${REPORT_ROLES_USER}' now?"; then
    warn "Report group roles skipped by user."
    REPORT_ROLES_STATUS="declined"; REPORT_ROLES_DETAIL="declined — Reports dashboard stays blank"
    return 0
  fi

  if ! _rr_backup; then
    error "Could not back up the role tables; nothing was changed."
    REPORT_ROLES_STATUS="failed"; REPORT_ROLES_DETAIL="pre-change backup failed — nothing changed"
    return 1
  fi

  if ! _rr_apply; then
    error "The role inserts failed. Restore from ${REPORT_ROLES_BACKUP} if needed."
    REPORT_ROLES_STATUS="failed"; REPORT_ROLES_DETAIL="INSERT failed (backup: ${REPORT_ROLES_BACKUP})"
    return 1
  fi

  # Read it back rather than trusting the exit status.
  row="$(_rr_missing)" || row=""
  IFS=$'\t' read -r roles inherit assign has_app has_user <<<"$row"
  if [ "$roles" != "0" ] || [ "$inherit" != "0" ] || [ "$assign" != "0" ]; then
    error "The inserts ran but ${roles:-?} role(s), ${inherit:-?} link(s), ${assign:-?} assignment(s) are still missing."
    REPORT_ROLES_STATUS="failed"; REPORT_ROLES_DETAIL="still incomplete after the INSERTs"
    return 1
  fi

  info "Users holding each report role:"
  _concepts_mysql -t 2>/dev/null <<'SQL' >&2 || true
SELECT r.role, COUNT(ur.user_id) AS users_assigned
FROM   role r
LEFT   JOIN user_role ur ON ur.role = r.role
WHERE  r.role LIKE 'Reports-%'
GROUP  BY r.role
ORDER  BY r.role;
SQL

  _rr_settle "fixed" "group roles created, inherit Reports-App, assigned to '${REPORT_ROLES_USER}'" \
             "$has_app" "$has_user"
  [ "$REPORT_ROLES_STATUS" = "fixed" ] && success "Report group roles in place. Users must log in again to see them."
  return 0
}

# _rr_settle <status> <detail> <has Reports-App> <user exists> — a missing
# Reports-App or user means the fix could not be completed: report it as partial.
_rr_settle() {
  REPORT_ROLES_STATUS="$1"; REPORT_ROLES_DETAIL="$2"
  if [ "$3" != "1" ]; then
    REPORT_ROLES_STATUS="partial"
    REPORT_ROLES_DETAIL="no 'Reports-App' role in ${DB_NAME} — group roles cannot inherit it"
  elif [ "$4" != "1" ]; then
    REPORT_ROLES_STATUS="partial"
    REPORT_ROLES_DETAIL="no user '${REPORT_ROLES_USER}' in ${DB_NAME} — roles created, none assigned (set EREGISTER_REPORT_ROLES_USER)"
  fi
}
