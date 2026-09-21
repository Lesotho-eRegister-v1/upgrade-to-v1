# 7. Database backups

There are **two** different backups in this toolkit, and confusing them is the
easiest way to lose data.

| | The pre-upgrade dump | The rolling nightly backup |
|---|---|---|
| Taken | **Once**, by `install.sh`, from the 0.92 stack | **Every night** at 01:30, from the live v1 stack |
| Lives in | `<base>/v1/bahmni-backup/openmrsdb_backup.sql` | `<base>/v1/db-backups/openmrs_<stamp>.sql.gz` |
| Read by | `restore_bahmni_standard.sh` during the upgrade | You, by hand |
| Retention | Kept forever | Newest 14 |
| Purpose | The 0.92 data the upgrade migrates | Undo a bad import or a deleted record |

> **`install.sh --force` reloads the database from the pre-upgrade dump**,
> replacing anything entered since it was made. On a site that has been live on
> v1 for a while, that is data loss.

## 7.1 The nightly backup

Installed by `install.sh` (first, before anything else that writes to the
database on a schedule) and checked by every `catch-up.sh` run.

```bash
sudo /usr/local/bin/eregister-db-backup.sh    # run it now
```

### What one run does

1. `mysqldump` the whole `openmrs` database inside the `openmrsdb` container,
   with `--single-transaction` — a consistent snapshot without locking writers
2. Stream it out, gzip it host-side, write it under a `.part` name
3. Check **both** the gzip integrity **and** that mysqldump wrote its
   `Dump completed` trailer
4. Only then move it into place and repoint `latest.sql.gz`
5. Delete all but the newest `EREGISTER_DB_BACKUP_KEEP` dumps

> Step 3 is the one that matters. A dump cut short by an OOM or a restarting
> container is otherwise a perfectly plausible-looking file that restores half a
> site — and looks exactly like a good one until the day you need it.

### Why 01:30

Before the auto-pull (02:30), the form import (03:30) and the concept import
(04:30), so each night's dump is of the database as it was **before** anything
scheduled touched it.

### The script is standalone on purpose

cron and systemd run it in a bare environment, so it carries its own logger,
resolves docker compose itself, and depends on nothing under `lib/`.

Mode `0755` normally. When `EREGISTER_DB_PASS` was set, the password is baked
into the file and it goes in `0700` instead — the usual case bakes nothing,
because the v1 database's root password is the container's own
`MYSQL_ROOT_PASSWORD` and the script reads it there.

## 7.2 What catch-up checks

Two separate questions, two separate rows:

```
  ✔ OK   cron    eregister-db-backup   systemd timer active (next: Mon 01:30)
  ✘ GAP  backup  newest dump           newest dump is 51h old — the nightly job is not producing files
```

The first says a timer **exists**. The second says the timer is **producing
files**, which is the question that matters: a backup job whose `openmrsdb`
service has been unreachable since a compose rename fails silently every night,
and the only visible symptom is that the newest dump stops moving.

A newest dump over **36h** old is a `GAP`. So is any leftover `.part` file — that
is a run that was interrupted mid-write.

`--no-db-backup` silences both rows and leaves the job alone.

## 7.3 Restoring

```bash
gzip -dc /var/lib/v1/db-backups/latest.sql.gz \
  | ( cd /var/lib/v1/bahmni-docker-ls/bahmni-standard \
      && sudo docker compose exec -T openmrsdb mysql -uroot -p )
```

The dump carries `CREATE DATABASE` / `USE`, so no database name is needed on the
command line.

### Verifying a dump before you trust it

```bash
# integrity of the gzip stream
gzip -t /var/lib/v1/db-backups/openmrs_20260921_013001.sql.gz && echo "gzip OK"

# did mysqldump actually finish?
gzip -dc /var/lib/v1/db-backups/openmrs_20260921_013001.sql.gz | tail -n 3
# -> should end with: -- Dump completed on 2026-09-21  1:34:12
```

## 7.4 These dumps do not protect you from losing the machine

They sit on the **same disk as the database**. They protect against a bad
import or a deleted record, not against a failed disk or a lost host.

**Copy `<base>/v1/db-backups` off the host as well.** Nothing in this toolkit
does that for you.

## 7.5 Configuration summary

| Variable | Default | Meaning |
|---|---|---|
| `EREGISTER_DB_BACKUP` | `1` | `0` (or `--no-db-backup`) does not install it |
| `EREGISTER_DB_BACKUP_CRON` | `30 1 * * *` | cron schedule |
| `EREGISTER_DB_BACKUP_ONCALENDAR` | `*-*-* 01:30:00` | systemd schedule |
| `EREGISTER_DB_BACKUP_KEEP` | `14` | How many dumps to retain |
| `EREGISTER_DB_BACKUP_DIR` | `<base>/v1/db-backups` | Where they go (mode `0700`) |
| `EREGISTER_DB_BACKUP_LOG` | `/var/log/eregister-db-backup.log` | The log |
