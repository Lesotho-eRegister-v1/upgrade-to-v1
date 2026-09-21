# 2. The upgrade: `install.sh`

`install.sh` works as both a fresh installer and an in-place upgrader from
0.92 to v1. It is the only script in the toolkit that stops the old stack and
restores a database.

> [!WARNING]
> Run it **once** per site. To pick up later changes to these scripts on a site
> that is already on v1, run `catch-up.sh` — see [chapter 3](03-catch-up.md).

## 2.1 Usage

```bash
./install.sh [--yes] [--force] [--install-dir DIR] [--target-ref REF[,REF...]]
             [--no-concepts] [--no-db-backup] [--no-color] [--help]
```

| Flag | Meaning |
|---|---|
| `-y`, `--yes` | Non-interactive; assume yes at every prompt. Also `EREGISTER_ASSUME_YES=1` |
| `--force` | Redo the whole upgrade even when the marker says it finished |
| `--install-dir DIR` | Install base (default `/var/lib`) |
| `--target-ref REF[,REF...]` | Git ref preference list, tried against every repo — see §1.4 |
| `--no-concepts` | Do not install the concept-dictionary job at all |
| `--no-db-backup` | Do not install the daily database backup. The site is then left with **no routine backup** |
| `--no-forms` | Accepted but **inert here** — this script no longer touches forms |
| `--no-color` | Disable ANSI colours |

## 2.2 What one run does, in order

```
main()
 ├─ load_modules            source lib/ (or fetch it — see §1.2)
 ├─ parse_args / banner
 ├─ detect_platform         OS, arch
 ├─ detect_pkg_mgr          apt-get, yum, …
 ├─ resolve_config          finalise every <base>-derived path
 ├─ detect_privilege        root, or sudo
 ├─ print_config            the "Resolved configuration" block
 ├─ resolve_install_stage   the idempotency guard (§2.6)
 ├─ run_migration           ← the upgrade proper
 ├─ run_post_install        ← the scheduled jobs
 ├─ mark_stage complete
 └─ next_steps
```

### `run_migration` — the upgrade proper

| # | Step | Notes |
|---|---|---|
| 1 | **Go/no-go** | `Begin the upgrade 0.92 -> v1?` Every step below is *also* confirmed individually |
| 2 | **Dependencies** | Check for, and install if missing: git, docker, … |
| 3 | **Workspace and folders** | `mktemp -d` plus `<base>/v1` and `<base>/v1/bahmni-backup` |
| 4 | **Backup** | Dump `openmrs` out of the running 0.92 EMR container |
| 5 | **Freeze the old stack** | `docker compose stop` — **rollback is armed from here** |
| 6 | **Fetch repos** | Clone/update every v1 repo plus the 0.92 config |
| 7 | **Restore** | `restore_bahmni_standard.sh <backup dir>` |
| 8 | **Start v1** | `run-bahmni.sh`, falling back to `docker compose up -d` |
| 9 | **Verify and mark** | Post-install checks, then `stage=migrated` |

### `run_post_install` — the long tail

Every step here is **advisory**: the migration is already finalised, so a
failure warns and names the standalone script that redoes it. None of them can
abort the run or trigger a rollback.

| # | Step | Notes |
|---|---|---|
| 1 | **Daily database backup** | First, deliberately — see below |
| 2 | **Concept-dictionary job** | Installed with one delayed first run, ~3h out |
| 3 | *(clinical forms)* | **Deliberately absent** — see §2.5 |
| 4 | **Auto-pull job** | Offered, then installed |

> [!NOTE]
> The database backup is installed **first** on purpose. Everything else in this
> function installs something that will later write to the `openmrs` database on
> a schedule — the concept dictionary replaces whole tables, the form import
> creates form versions. The job that lets a site undo any of that should be in
> place before those jobs are, not after.

## 2.3 The backup

This is the dump the restore reads. It is taken **before anything is changed**,
directly out of the running 0.92 EMR container:

```bash
docker exec -e "MYSQL_PWD=<password>" <emr-container> \
  mysqldump --single-transaction --routines --triggers --events \
            --hex-blob --default-character-set=utf8mb4 \
            --databases -u root openmrs \
  > /var/lib/v1/bahmni-backup/openmrsdb_backup.sql
```

Each flag earns its place:

| Flag | Why |
|---|---|
| `--single-transaction` | Consistent InnoDB snapshot without locking writers |
| `--routines` | Stored procedures and functions |
| `--triggers` | Table triggers |
| `--events` | Scheduled events |
| `--databases` | Emits `CREATE DATABASE` / `USE`, so the DB is recreated |
| `--hex-blob` | Binary-safe encoding of BLOB/BINARY columns |
| `--default-character-set=utf8mb4` | No truncation or corruption of unicode text |

`MYSQL_PWD` keeps the password off the container's process list.

### Finding the EMR container

The configured name is tried first, then a known alternate, each matched with
hyphen and underscore treated as interchangeable — so compose v1
(`bahmni_docker_emr_service_1`), compose v2 (`bahmni_docker-emr-service-1`) and
mixed variants all resolve to the same configured name.

If neither is running, you are asked for the name, **in a loop**: a mistyped
name used to cost the pre-upgrade backup outright. A blank line still means
"skip", and a name that does not resolve gets a second chance plus a listing of
the running containers to copy from.

### An existing dump always wins

A dump already sitting in `bahmni-backup` is **reused, not retaken**. It is the
0.92 data the restore needs, and once an earlier run has frozen the old stack it
cannot be retaken at all.

```
[✔] Reusing the backup already in /var/lib/v1/bahmni-backup:
[✔]   /var/lib/v1/bahmni-backup/openmrsdb_backup.sql (299M)
[ℹ] The restore below loads THIS file. To retake it instead, re-run with
    --force while the 0.92 EMR container is running.
```

> [!CAUTION]
> **`--force` reloads the database from that file, replacing anything entered
> since it was made.** On a site that has been live on v1 for a while, that is
> data loss. This is why `catch-up.sh` exists.

### No old container at all

If nothing is running and no dump exists, the run continues as a **fresh
install** with nothing to migrate. Downstream steps notice: the restore is still
attempted but never fatal, and every post-install check is demoted from an error
to a warning.

## 2.4 Freeze, not destroy

```bash
cd ~/bahmni_docker && docker compose stop
```

`stop`, not `down`. The containers are halted but **not removed**, so volumes
and networks stay intact and a rollback is a fast `start` with no re-create.

### Rollback

From the freeze onwards, an error trap is armed. If the run fails or is aborted
before the migration is finalised:

```
[⚠] Upgrade failed — initiating rollback to eRegister Lesotho 0.92.
[ℹ] Restarting the frozen old stack (/home/kgatman/bahmni_docker)…
[✔] Old stack restarted.
[⚠] Your database backup is preserved at: /var/lib/v1/bahmni-backup/openmrsdb_backup.sql
[✘] Rollback complete. The v1 upgrade was NOT applied.
```

The backup is always preserved. Rollback disarms once `post_verify` succeeds.

## 2.5 What `install.sh` deliberately does **not** do

Three imports are cloned but not performed here. The reason is the same in each
case, and it is worth understanding because it shapes the whole toolkit:

> [!IMPORTANT]
> **When `install.sh` finishes, the stack has only just been started.**
> `openmrsdb` answers early, but the OpenMRS instance behind it needs 30+
> minutes — hours on site hardware — before it is usable.

| Not done here | Why | Who does it |
|---|---|---|
| **Concept dictionary** | The import replaces the `concept_*`/`drug*` tables. Asking an operator to authorise that at the least informative possible moment helps nobody | A delayed first run ~3h out, then the daily job. Or `./import-concepts.sh` |
| **Clinical forms** | They deploy over the EMR's **REST API**, which is not answering yet. An import here either blocks the operator for the whole boot or fails for nothing | `./catch-up.sh` or `./import-forms.sh` — **nowhere else** |
| **Report definitions** | Same reason as the dictionary: the database is minutes old | `./catch-up.sh` |

For the forms this is absolute: `install.sh` installs **no** form importer, **no**
credentials file and **no** timer. Until `catch-up.sh` or `import-forms.sh` has
been run, nothing on the host is importing forms.

## 2.6 Re-running after an interruption

`<base>/v1/.eregister-upgrade-complete` records **how far** the last run got, not
merely that one happened:

| Marker | Meaning | A re-run will… |
|---|---|---|
| *(absent)* | Nothing has run | Do the whole upgrade |
| `stage=migrated` | Stack migrated, verified and started, but the post-install steps did not finish | **Redo the upgrade from the top**, reusing the existing backup, then finish the outstanding steps |
| `stage=complete` | The whole run finished | Short-circuit: "already installed, nothing to do" |

This distinction is the whole point of the file. The post-install steps load a
multi-hundred-MB dump and talk to an EMR that takes 30+ minutes to boot, so they
are easy to interrupt with a Ctrl-C or a dropped ssh session. When the marker was
a bare `touch` taken at verification time, an interrupt anywhere in that window
left behind a marker saying "installed" — and every later run short-circuited on
it, printing a summary of work it had not done.

A marker written by an older installer carries no stage. What is still
outstanding is then inferred from what those steps leave on disk (the
concept-import runner, or its state file).

### `stage=complete`

```
[✔] eRegister Lesotho v1 is already installed (/var/lib/v1/.eregister-upgrade-complete).
    Nothing to do.
[ℹ] To pick up later changes to these scripts on a live site, run ./catch-up.sh.
[ℹ] To redo the whole upgrade from the backup in /var/lib/v1/bahmni-backup,
    re-run with --force.
```

### `stage=migrated`

```
[⚠] A previous run migrated the stack but stopped before the post-install
[⚠] steps finished (/var/lib/v1/.eregister-upgrade-complete records stage=migrated).
[⚠] This run redoes the upgrade from the top. The backup already in
[⚠] /var/lib/v1/bahmni-backup is REUSED, not retaken — and the restore reloads
[⚠] 'openmrs' from it, replacing anything entered since it was made.
```

## 2.7 Post-install verification

Before recording `stage=migrated`, four things are checked:

```
[ -s <base>/v1/bahmni-backup/openmrsdb_backup.sql ]   the dump exists and is non-empty
[ -d <base>/v1/bahmni-docker-ls/.git ]                the stack repo is a checkout
[ -d <base>/v1/standard-config-ls/.git ]              the config repo is a checkout
[ -d <base>/v1/bahmni-backup/bahmni_config/.git ]     the 0.92 config is a checkout
```

On a fresh install (no backup taken), each of these is demoted to a warning so
the upgrade can still finalise.

## 2.8 Worked example

A full upgrade on a host that already holds a 0.92 dump:

```bash
curl -fsSL --retry 8 --retry-max-time 180 \
  https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/install.sh | bash
```

```text
lib/ not found locally — fetching the modules …
Modules obtained by cloning https://github.com/Lesotho-eRegister-v1/upgrade-to-v1.

  ┌────────────────────────────────────────────────────────────┐
  │     ███  eRegister Lesotho — Upgrade to v1                 │
  │     ⏳  Initializing migration…………                         │
  │     🔍  Checking prerequisites…….                          │
  │     ✨  Doing the magic………                                 │
  └────────────────────────────────────────────────────────────┘

[ℹ] Elevation required for /var/lib; will use sudo.

==> Resolved configuration
  App            : eRegister Lesotho
  Current ver    : none
  Target ver     : v1
  Ref override   : (none — using the per-repo defaults below)
  Default refs   : docker=Bokang-changes  config=Bokang-changes  092=main
  OS / Arch      : linux / amd64
  Pkg manager    : apt-get
  Install base   : /var/lib
  v1 dir         : /var/lib/v1
  Concept dict   : /var/lib/v1/eregister_concepts_release_v1/omrs_concept_dictionary*.sql (newest) -> openmrsdb:openmrs
  Concept job    : first run ~3h after install, then daily 30 4 * * *
  Report defs    : /var/lib/v1/openmrs_reporting_release (cloned here; imported by ./catch-up.sh)
  Clinical forms : /var/lib/v1/clinical-obs-forms (cloned here; imported by ./catch-up.sh)
  DB backup      : openmrsdb:openmrs -> /var/lib/v1/db-backups (daily: 30 1 * * *, keep 14)
  Old stack      : /home/kgatman/bahmni_docker
  EMR container  : bahmni_docker-emr-service-1
  Privilege      : sudo
  Non-interactive: no

[⚠] Cautious mode: you will be asked to confirm EVERY step before it runs.
Begin the upgrade 0.92 -> v1? [y/N]: y
Next step: Check for, and install if missing, required dependencies (git, docker, …) — proceed? [y/N]: y
[✔] All dependencies present.
...
```

### Unattended

```bash
sudo EREGISTER_DB_PASS='<0.92 db password>' ./install.sh --yes
```

### Pinning every repo to one release

```bash
sudo ./install.sh --yes --target-ref v1.4.0,Bokang-changes,main
```

### Installing somewhere other than `/var/lib`

```bash
sudo ./install.sh --install-dir /srv
# everything then lives under /srv/v1
```

## 2.9 Immediately after the upgrade

The stack is up but the EMR is still booting. In order:

1. **Wait 30+ minutes.** Hours on site hardware. Nothing below works until the
   EMR answers.
2. **Run `ocl-fix.sh`** once the OCL import has finished — see
   [chapter 5](05-concepts.md#54-the-ocl-concept-name-fix).
3. **Run `catch-up.sh`.** This is what deploys the clinical forms and the report
   definitions. Until it has run, neither is on the site.
