To run this script, just copy and paste this line below in your terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/install.sh | bash
```

## Already on v1? Run the catch-up script

These scripts keep gaining steps — asset repos, the concept dictionary, the
nightly repo auto-pull, the daily clinical form import. A site installed from an
earlier version never got the newer ones. **This one line checks everything the
installer is meant to have set up and redoes only what is missing or out of
date**, on a live site:

```bash
curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/catch-up.sh | bash
```

> [!NOTE]
> Every check is read-only, every repo update is a fast-forward, and a repo with
> local changes is reported and left alone. **One step does act on a running
> container:** the last job recreates the EMR service
> (`docker compose up -d --force-recreate --renew-anon-volumes openmrs`) so the
> refreshed config, omods and forms are actually loaded. That costs the EMR's
> usual 30+ minute boot, so run it outside clinic hours — or pass
> `--no-recreate` to skip it. Patient data lives in the `openmrsdb` service and
> its named volumes and is not touched.

It updates itself first (`git pull`, then re-runs from the fresh copy), so the
line above always applies the newest checks. Non-interactive form:

```bash
curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/catch-up.sh | sudo EREGISTER_BAHMNI_PASS='<superman password>' bash -s -- --yes
```

Useful flags: `--no-recreate` (skip the EMR reload — then nothing touches a
running container), `--force-repos` (bring off-release repos back, discarding
local changes), `--no-stack` (leave `bahmni-docker-ls` alone), `--no-forms`,
`--no-db-backup` (leave the nightly database backup alone), `--install-dir DIR`. It exits `0` only when there are no gaps, so it also works
as a monitoring check. Full detail: [Catching an early site up](#catching-an-early-site-up).

> [!WARNING]
> If you need to do the upgrade process again, remember to run:
> `docker volume rm $(docker volume ls -q)` to clean all volumes.
> Make sure all volumes are deleted with `docker volume ls`

An example of how to use flags below:

```bash
curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/install.sh | bash -s -- --force --yes
```

### If the installer stopped part-way through

The installer writes `/var/lib/v1/.eregister-upgrade-complete` to record **how
far** it got, not merely that it ran:

| `stage=` | meaning | what a re-run does |
|---|---|---|
| *(no file)* | nothing has been installed | runs the whole upgrade |
| `migrated` | the stack was migrated, verified and started, but the post-install steps (concept import, form import, auto-updates) had not finished | redoes the upgrade from the top, **reusing the backup already in `/var/lib/v1/bahmni-backup`**, then finishes the outstanding steps |
| `complete` | the whole run finished | prints a reference card and exits with "nothing to do" |

Only `complete` short-circuits. Before this was recorded, a Ctrl-C or a dropped
ssh session anywhere in the post-install steps left a bare marker that said
"installed", and every later run exited on it — printing a summary of work it
had never done.

**The backup is reused, never retaken.** `openmrsdb_backup.sql` is the 0.92 data
the restore needs, and once an earlier run has frozen the old stack it cannot be
retaken at all, so a re-run loads the file that is already there. That also
means the restore reloads the `openmrs` database from it — anything entered
since the backup was made is replaced. To reconcile a site *without* touching
the backup or the restore, use [`catch-up.sh`](#catching-an-early-site-up)
instead.

`--force` redoes everything regardless of the stage; it retakes the backup only
if the 0.92 EMR container is still running, and otherwise reuses the existing
one.

What to do next:
1. cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
2. Confirm services are healthy:
        `docker compose ps`
3. If anything is down, bring it up with:
         docker compose up -d
4. After the instance is FULLY up and the OCL import has finished (~30+ min), apply the OCL concept-name fix (run once):

```bash
curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/ocl-fix.sh | bash
```
(or, from the upgrade repo:  `bash ./ocl-fix.sh`)

5. Once verified, the old install in /home/kgatman/bahmni_docker can be archived.

# Refactoring it so that I can maintain it better

The functions are split into modules under `lib/`, grouped by concern. Only
`main()` and the module loader live in `install.sh`.

```text
install.sh                       # header + load_modules() + main() + main "$@"
lib/
├── core/
│   ├── config.sh                # all defaults / runtime-state vars
│   ├── logging.sh               # setup_colors, log/info/warn/error/success/step, banner
│   ├── traps.sh                 # on_error, cleanup, install_traps
│   ├── prompt.sh                # confirm, confirm_step, prompt_db_password
│   └── cli.sh                   # usage, parse_args, resolve_config, print_config
├── system/
│   ├── platform.sh              # detect_platform
│   ├── privilege.sh             # detect_privilege, as_root
│   └── deps.sh                  # detect_pkg_mgr, pkg_install, ensure_deps
└── upgrade/
    ├── verify.sh                # verify_checksum, verify_gpg, git_clone_or_update
    ├── detect.sh                # read_current_version
    ├── backup.sh                # ensure_dir, take_backup (the ONE pre-upgrade dump)
    ├── migrate.sh               # shutdown_old_stack, fetch_repos, run_restore
    ├── rollback.sh              # rollback
    ├── postinstall.sh           # post_verify, next_steps
    ├── concepts.sh              # import_concepts + the scheduled/delayed job
    ├── reporting.sh             # import_reporting (openmrs_reporting_release -> openmrsdb)
    ├── forms.sh                 # install_form_import (clinical-obs-forms -> EMR, daily)
    ├── autopull.sh              # install_auto_pull (systemd timer / cron.d)
    ├── dbbackup.sh              # install_db_backup (nightly openmrsdb dump, daily)
    └── catchup.sh               # catch_up (reconcile a deployed site + report)
bin/
└── bahmni_form_import.sh        # the form importer itself (installed to /usr/local/bin)
```

# Importing the concept dictionary

The concept dictionary lives in the `eregister_concepts_release_v1` clone
(`/var/lib/v1/eregister_concepts_release_v1/omrs_concept_dictionary_*.sql`) and
is loaded into the `openmrs` database inside the `openmrsdb` container — the
scripted version of that repo's manual `docker cp` + `mysql source`
instructions.

**The installer does not import it.** When an upgrade finishes, the stack has
only just been started: `openmrsdb` answers early, but the instance behind it
needs 30+ minutes — hours on site hardware — before importing a dictionary is
worth doing. So instead of importing inline, the installer installs the import
job and gives it **one delayed run, 3 hours out**, after which
[the daily job](#the-daily-concept-dictionary-job) keeps it current.

| | |
| --- | --- |
| with systemd | a transient timer, `eregister-concept-import-first.timer` |
| without systemd | an `at` job |
| neither available | nothing one-off; the daily job takes the first import |

```bash
systemctl list-timers eregister-concept-import-first.timer   # when it fires
sudo systemctl stop eregister-concept-import-first.timer     # cancel it
sudo /usr/local/bin/eregister-concept-import.sh              # or just run it now
```

The transient timer does not survive a reboot; if the box restarts before it
fires, the daily job becomes the first import. Tune it with
`EREGISTER_CONCEPT_IMPORT_FIRST_DELAY_SEC` (default `10800`) or turn it off with
`EREGISTER_CONCEPT_IMPORT_FIRST_RUN=0`. `--no-concepts` installs no concept job
at all.

The dump is a mysqldump with `DROP TABLE IF EXISTS` + `CREATE TABLE` for the
`concept_*` and `drug*` tables, so it **replaces** them rather than merging.
`drug_order` is one of those tables. Before importing, the current contents of
exactly the tables the file touches are dumped to
`/var/lib/v1/bahmni-backup/concepts-preimport-<timestamp>.sql`; feed that file
back the same way to undo the import.

Re-run it on its own at any time:

```bash
curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/import-concepts.sh | bash
```
(or, from the upgrade repo: `bash ./import-concepts.sh`)

## Which dump gets imported

The repo names every release after the moment it was taken —
`run_concept_dump.sh` writes `omrs_concept_dictionary_$(date +%Y%m%d_%H%M%S).sql`
— so there is **no fixed filename**: today's is
`omrs_concept_dictionary_20260804.sql`, and the next release lands beside it
under a new name. The importer therefore takes the **newest file matching
`omrs_concept_dictionary*.sql`** (names sort chronologically). Pin one exact
file with `EREGISTER_CONCEPTS_SQL_NAME`, or change the pattern with
`EREGISTER_CONCEPTS_SQL_PATTERN`.

## The daily concept-dictionary job

Its own job, separate from the daily form import and independent of it. One run:

1. fast-forwards `/var/lib/v1/eregister_concepts_release_v1`;
2. picks the newest `omrs_concept_dictionary_*.sql` in it;
3. **imports it only if its content changed** — the sha256 of the dump that was
   imported is recorded in `/var/lib/v1/.eregister_concept_import_state`, so a
   nightly run on an unchanged dictionary does nothing at all;
4. logs that the EMR needs a restart before the new dictionary is visible
   (OpenMRS caches concepts).

| Path | What it is |
| --- | --- |
| `/usr/local/bin/eregister-concept-import.sh` | the runner cron/systemd calls |
| `eregister-concept-import.timer` or `/etc/cron.d/eregister-concept-import` | the daily schedule (04:30) |
| `eregister-concept-import-first.timer` | the one-off first run, ~3h after install (transient) |
| `/var/lib/v1/.eregister_concept_import_state` | sha256 + filename + date of the last import |
| `/var/log/eregister-concept-import.log` | every run |

The runner does the cheap parts itself (refresh, pick, compare) and hands the
import to `import-concepts.sh` from the site's own checkout, so the pre-import
backup, the DB wait and the import itself live in one place rather than being
copied into a generated file. Detection is on **content**, not filename: a
re-published dump under the same name is imported, an unchanged one is not.

Install it (the installer offers it automatically at the end of an upgrade):

```bash
sudo ./import-concepts.sh --schedule
sudo /usr/local/bin/eregister-concept-import.sh    # run one check now
```

Tune it with `EREGISTER_CONCEPT_IMPORT=0` (do not install the job),
`EREGISTER_CONCEPT_IMPORT_CRON` (default `30 4 * * *`),
`EREGISTER_CONCEPT_IMPORT_ONCALENDAR` (default `*-*-* 04:30:00`),
`EREGISTER_CONCEPT_IMPORT_SELF_PULL=0` (import what is on disk, no refresh).

> [!WARNING]
> **The EMR restart is not automatic.** OpenMRS caches concepts, so an imported
> dictionary stays invisible until `openmrs` restarts — 30+ minutes of downtime,
> which the job will not take unattended. It logs a `NOTE` instead, and
> `catch-up.sh` recreates the service at the end of its run. Set
> `EREGISTER_CONCEPT_IMPORT_RESTART_EMR=1` if you want the job to restart the
> EMR itself after an import.

# Importing the OpenMRS report definitions

The `openmrs_reporting_release` clone
(`/var/lib/v1/openmrs_reporting_release/Serialized_Object.sql`) is a mysqldump
of the OpenMRS reporting module's `serialized_object` table. That table **is**
the report library: every report, cohort, indicator and dataset definition the
Reports app lists is one serialized XML row in it.

**The installer clones it but does not import it**, for the same reason it does
not import the concept dictionary — when an upgrade finishes the database behind
the stack is minutes old. **`catch-up.sh` does the import**, and it is the one
import catch-up performs itself rather than reporting on:

- it replaces **one table**, `serialized_object`. No patient data, no concepts,
  no obs;
- the current contents of exactly the tables the dump touches are written to
  `/var/lib/v1/bahmni-backup/reporting-preimport-<timestamp>.sql` first, so
  feeding that file back undoes the import;
- it is content-addressed. The sha256 of what was imported is recorded in
  `/var/lib/v1/.eregister_reporting_import_state`, so a clone whose dump is
  already the one in the database costs a hash and stops there — catch-up can be
  run nightly without ever re-importing the same definitions;
- nothing else schedules it. The concept dictionary has a daily job to defer to;
  the report definitions do not, so reporting a gap and leaving it would leave
  that gap open forever.

The auto-pull job keeps the clone current, so a new release of the definitions
lands on disk on its own and the next catch-up run imports it.

```bash
sudo ./catch-up.sh                       # imports if the dump is new
sudo rm /var/lib/v1/.eregister_reporting_import_state && sudo ./catch-up.sh   # force a re-import
```

By default every `*.sql` at the top of the clone is imported, in filename order
— today that is the repo's single `Serialized_Object.sql`, and a second dump
added upstream is picked up with no code change. Pin one file with
`EREGISTER_REPORTING_SQL_NAME`, change the pattern with
`EREGISTER_REPORTING_SQL_PATTERN`, track a different branch with
`EREGISTER_REF_REPORTING` (default `master`), or skip the import entirely with
`--no-reporting` / `EREGISTER_IMPORT_REPORTING=0`.

> [!WARNING]
> Like the concept dictionary, this **replaces** rather than merges: report
> definitions written on this site by hand, and not present in the release, are
> gone after an import. And OpenMRS caches them — new reports appear only after
> `openmrs` restarts, which catch-up's final step does anyway.

The four scheduled jobs are deliberately independent, and run in this order:

| Job | Schedule | Does |
| --- | --- | --- |
| `eregister-db-backup` | 01:30 | dumps the `openmrs` database |
| `eregister-autopull` | 02:30 | fast-forwards the seven asset/config repos |
| `eregister-form-import` | 03:30 | deploys changed clinical forms |
| `eregister-concept-import` | 04:30 | imports a changed concept dictionary |

The backup goes first on purpose: the three jobs after it all write to the site
in some way, so each night's dump is of the database as it stood *before* any of
them ran.

OpenMRS caches concepts, so restart the EMR service afterwards for the new
dictionary to show up:
`docker compose restart openmrs` (from `/var/lib/v1/bahmni-docker-ls/bahmni-standard`).

Skip or tune it with `--no-concepts`, `EREGISTER_CONCEPTS_SQL_NAME` (dump
filename), and the first-run knobs above.

Whenever it does run, the importer probes `openmrsdb` **once**; it does not wait
on it. If the database is not answering yet it says so and skips, rather than
blocking — run `./import-concepts.sh` again later, or leave it to the daily job.

# Importing the clinical observation forms

The `clinical-obs-forms` repo holds Bahmni Form Builder JSON exports. At the end
of a run the installer deploys them into the running EMR over its REST API —
concept UUID fix-up, `POST /form`, save body, save translations — which is
exactly what the Implementer Interface's **Import** button does, minus the
~1700 parallel fetches that produce its "Failed to fetch" errors.

It installs:

| Path | What it is |
| --- | --- |
| `/usr/local/bin/bahmni-form-import.sh` | the importer (`bin/bahmni_form_import.sh` in this repo) |
| `/usr/local/bin/eregister-form-import.sh` | the wrapper cron/systemd runs: sources the credentials, refreshes the clone, imports the folder |
| `/etc/eregister/form-import.env` | EMR URL / user / password, mode `0600` |
| `eregister-form-import.timer` or `/etc/cron.d/eregister-form-import` | the **daily** schedule (03:30, after the 02:30 auto-pull) |
| `/var/lib/v1/.bahmni_form_import_state.json` | what has been deployed: version + sha256 per form |
| `/var/log/eregister-form-import.log` | log of every run |

Called with no path the importer imports
`${BAHMNI_FORMS_DIR:-${eRegister_HOME:-/var/lib/v1}/clinical-obs-forms}` —
the deployed clone — recursively. (It used to default to a local `forms/`
folder.) Files or folders can still be passed explicitly.

## How it knows a form is new

Detection is on file **content**, never on the file name or its timestamp:

- each form's sha256 is recorded against `<server URL>|<form name>` in the state
  file, so the same folder can be re-imported nightly and nothing moves unless
  an author actually changed something;
- a same-named file holding a **new export** hashes differently and is deployed
  as a **new version** — `max(recorded version, version on the server) + 1` — so
  the live version is never overwritten and the version history stays intact;
- a file that was merely re-checked-out by the auto-pull job (fresh mtime,
  identical bytes), re-downloaded or renamed is recognised as already deployed
  and skipped;
- the state file lives in `/var/lib/v1/`, **outside** the clone, so the
  auto-pull job's `git reset --hard` cannot erase the deployment record. Even if
  it were lost, the next version number is still taken from the server.

Run one by hand at any time:

```bash
sudo /usr/local/bin/eregister-form-import.sh          # the scheduled job, now
sudo /usr/local/bin/bahmni-form-import.sh -k --dry-run  # validate concepts only
sudo /usr/local/bin/bahmni-form-import.sh -k --force     # re-deploy everything
```

Re-install or re-schedule the whole thing (also useful if it was skipped during
the upgrade):

```bash
curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/import-forms.sh | bash
```
(or, from the upgrade repo: `bash ./import-forms.sh`)

Skip or tune it with `--no-forms` / `EREGISTER_IMPORT_FORMS=0`,
`EREGISTER_BAHMNI_URL`, `EREGISTER_BAHMNI_USER`, `EREGISTER_BAHMNI_PASS`
(needed for a non-interactive install — otherwise the password is prompted),
`EREGISTER_FORMS_DIR`, `EREGISTER_FORM_IMPORT_CRON` (default `30 3 * * *`) and
`EREGISTER_FORM_IMPORT_ONCALENDAR` (default `*-*-* 03:30:00`).

A form whose concepts are not in the dictionary is **not** deployed: the run
writes `<form>.importErrors.txt` into `/var/lib/v1/form-import/` listing the
missing concept names, and exits non-zero. Load the concept dictionary first
(see above) and the next run picks the form up.

# Daily backups of the v1 database

The installer schedules a nightly dump of the live `openmrs` database out of the
`openmrsdb` service. This is **not** the pre-upgrade backup in
`/var/lib/v1/bahmni-backup/openmrsdb_backup.sql` — that one is taken once, from
the 0.92 stack, and is what the restore reads. This is the rolling backup of the
site from the upgrade onwards.

| Path | What it is |
| --- | --- |
| `/usr/local/bin/eregister-db-backup.sh` | the backup script (run it by hand any time) |
| `eregister-db-backup.timer` or `/etc/cron.d/eregister-db-backup` | the **daily** schedule (01:30) |
| `/var/lib/v1/db-backups/openmrs_<stamp>.sql.gz` | the dumps, mode 0600 in a 0700 folder |
| `/var/lib/v1/db-backups/latest.sql.gz` | symlink to the newest one |
| `/var/log/eregister-db-backup.log` | every run |

One run:

1. `mysqldump --single-transaction` inside the `openmrsdb` container — a
   consistent snapshot that does not lock writers, so the site keeps working;
2. streams it out and gzips it host-side under a `.part` name;
3. checks the gzip integrity **and** that `mysqldump` wrote its `Dump completed`
   trailer;
4. only then moves it into place and repoints `latest.sql.gz`;
5. deletes all but the newest 14 dumps.

Step 3 is the point of the whole thing. A dump cut short by an OOM, a full disk
or a container restarting looks exactly like a good one until the day you try to
restore it. A truncated dump is never kept as a backup: it stays as a `.part`
file, the run is logged as a failure, and `catch-up.sh` reports it.

The password is never on the host's command line — it is passed to a shell
inside the container, and an unset one falls back to the container's own
`MYSQL_ROOT_PASSWORD`, which is what a stock v1 stack uses. Set
`EREGISTER_DB_PASS` only if yours differs; the script is then installed 0700
rather than 0755, because the password is baked into it.

```bash
sudo /usr/local/bin/eregister-db-backup.sh          # take one now
tail -f /var/log/eregister-db-backup.log            # watch it
systemctl list-timers eregister-db-backup.timer     # when it next fires
```

Restore one:

```bash
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
gzip -dc /var/lib/v1/db-backups/latest.sql.gz \
  | sudo docker compose exec -T openmrsdb mysql -uroot -p
```

The dump carries `CREATE DATABASE` / `USE`, so it recreates the database on its
own. Restart `openmrs` afterwards — it caches heavily.

Tune it with `--no-db-backup` (or `EREGISTER_DB_BACKUP=0`) to skip it entirely,
`EREGISTER_DB_BACKUP_CRON` (default `30 1 * * *`),
`EREGISTER_DB_BACKUP_ONCALENDAR` (default `*-*-* 01:30:00`),
`EREGISTER_DB_BACKUP_KEEP` (default `14`),
`EREGISTER_DB_BACKUP_DIR` (default `/var/lib/v1/db-backups`),
`EREGISTER_DB_BACKUP_COMPRESS=0` for plain `.sql`, and
`EREGISTER_DB_BACKUP_FIRST_RUN=0` to leave the first dump to the timer.

> [!WARNING]
> **These dumps are on the same disk as the database.** They undo a bad import
> or a deleted record; they do nothing for a dead disk or a lost server. Copy
> `/var/lib/v1/db-backups` off the host as well — `rsync`, a mounted volume, an
> object store, whatever the site already has.

> [!NOTE]
> Straight after an upgrade the immediate first dump often fails, because
> `openmrsdb` is not accepting connections yet. That is reported, not treated as
> an install failure — the nightly job takes the first dump instead.

# Keeping the v1 repos up to date

After a successful upgrade the installer offers to schedule a job that
periodically `git pull`s the asset/config repos — `standard-config-ls`,
`implementer-interface-release`, `openmrs-v1-modules`, `clinical-obs-forms`,
`dhisconnector_mappings_v1`, `eregister_concepts_release_v1` and
`openmrs_reporting_release` — so a deployed instance tracks their remotes
without a full re-run.

- On systemd hosts (Ubuntu default) it installs `eregister-autopull.timer` +
  `.service`; elsewhere it writes `/etc/cron.d/eregister-autopull`. Both run the
  same standalone updater at `/usr/local/bin/eregister-autopull.sh`.
- Each repo is fast-forwarded onto its tracked branch (`fetch --depth 1` +
  `reset --hard origin/<branch>`); a repo with uncommitted local changes is
  left untouched. `bahmni-docker-ls` and the 0.92 `bahmni_config` are **not**
  touched — they stay pinned to the deployed release.
- Run a one-off sync by hand: `sudo /usr/local/bin/eregister-autopull.sh`
  (log: `/var/log/eregister-autopull.log`).

> [!IMPORTANT]
> **Mixed clone ownership.** Depending on how each clone was made, the repos
> under `/var/lib/v1` end up owned by `root` or by the operator. Since git 2.35
> a repo whose owner is not the current user is refused outright —
> `fatal: detected dubious ownership in repository at '/var/lib/v1/…'` — so a
> root-run cron job silently stops updating a user-owned clone, and the log
> reads like a detached HEAD rather than a permissions problem. Every git call
> in these scripts now runs with `-c safe.directory='*'`, which relaxes that
> ownership check only (file permissions still apply), and the auto-pull log
> now says `git cannot read it — ownership or permissions` when git really is
> refusing. Check a site with:
>
> ```bash
> ls -ld /var/lib/v1/*/          # who owns each clone
> ```

You can configure the cronjob like so:

`sudo crontab -e`

`# Top of every hour (00:00, 01:00, 02:00 ...)`

`0 * * * * /usr/local/bin/eregister-autopull.sh >> /var/log/eregister-autopull.log 2>&1`

Remember to `sudo chmod +x /usr/local/bin/eregister-autopull.sh`


Tune or disable via env vars: `EREGISTER_AUTO_PULL=0` (off),
`EREGISTER_AUTO_PULL_ONCALENDAR` (systemd schedule, default `*-*-* 02:30:00`),
`EREGISTER_AUTO_PULL_CRON` (cron schedule, default `30 2 * * *`).

# Catching an early site up

`catch-up.sh` is the reconcile tool for sites that were installed before these
scripts grew their later steps. `install.sh` is the wrong tool for that job — it
freezes the old stack, restores a backup and restarts everything. Catch-up does
the opposite: it checks what is already there, fixes only the gaps, and reports.

```bash
curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/catch-up.sh | bash
```
(or, from the upgrade repo: `bash ./catch-up.sh`)

Everything it checks is read-only. Two steps write: the report definition
import (one table, backed up first, skipped when already current) and the EMR
reload, which is the only step that acts on a running container and comes last.
Both are confirmed before they run.

What it does, in order:

1. **Updates these scripts.** Inside a checkout it fast-forwards it; piped from
   `curl` it clones/updates `/var/lib/v1/upgrade-to-v1`. Either way it re-runs
   itself once from the fresh copy, so the checks that follow are the current
   ones. A checkout with local changes is left alone.
2. **Checks and updates every dependency repo**, cloning any a site never got:

   | Repo | Pinned ref | Notes |
   | --- | --- | --- |
   | `clinical-obs-forms` | `main` | the forms the daily import deploys |
   | `eregister_concepts_release_v1` | `main` | the concept dictionary dump |
   | `openmrs_reporting_release` | `master` | the report definitions dump |
   | `implementer-interface-release` | `main` | |
   | `standard-config-ls` | `Bokang-changes` | |
   | `bahmni-docker-ls` | `Bokang-changes` | the stack; disk only — see below |
   | `dhisconnector_mappings_v1` | `master` | |
   | `openmrs-v1-modules` | `main` | ~246 MB on first clone |
   | `upgrade-to-v1` | `main` | the site's own checkout of these scripts |
   | `bahmni_config` (0.92) | `main` | restore-only; checked, never updated |

   Each is fast-forwarded onto its pinned ref. A repo is **reported and left
   untouched** — never reset — when it has uncommitted local changes, sits on a
   detached HEAD, or tracks a different branch than the release pins; the row
   says which, and `--force-repos` brings it back on-release (discarding those
   changes). A clone pointing at a different remote is flagged, and re-pointed
   only when it is otherwise on-release. `bahmni-docker-ls` is updated on disk
   only; the report says it needs a `docker compose up -d` at your next
   maintenance window (`--no-stack` skips it entirely).

   `upgrade-to-v1` gets a row of its own in addition to the self-update in step
   1, so the site's `/var/lib/v1/upgrade-to-v1` checkout is kept current even
   when you ran the script from a clone somewhere else.
3. **Reinstalls the generated helpers** — `eregister-autopull.sh`,
   `eregister-db-backup.sh`, `bahmni-form-import.sh`, `eregister-form-import.sh`
   — from the release that was just pulled. An existing
   `/etc/eregister/form-import.env` is never overwritten; a missing one is
   written after prompting for the password.
4. **Checks all four scheduled jobs** (`eregister-db-backup`,
   `eregister-autopull`, `eregister-form-import`, `eregister-concept-import`)
   and installs whichever is absent, as a systemd timer or an `/etc/cron.d`
   entry. Hosts with neither get the exact cron line to add by hand. This is how
   a site installed before the backup job existed gets one.
5. **Runs the clinical form import** — only forms whose content changed are
   deployed, so on a current site this is a no-op.
6. **Reports on the concept dictionary** — which dump is on disk, whether it is
   the one actually imported (comparing its sha256 against the import marker),
   and the live `concept` row count. Catch-up never imports it itself: that
   replaces the `concept_*`/`drug*` tables, which is the daily concept job's
   business, or yours via `./import-concepts.sh`. The severity of the
   `imported` row follows from that — a newer dump **with** the job scheduled is
   `OK` (pending tonight); the same dump with **no** job scheduled is a `GAP`,
   because then nothing will ever load it.
7. **Imports the OpenMRS report definitions** from `openmrs_reporting_release`
   into the `openmrs` database — see
   [Importing the OpenMRS report definitions](#importing-the-openmrs-report-definitions).
   Unlike the dictionary above this one *is* imported here: it replaces a single
   table (`serialized_object`), backs that table up first, and does nothing at
   all when the dump in the clone is already the one in the database. Skip with
   `--no-reporting`.
8. **Reports on the database backups** — how many dumps there are and how old
   the newest one is. The schedule row above only says a timer exists; this row
   says it is producing files, which is the question that matters. A newest dump
   over 36h old is a `GAP`, as is any leftover `.part` file. Silence with
   `--no-db-backup`.
9. **Reports service health** — `docker compose ps` per service plus HTTP
   probes of the OpenMRS REST API and the Bahmni UI. This is the site **as
   found**, probed before the reload below.
10. **Reloads the EMR**, last, so everything refreshed above is actually picked
    up:

    ```bash
    docker compose up -d --force-recreate --renew-anon-volumes openmrs
    ```

    A long-running `openmrs` container keeps serving the config it read at boot,
    and content seeded into its **anonymous** volumes survives a plain restart —
    so `--force-recreate` replaces the container and `--renew-anon-volumes`
    throws those volumes away to be re-seeded. The EMR is then down for its usual
    30+ minute boot. Named volumes and the `openmrsdb` service (patient data) are
    untouched, but anything hand-placed *inside* the running EMR container rather
    than in its config repo is gone. Skip with `--no-recreate` /
    `EREGISTER_CATCHUP_RECREATE=0`; change the service with
    `EREGISTER_EMR_SERVICE`.

Then it prints one table:

```text
  ⟳ FIXED self      upgrade-to-v1                    a1b2c3d -> e4f5g6h
  — SKIP  repo      bahmni-docker-ls                 uncommitted local changes — left untouched
  ⟳ FIXED repo      clinical-obs-forms               main 4ad5c52 -> e3b2e34
  ✔ OK    repo      standard-config-ls               current (main @ 0f2d92c)
  ⟳ FIXED script    eregister-form-import.sh         was missing — installed
  ⟳ FIXED cron      eregister-form-import            installed — systemd timer active, next: Tue 03:30
  ✔ OK    forms     import                           imported 0/12 form(s), 12 unchanged, 0 failed
  ✔ OK    concepts  imported                         newer dump pending — daily job loads it (30 4 * * *); in the DB now: omrs_concept_dictionary_20260804.sql from 2026-06-14T09:12:03Z
  ✔ OK    concepts  database                         openmrs.concept holds 412345 rows
  ⟳ FIXED reporting definitions                      Serialized_Object.sql imported — serialized_object holds 3402 rows
  ✔ OK    backup    dumps                            14 kept (limit 14); newest openmrs_20260901_013012.sql.gz 284M, 9h old
  ✘ GAP   service   reports                          exited — Exited (1) 2 hours ago
  ✔ OK    endpoint  openmrs REST                     https://localhost/openmrs — HTTP 200
  ⟳ FIXED reload    openmrs                          recreated with renewed anonymous volumes — booting now
```

`OK` = already current · `FIXED` = redone by this run · `SKIP` = deliberately
left alone · `GAP` = needs a human. The exit status is `0` only when there are
no `GAP` rows, so it can be wired into monitoring:

```bash
30 6 * * 1 /var/lib/v1/upgrade-to-v1/catch-up.sh --yes --no-forms --no-recreate >> /var/log/eregister-catchup.log 2>&1
```

Flags: `--yes`, `--no-recreate`, `--force-repos`, `--no-stack`, `--no-forms`,
`--no-concepts` (leave the dictionary alone entirely — no DB probe, and the
daily concept job is neither installed nor refreshed), `--no-reporting` (clone
and fast-forward `openmrs_reporting_release`, but do not import it),
`--no-db-backup` (leave
the nightly database backup alone — neither installed, refreshed, nor reported
on), `--install-dir DIR`,
`--no-color`. Env: `EREGISTER_BAHMNI_PASS` (needed
for `--yes` if the credentials file is missing), `EREGISTER_UPGRADE_REPO`,
`EREGISTER_UPGRADE_REF`, `EREGISTER_CATCHUP_STACK_REPO=0`,
`EREGISTER_CATCHUP_DB_CHECK=0`, `EREGISTER_CATCHUP_HTTP_TIMEOUT`,
`EREGISTER_CATCHUP_RECREATE=0`, `EREGISTER_CATCHUP_FORCE_REPOS=1`,
`EREGISTER_DB_BACKUP=0`, `EREGISTER_DB_BACKUP_CRON`, `EREGISTER_DB_BACKUP_KEEP`,
`EREGISTER_EMR_SERVICE`, `EREGISTER_CONCEPT_IMPORT=0`,
`EREGISTER_IMPORT_REPORTING=0`, `EREGISTER_REPORTING_SQL_NAME`,
`EREGISTER_REF_REPORTING`.

> [!WARNING]
> The monitoring/cron use above should carry `--no-recreate`. Left on, every
> scheduled run would recreate the EMR and take it down for half an hour.

# Troubleshooting: `curl: (56) The requested URL returned error: 404`

That is the one-liners failing to fetch their own modules. It is a **404 on a
raw.githubusercontent.com URL** — curl reports it as exit `56` rather than the
usual `22` because of an HTTP/2 quirk, and the old message named neither the
file nor the reason.

The scripts now handle this properly. They fetch modules by shallow-cloning the
repo first (which resolves the remote's default branch by itself) and fall back
to per-file downloads, they accept the tree only once **every** required module
is present, and they print which URL returned what:

```text
FATAL: could not obtain the eRegister modules (lib/).
Tried:
  • git clone https://github.com/…/upgrade-to-v1 (default branch) -> cloned OK, but lib/upgrade/catchup.sh is not on that branch
  • https://raw.githubusercontent.com/…/refs/heads/main/lib/upgrade/catchup.sh -> HTTP 404
```

**In almost every case the cause is the first one: the file is not pushed yet.**
A one-liner fetches from the branch, not from your laptop, so a module added
locally 404s for every site until it is pushed. The other two causes are a
just-pushed file still stale in the raw CDN (a few minutes), and a branch that
does not exist or a repo that is private — raw answers `404`, not `401`, for
private repos.

Check it before a site does — run this after any push that adds or renames a
file under `lib/` or `bin/`:

```bash
./tests/check-published.sh          # or: ./tests/check-published.sh <branch>
```

It probes every module each entry script lists, plus `bin/bahmni_form_import.sh`,
and flags anything uncommitted or unpushed in your checkout. Exit `0` means the
one-liners work right now.

Workarounds while a fix is being pushed:

```bash
# run from a checkout — nothing is fetched at all
git clone https://github.com/Lesotho-eRegister-v1/upgrade-to-v1
cd upgrade-to-v1 && ./install.sh

# or point the scripts at a branch that does have the modules
EREGISTER_RAW_REFS=my-branch ./install.sh
EREGISTER_RAW_BASE=<raw url> EREGISTER_RAW_BASE_PINNED=1 ./install.sh
```

# Checklist
    - working superman password. ✅
    - login locations are loading correctly ✅
    - able to search for your patients / clients ✅
    - LabonFHIR 1.3.1 ✅
    - FHIR2 1.9.0 ✅
    - DHIS-Connector ✅
