# Fix: Clinical patient-queue tabs stuck on "(...)"

**Symptom:** On `/bahmni/clinical`, the Active, My Patients, OPD-1 and PatientsByLocation tabs never load. Programs works.

**Cause:** The openmrs DB is missing the custom `emrapi.sqlSearch.queue.*` global properties. OpenMRS logs `No such query:emrapi.sqlSearch.queue.activePatients` (also `...ByProvider` and `...ByLocation`). They were lost on the DB restore of 2026-11-10. Nothing in `standard-config-ls` creates them: `addQueueNumberToQueueSqlSearch.xml` only UPDATEs these rows if they already exist.

**Fix:** re-insert the 3 rows from the 2026-11-06 dump (`fix_queue_sqlsearch.sql`). It is idempotent and safe to re-run.

## Quick way (from any directory, e.g. `~`)

```bash
~/upgrade-to-v1/queue-fix.sh --check     # report only
~/upgrade-to-v1/queue-fix.sh             # back up to ./backups/, apply, verify
~/upgrade-to-v1/queue-fix.sh --rollback  # undo
~/upgrade-to-v1/queue-fix.sh --fix-gp    # Notifications tab: reload gp_clinical.xml (RESTARTS OpenMRS)
```

`--fix-gp` handles a second restore problem. Initializer keeps a checksum of
`masterdata/configuration/globalproperties/gp_clinical.xml` in the openmrs data volume, so after a DB
restore it never re-loads that file. The DB is then missing `emrapi.sqlSearch.labResultNotifications`
(Notifications tab) and `emrapi.sqlSearch.emergencyMedicationToAcknowledge`. The option saves and deletes
`gp_clinical.checksum`, restarts OpenMRS, and waits for both properties to appear. To undo, delete the two
properties; the saved checksum is in `backups/`.

## Manual way

Run every block from this folder on the Docker host:

```bash
cd ~/upgrade-to-v1
DB=bahmni-standard-openmrsdb-1
```

## 1. Back up the current sqlSearch rows

```bash
docker exec $DB sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --no-create-info --replace --skip-extended-insert openmrs global_property --where="property LIKE '"'"'emrapi.sqlSearch%'"'"'"' 2>/dev/null > backup_sqlsearch_$(date +%Y%m%d_%H%M%S).sql
ls -la backup_sqlsearch_*.sql
```

## 2. Apply the fix

```bash
docker exec -i $DB sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" openmrs' < fix_queue_sqlsearch.sql 2>&1 | grep -v Warning
```

The output should list the 3 `emrapi.sqlSearch.queue.*` properties.

## 3. Verify

1. Hard-reload `https://192.168.8.8/bahmni/clinical/index.html` (Ctrl+Shift+R).
2. Each queue tab should show a count, e.g. "Active (n)".
3. Check that OpenMRS is no longer rejecting the queries:

```bash
docker logs --since 5m bahmni-standard-openmrs-1 2>&1 | grep -c "No such query:emrapi.sqlSearch.queue"   # expect 0
```

If the count is not 0 after a reload, restart OpenMRS once to clear the global-property cache. This takes a few minutes of downtime.

```bash
docker restart bahmni-standard-openmrs-1
```

## Rollback

```bash
docker exec -i $DB sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" openmrs' < rollback_queue_sqlsearch.sql 2>&1 | grep -v Warning
# then, to put back exactly what step 1 saved:
docker exec -i $DB sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" openmrs' < backup_sqlsearch_YYYYMMDD_HHMMSS.sql
```

## Preventing it next time

Any restore from a dump without these rows will break the queue again. To make it permanent, ship `fix_queue_sqlsearch.sql` as a Liquibase changeset in `standard-config-ls/openmrs/migrations/`. Add a precondition so it only runs when `emrapi.sqlSearch.queue.%` rows are missing, and include it *before* `addQueueNumberToQueueSqlSearch.xml` in `liquibase.xml`.
