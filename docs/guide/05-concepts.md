# 5. The concept dictionary

The `eregister_concepts_release_v1` repo ships a **mysqldump of the OpenMRS
concept dictionary** — `omrs_concept_dictionary_<timestamp>.sql`. It is loaded
into the `openmrs` database inside the `openmrsdb` service.

> [!IMPORTANT]
> **Nothing imports this during the upgrade, and `catch-up.sh` only ever reports
> on it.** The import drops and recreates whole tables, which is a big enough
> operation to belong to a job of its own, or to a deliberate manual run.

## 5.1 What the import actually does

The dump is a plain mysqldump with `FOREIGN_KEY_CHECKS=0`, `DROP TABLE IF
EXISTS` + `CREATE TABLE` + `INSERT`s. Importing it therefore **replaces those
tables wholesale** rather than merging into them.

The table list is not hard-coded. It is read straight out of the `.sql` file
being imported:

```bash
sed -n 's/^DROP TABLE IF EXISTS `\([A-Za-z0-9_]*\)`.*/\1/p' <dump> | sort -u
```

so the pre-import backup always matches the file about to be imported, even when
a new release adds a table.

> [!CAUTION]
> **`drug_order` is among those tables.** Any drug orders the site currently
> holds are replaced. This is the single most important thing to understand
> about this import.

A pre-import dump of exactly those tables is written to
`<base>/v1/bahmni-backup/concepts-preimport-<stamp>.sql` before anything is
replaced, so the import can be undone by feeding that file back in.

## 5.2 Who imports it, and when

| Path | When |
|---|---|
| **Delayed first run** | ~3 hours after `install.sh` finishes, once, via a transient systemd timer (`eregister-concept-import-first.timer`) or an `at` job |
| **The daily job** | 04:30 every night — but only when the dump's content differs from the one already loaded |
| **`./import-concepts.sh`** | Whenever you want, by hand |
| **`catch-up.sh`** | **Never.** It reports only |

If neither systemd nor `at` is available, the daily job simply takes the first
import.

### Why the delay

When `install.sh` finishes, the stack has only just been started. `openmrsdb`
answers early, but the instance behind it needs 30+ minutes — often hours on site
hardware — before importing a dictionary is worth doing.

Doing it inline therefore either blocked the run or skipped for nothing, and
either way it asked the operator to authorise replacing the `concept_*`/`drug*`
tables at the least informative possible moment.

### Change detection

The daily job records the sha256 of the dump it imported in
`<base>/v1/.eregister_concept_import_state`. A night where the clone has not
moved does nothing at all.

## 5.3 What `catch-up.sh` reports

```
  ✔ OK    concepts  dump       omrs_concept_dictionary_20260804.sql (newest of 3)
  ✔ OK    concepts  imported   sha256 matches the dump on disk
  ✔ OK    concepts  database   openmrs.concept holds 41,208 rows
```

The severity of the `imported` row depends on whether the daily job is actually
scheduled:

- a **newer dump with the job in place** → `OK`. It is simply pending tonight.
- the **same dump with no job scheduled** → `GAP`. Nothing will ever load it.

`--no-concepts` silences these rows *and* leaves the daily job alone — reporting
a gap that tells you to run the job you just disabled would be noise, and it
would fail the exit code for a state you chose.

## 5.4 The OCL concept-name fix

Run **once**, after the v1 instance has fully started and finished its OCL
import (~30+ minutes after the stack starts).

During that import OCL voids the local concept names (reason "Removed from OCL")
and inserts its own replacements. `ocl-fix.sh`:

1. **Unvoids** the original names and **voids** OCL's replacements, in the
   `openmrs` database of the `openmrsdb` service.
2. **Renames** `CIEL_*.zip` → `.DONE` in the OCL directory of the `openmrs`
   service, so the import does not run again on the next startup.

Naturally idempotent: a second run finds nothing to unvoid and no zip to move.

```bash
./ocl-fix.sh [--yes] [--install-dir DIR] [--no-color] [--help]
```

```bash
curl -fsSL --retry 8 --retry-max-time 180 \
  https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/ocl-fix.sh | bash
```

| Variable | Default |
|---|---|
| `EREGISTER_INSTALL_BASE` | `/var/lib` |
| `EREGISTER_DB_SERVICE` | `openmrsdb` |
| `EREGISTER_EMR_SERVICE` | `openmrs` |
| `EREGISTER_OCL_DIR` | `/openmrs/data/configuration/ocl` |
| `EREGISTER_DB_PASS` | *(the container's own `MYSQL_ROOT_PASSWORD`)* |

## 5.5 `import-concepts.sh`

```bash
./import-concepts.sh [--yes] [--install-dir DIR] [--no-color] [--help]
./import-concepts.sh --schedule    # install the DAILY job instead of importing now
```

Import now:

```bash
sudo ./import-concepts.sh
```

Install (or re-install) the daily job without importing:

```bash
sudo ./import-concepts.sh --schedule
```

From the network:

```bash
curl -fsSL --retry 8 --retry-max-time 180 \
  https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/import-concepts.sh | bash
```

### Before it writes, it warns

```
[⚠] This REPLACES the concept dictionary in the 'openmrs' database with
[⚠] the dump in /var/lib/v1/eregister_concepts_release_v1/omrs_concept_dictionary_20260804.sql.
[⚠] The tables it drops and recreates include drug_order — so any rows those
[⚠] tables currently hold are replaced.
[ℹ] Backing up the tables about to be replaced -> /var/lib/v1/bahmni-backup/concepts-preimport-20260921_141203.sql
```

### Undoing an import

```bash
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo cat /var/lib/v1/bahmni-backup/concepts-preimport-<stamp>.sql \
  | sudo docker compose exec -T openmrsdb mysql -uroot -p openmrs
```

## 5.6 Choosing which dump to import

The repo's own tooling names each release with a timestamp
(`run_concept_dump.sh` writes `omrs_concept_dictionary_$(date +%Y%m%d_%H%M%S).sql`),
so there is no fixed filename to pin.

- Leave `EREGISTER_CONCEPTS_SQL_NAME` **empty** (the normal case) to pick the
  newest file matching `EREGISTER_CONCEPTS_SQL_PATTERN`
  (default `omrs_concept_dictionary*.sql`).
- Set it to pin one exact filename.

## 5.7 Database connectivity

Every step that talks to the database asks **once** and does not poll:

```
[⚠] openmrsdb:openmrs is not accepting connections right now.
[⚠] A freshly started v1 stack needs 30+ minutes before its database answers,
[⚠] so this is expected straight after an upgrade — it is not an error.
[⚠] Skipping the concept dictionary; nothing else in this run depends on it.
[⚠] Load it once the stack is up with:  ./import-concepts.sh
```

This used to poll for up to five minutes, on the theory that the import runs
while the stack is still booting. In practice that turned a skippable step into a
five-minute hang whenever `openmrsdb` was not coming up at all — and the import
is not on the critical path. So: ask once, and if the answer is no, say why and
move on.

The password comes from `EREGISTER_DB_PASS` when set, else the container's own
`MYSQL_ROOT_PASSWORD`, so it never lands on a host process list.

## 5.8 Configuration summary

| Variable | Default | Meaning |
|---|---|---|
| `EREGISTER_IMPORT_CONCEPTS` | `1` | `0` (or `--no-concepts`) disables the import |
| `EREGISTER_CONCEPTS_SQL_NAME` | *(empty)* | Pin one exact dump filename |
| `EREGISTER_CONCEPTS_SQL_PATTERN` | `omrs_concept_dictionary*.sql` | Which files to consider |
| `EREGISTER_CONCEPT_IMPORT` | `1` | `0` does not install the daily job |
| `EREGISTER_CONCEPT_IMPORT_CRON` | `30 4 * * *` | cron schedule |
| `EREGISTER_CONCEPT_IMPORT_ONCALENDAR` | `*-*-* 04:30:00` | systemd schedule |
| `EREGISTER_CONCEPT_IMPORT_FIRST_RUN` | `1` | `0` = no delayed first run |
| `EREGISTER_CONCEPT_IMPORT_FIRST_DELAY_SEC` | `10800` (3h) | How long to wait for it |
| `EREGISTER_CONCEPT_IMPORT_RESTART_EMR` | `0` | Restart the EMR after an import (30+ min downtime) |

> [!NOTE]
> An imported dictionary is only visible after the EMR restarts.
