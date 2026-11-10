# Fix: Clinical patient-queue tabs stuck on "(...)"

**Symptom:** On `/bahmni/clinical`, the Active, My Patients, OPD-1 and PatientsByLocation tabs never load. Programs works.

**Cause:** The openmrs DB is missing the custom `emrapi.sqlSearch.queue.*` global properties. OpenMRS logs `No such query:emrapi.sqlSearch.queue.activePatients` (also `...ByProvider` and `...ByLocation`). They were lost on the DB restore of 2026-11-10. Nothing in `standard-config-ls` creates them: `addQueueNumberToQueueSqlSearch.xml` only UPDATEs these rows if they already exist.

**Fix:** re-insert the 3 rows from the 2026-11-06 dump (`fix_queue_sqlsearch.sql`). It is idempotent and safe to re-run.

## Quick way (from any directory, e.g. `~`)

```bash
~/upgrade-to-v1/queue-fix.sh --check     # to check the status, if it's 0/3 you need to run the fix
~/upgrade-to-v1/queue-fix.sh             # back up to ./backups/, apply, verify. After running this you can run the check and it should say 3/3
~/upgrade-to-v1/queue-fix.sh --fix-gp    # Notifications tab: reload gp_clinical.xml (RESTARTS OpenMRS)
~/upgrade-to-v1/queue-fix.sh --rollback  # undo
```

`--fix-gp` handles a second restore problem. Initializer keeps a checksum of
`masterdata/configuration/globalproperties/gp_clinical.xml` in the openmrs data volume, so after a DB
restore it never re-loads that file. The DB is then missing `emrapi.sqlSearch.labResultNotifications`
(Notifications tab) and `emrapi.sqlSearch.emergencyMedicationToAcknowledge`. The option saves and deletes
`gp_clinical.checksum`, restarts OpenMRS, and waits for both properties to appear. To undo, delete the two
properties; the saved checksum is in `backups/`.

