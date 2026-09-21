# 6. OpenMRS report definitions

The `openmrs_reporting_release` repo ships a **mysqldump of the OpenMRS
reporting module's `serialized_object` table** — currently
`Serialized_Object.sql`.

That table *is* the report library: every report, cohort, indicator and dataset
definition the Reports app offers is one serialized XML row in it.

## 6.1 The one import catch-up performs itself

`catch-up.sh` imports this directly, where it only ever **reports** on the
concept dictionary. It earns that difference:

| | Concept dictionary | Report definitions |
|---|---|---|
| Tables replaced | `concept_*`, `drug*`, including `drug_order` | `serialized_object` only |
| Patient data touched | Drug orders are replaced | None |
| Blast radius | Large | One table of report definitions |
| Undo | Pre-import dump | Pre-import dump |
| Who imports it | The daily job, or you | `catch-up.sh` |

> [!WARNING]
> Importing **replaces** the table rather than merging into it. Report
> definitions written on this site by hand, and not present in the release, are
> lost. The pre-import dump is what gets them back.

## 6.2 What one run does

1. Resolve which `.sql` file(s) to import
2. Hash them and compare against `<base>/v1/.eregister_reporting_import_state`
3. **If unchanged — stop.** Nothing is touched
4. Dump the current `serialized_object` to
   `<base>/v1/bahmni-backup/reporting-preimport-<stamp>.sql`
5. Feed the release dump into `openmrsdb:openmrs`
6. Record the new hash

Re-runnable by design: a second run with an unchanged clone does nothing at all,
and a run after the auto-pull job brings in a new release imports the new
definitions.

## 6.3 Which files get imported

- Leave `EREGISTER_REPORTING_SQL_NAME` **empty** (the normal case) to import
  every file matching `EREGISTER_REPORTING_SQL_PATTERN` (default `*.sql`) at the
  top of the clone, in filename order. A second dump added upstream is then
  picked up without a code change.
- Set it to pin one exact filename.

## 6.4 Report rows

```
  ✔ OK     reporting import    already current (sha256 matches the clone)
  ⟳ FIXED  reporting import    imported Serialized_Object.sql — pre-import dump in /var/lib/v1/bahmni-backup/
  ✘ GAP    reporting import    openmrsdb:openmrs not reachable — re-run catch-up once the stack is up
  — SKIP   reporting import    disabled (--no-reporting)
```

`--no-reporting` still clones and fast-forwards the repo; only the database
import is skipped.

## 6.5 Forcing and undoing

```bash
# re-import (skipped when already current)
sudo /var/lib/v1/upgrade-to-v1/catch-up.sh

# force one: drop the state marker, then run again
sudo rm /var/lib/v1/.eregister_reporting_import_state
sudo /var/lib/v1/upgrade-to-v1/catch-up.sh

# undo one
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo cat /var/lib/v1/bahmni-backup/reporting-preimport-<stamp>.sql \
  | sudo docker compose exec -T openmrsdb mysql -uroot -p openmrs
```

> [!NOTE]
> **New reports only appear after the EMR restarts.** The catch-up run's final
> step does that for you unless `--no-recreate` was passed.

## 6.6 Configuration summary

| Variable | Default | Meaning |
|---|---|---|
| `EREGISTER_IMPORT_REPORTING` | `1` | `0` (or `--no-reporting`) skips the import |
| `EREGISTER_REPORTING_SQL_NAME` | *(empty)* | Pin one exact filename |
| `EREGISTER_REPORTING_SQL_PATTERN` | `*.sql` | Which files to consider |
| `EREGISTER_REF_REPORTING` | `master` | The repo's branch |
