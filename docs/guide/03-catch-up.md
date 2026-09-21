# 3. Reconciling a live site: `catch-up.sh`

`catch-up.sh` re-checks everything `install.sh` is meant to have set up, and
redoes **only** what is missing or out of date.

It exists because sites installed from an earlier version of these scripts never
got the steps added since — and re-running `install.sh` on them is the wrong
tool, because that freezes the stack, restores a backup and restarts everything.

It also **owns** two steps outright: the clinical form import and the report
definition import happen here and nowhere else.

The run ends with a single table: what was already OK, what it redid, what it
deliberately left alone, and what still needs a human. **Exit status is `0` only
when there are no gaps**, so it doubles as a monitoring check.

## 3.1 Usage

```bash
./catch-up.sh [--decode]
./catch-up.sh [--yes] [--no-stack] [--no-forms] [--no-retire-forms]
              [--no-publish] [--no-decode] [--no-concepts] [--no-reporting]
              [--no-idgen] [--no-db-backup] [--no-compose-up] [--pull-images]
              [--no-recreate] [--force-repos]
              [--install-dir DIR] [--no-color] [--help]
```

| Flag | Effect |
|---|---|
| `-y`, `--yes` | Non-interactive; assume yes at every prompt |
| `--decode` / `--decode-only` | **Run only the form-JSON decode, then stop.** No repo updated, nothing imported, no health probe, EMR left running. Seconds instead of the usual run |
| `--no-stack` | Do not fast-forward `bahmni-docker-ls` |
| `--no-forms` | Leave the form import and its schedule alone. Implies `--no-decode`, `--no-retire-forms` and `--no-publish` |
| `--no-retire-forms` | Import the new forms but leave the ones they replace live |
| `--no-publish` | Leave the deployed forms in Draft — they are then not offered in the clinical app |
| `--no-decode` | Import the forms but leave the HTML entities in what the EMR wrote |
| `--no-concepts` | Leave the dictionary alone: no DB probe, and the daily job is neither installed nor refreshed |
| `--no-reporting` | Clone and fast-forward the reporting repo, but do not import it |
| `--no-idgen` | Do not retire the disused identifier source |
| `--no-db-backup` | Leave the nightly backup alone — not installed, refreshed or reported on |
| `--no-compose-up` | Do not apply the compose files to the stack |
| `--pull-images` | Add `--pull always` when applying them |
| `--no-recreate` | Do **not** recreate the EMR service at the end |
| `--force-repos` | Bring off-release repos back onto their pinned ref, **discarding** local changes |
| `--install-dir DIR` | Install base (default `/var/lib`) |

> `--decode` and `--no-decode` contradict each other. Passing both is an error,
> because picking one silently would leave you working out why your run did
> nothing.

## 3.2 Phase 1 — the self-update

Before any module is sourced, `catch-up.sh` updates **itself**, so a site always
reconciles against the latest version of these scripts. This phase may use only
shell built-ins, git and curl.

Two cases:

- **Running from a git checkout** — fast-forward it in place. A checkout with
  uncommitted local changes is never discarded; it is reported and left alone.
- **Piped from curl, or a stray copy** — clone or update the managed checkout at
  `<base>/v1/upgrade-to-v1` and re-exec from there.

Either way it `exec`s the up-to-date `catch-up.sh` exactly once, guarded by
`EREGISTER_CATCHUP_REEXEC`, so the rest of the run uses the new modules. The
outcome is handed to phase 2 in the environment and becomes the first row of the
report:

```
  ⟳ FIXED self      upgrade-to-v1    a1b2c3d -> e4f5a6b (/var/lib/v1/upgrade-to-v1)
```

If git is missing, or the clone fails, the run continues with the copy that is
running and records a `GAP`.

## 3.3 Phase 2 — the reconcile, step by step

```
catch_up()
 ├─  1. catchup_repos            dependency repos
 ├─  2. catchup_helper_scripts   generated helpers
 ├─  3. catchup_schedules        the four scheduled jobs
 ├─  4. catchup_forms            retire → import → decode
 ├─  5. catchup_concepts         REPORT ONLY
 ├─  6. catchup_reporting        report definitions (imported here)
 ├─  7. catchup_idgen            retire the disused identifier source
 ├─  8. catchup_db_backups       REPORT ONLY
 ├─  9. catchup_services         health, as found
 ├─ 10. catchup_stack_up         docker compose up -d
 ├─ 11. catchup_recreate_emr     reload the EMR
 └─ 12. catchup_report           the table + verdict
```

### Step 1 — Dependency repos

Every repo the installer clones is fast-forwarded onto its pinned ref, plus the
site's own `upgrade-to-v1` checkout. Each gets a report row.

Repos are classified, and the class decides the behaviour:

| Class | Repos | Behaviour |
|---|---|---|
| `asset` | `standard-config-ls`, `openmrs-v1-modules`, `implementer-interface-release`, `clinical-obs-forms`, `dhisconnector_mappings_v1`, `eregister_concepts_release_v1`, `openmrs_reporting_release` | Always fast-forwarded |
| `stack` | `bahmni-docker-ls` | Fast-forwarded unless `--no-stack`; applied by step 10 |
| `pinned` | `bahmni_config` (0.92) | Checked for presence, never updated |
| `self` | `upgrade-to-v1` | The site's managed checkout, kept current even when you ran the script from a clone elsewhere |

**A repo is reported and left completely alone — never reset — when it:**

- has uncommitted local changes, or
- sits on a detached HEAD, or
- tracks a branch other than the one this release pins.

```
  — SKIP  repo      standard-config-ls   uncommitted local changes — left untouched; --force-repos to reset it onto Bokang-changes
```

Sites do hand-edit config, and silently discarding that would be the one
destructive thing this script could plausibly do. `--force-repos` opts in.

A clone pointing at a different remote than the release configures is flagged in
the row, and re-pointed **only** once it is otherwise on-release — re-pointing a
repo that is also off-ref would leave it tracking a branch its new origin may
not even have.

### Step 2 — Generated helper scripts

`eregister-autopull.sh`, `eregister-db-backup.sh`, `bahmni-form-import.sh`,
`eregister-form-import.sh` are rewritten from the release that was just pulled.
They are generated files, so rewriting unconditionally is how a site picks up
fixes to them, and keeps the result identical to a fresh install.

This is also where the form importer is **installed** rather than merely
refreshed: `install.sh` does no form work at all, so on a site that has never run
catch-up none of those three exist yet.

The EMR password in `/etc/eregister/form-import.env` is tested against the EMR:

- a working one is left alone,
- a missing or **rejected** one is replaced after prompting (and checked against
  the EMR before it is saved),
- while the EMR is still booting nothing can be checked, so an existing file is
  kept as-is and checked again just before the import runs.

### Step 3 — The scheduled jobs

All four jobs (`eregister-db-backup`, `eregister-autopull`,
`eregister-form-import`, `eregister-concept-import`) are checked, and whichever
is absent is installed — as a systemd timer, or an `/etc/cron.d` entry where
systemd is missing. Hosts with neither get the exact cron line to add by hand.

This is how a site installed before the backup job existed gets one.

### Step 4 — Clinical observation forms

Three parts, each with its own report row. Covered in full in
[chapter 4](04-forms.md):

1. **Retire** the forms this release replaces (`--no-retire-forms` skips)
2. **Import** the forms whose content changed, and **publish** them
   (`--no-forms` skips the import, `--no-publish` skips just the publishing)
3. **Decode** the HTML entities in the JSON the EMR wrote (`--no-decode` skips)

Publishing is what makes a deployed form actually appear in the clinical app —
the Implementer Interface's Import button leaves it in Draft. It re-asserts on
every run, so forms that were deployed as drafts before this existed are
published by the next ordinary catch-up.

The decode is deliberately **not** conditional on the import: what is being
decoded is JSON the EMR already holds, so a run that deployed nothing can still
face a folder full of `&amp;lt;` from an earlier release.

### Step 5 — Concept dictionary (report only)

Catch-up **never** imports the dictionary. That replaces the `concept_*`/`drug*`
tables, which is the daily concept job's business — or yours via
`./import-concepts.sh`.

It reports which dump is on disk, whether it is the one actually imported
(comparing sha256 against the import marker), and the live `concept` row count.
The severity follows from that:

- a newer dump **with** the job scheduled → `OK` (pending tonight)
- the same dump with **no** job scheduled → `GAP`, because then nothing will ever
  load it

### Step 6 — OpenMRS report definitions

Unlike the dictionary, this one **is** imported here. See
[chapter 6](06-reporting.md). It replaces a single table (`serialized_object`),
backs that table up first, and does nothing at all when the dump in the clone is
already the one in the database.

### Step 7 — The disused identifier source

Marks one row of `idgen_identifier_source` retired in the `openmrs` database, so
it stops being offered for new identifiers:

```sql
UPDATE idgen_identifier_source
SET retired = 1, retired_by = 1, date_retired = NOW(),
    retire_reason = 'No longer in use'
WHERE id = 14 AND retired = 0;
```

The row stays, and so does every identifier it has already issued. The run prints
the single statement that undoes it.

`AND retired = 0` matters: without it every run rewrites `date_retired` on a row
retired months ago, so the site loses the date it was actually retired and the
report claims a change it did not make. With it, the second and every later run
match zero rows and the step is a true no-op — **the database is its own state
file.**

The flip side is deliberate: this **re-asserts**. An operator who un-retires that
source by hand will find the next catch-up retiring it again. Pass `--no-idgen`
on a site where it is wanted.

Ids are per-site auto-increments, so the step reads the row first and the report
names what it retired. An id that is not there is a `GAP`, not a quiet pass:

```
  ✘ GAP   idgen     source 14        no source with id 14 in openmrs — nothing retired (set EREGISTER_IDGEN_RETIRE_ID, or --no-idgen)
```

### Step 8 — Database backups (report only)

Step 3 says a timer *exists*. This row says the timer is *producing files*, which
is a different question and the one that matters: a backup job whose `openmrsdb`
service has been unreachable since a compose rename fails silently every night,
and the only visible symptom is that the newest dump stops moving.

A newest dump over 36h old is a `GAP`, as is any leftover `.part` file.

### Step 9 — Service health

`docker compose ps` per service, plus HTTP probes of the OpenMRS REST API and the
Bahmni UI. This is the site **as found** — probed before anything below reloads
it.

### Step 10 — Applying the compose files

```bash
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard && docker compose up -d
```

Step 1 fast-forwarded `bahmni-docker-ls`, which **is** the compose files this
command reads. Without this step, pulling that repo changes files nothing ever
reads, and a site can sit for months on a stack definition it already has on
disk.

The EMR reload in step 11 is **not** a substitute: it names one service, so a new
service, a changed image tag, a new port or a changed environment block anywhere
else in the file is invisible to it.

`up -d` is a **reconcile, not a restart**. A service whose resolved definition
did not change is left running exactly as it is; only containers whose definition
moved are recreated, plus anything missing or stopped. On a site whose
`bahmni-docker-ls` did not move, this is a no-op.

That does include the database service, if the compose file changed it. Named
volumes — where the patient data lives — are never touched by `up -d`, but it can
mean a few seconds of database downtime. Hence the confirm, and
`--no-compose-up`.

**Images.** By default this deploys the images the host already has, pulling only
one it has never seen. A release that moves a tag *in place* (`:latest` and
friends) therefore needs `--pull-images`, which adds `--pull always`. It is off
by default because it turns a fast local reconcile into a download over whatever
link the site has.

The row is derived by diffing `docker compose ps -a -q` before and after, rather
than by parsing compose's progress output — that wording is a UI detail that
changes between compose releases, while an id that is gone is unambiguously a
container that was replaced.

### Step 11 — Reloading the EMR

```bash
docker compose up -d --force-recreate --renew-anon-volumes openmrs
```

The steps above update files on disk — standard-config, the omods, the
implementer interface, the forms. A long-running `openmrs` container goes on
serving what it read at boot, and anything seeded into an **anonymous** volume
when the container was first created keeps the old content even across a plain
restart. `--force-recreate` replaces the container; `--renew-anon-volumes`
throws its anonymous volumes away so they are re-seeded.

> **This takes the EMR down for its usual 30+ minute boot.** Named volumes and
> the separate `openmrsdb` service (the patient data) are **not** touched, so
> this is not a data-loss operation — but anything a site hand-placed *inside*
> the running EMR container, rather than in its config repo, is gone.

Hence the confirm, `--no-recreate`, and `EREGISTER_CATCHUP_RECREATE=0`.

## 3.4 The report

```
══════════════════════════════════════════════════════════════
 eRegister v1 — catch-up report  (2026-09-21 14:22:05 SAST)
══════════════════════════════════════════════════════════════

  ⟳ FIXED self      upgrade-to-v1        a1b2c3d -> e4f5a6b (/var/lib/v1/upgrade-to-v1)
  ✔ OK    repo      standard-config-ls   current (Bokang-changes @ 7f3c1a2)
  ⟳ FIXED repo      clinical-obs-forms   main 4d9e0b1 -> 8c2a7f5
  — SKIP  repo      bahmni-docker-ls     left at 22b9e10 (--no-stack)
  ✔ OK    script    eregister-autopull.sh  present, refreshed from this release
  ✔ OK    cron      eregister-form-import  systemd timer active (next: Mon 03:30)
  ⟳ FIXED forms     retire               12 form(s) retired (reason: deploying latest forms …)
  ⟳ FIXED forms     import               imported 12/48 form(s), 30 unchanged, 12 published, 0 failed
  ✔ OK    forms     decode               nothing escaped in openmrs:/home/bahmni/clinical_forms
  ✔ OK    concepts  dump                 omrs_concept_dictionary_20260804.sql is the one imported
  ✔ OK    reporting import               already current (sha256 matches)
  ✔ OK    idgen     source 14            'Old ART Number' already retired
  ✘ GAP   backup    newest dump          newest dump is 51h old — the nightly job is not producing files
  ✔ OK    service   openmrs              running
  ⟳ FIXED stack     compose up           3 container(s) created or recreated from /var/lib/v1/…
  ⟳ FIXED reload    openmrs              recreated with renewed anonymous volumes — booting now

[ℹ] OK = already current · FIXED = redone by this run · SKIP = left alone · GAP = needs attention
[⚠] 1 item(s) need attention — see the ✘ rows above.
```

| Status | Symbol | Meaning |
|---|---|---|
| `OK` | `✔` | Already current — this run changed nothing |
| `FIXED` | `⟳` | Redone by this run |
| `SKIP` | `—` | Deliberately left alone (a flag, or you declined) |
| `GAP` | `✘` | Needs a human |

The footer also prints the undo statements for everything the run wrote, and the
commands to run each job by hand.

## 3.5 Exit status

```bash
sudo ./catch-up.sh --yes; echo $?
```

`0` when there are no `GAP` rows; non-zero otherwise. This is what makes it
usable as a monitoring check.

## 3.6 Decode-only mode

The fast path for a site whose forms are already deployed and only need the
entity clean-up:

```bash
sudo ./catch-up.sh --decode
```

No repo is updated, nothing is imported or scheduled, no health probe runs and
the EMR is left running — so it costs seconds instead of the usual run. The
self-update row is kept (it already happened in phase 1), and the verdict is
scoped honestly:

```
[✔] Decode complete: nothing left escaped. Nothing else was checked.
```

## 3.7 Worked examples

### The normal run

```bash
cd /var/lib/v1/upgrade-to-v1 && sudo ./catch-up.sh
```

### Unattended, from the network

```bash
curl -fsSL --retry 8 --retry-max-time 180 \
  https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/catch-up.sh \
  | sudo EREGISTER_BAHMNI_PASS='<superman password>' bash -s -- --yes
```

### Deploy new forms, touch nothing else

```bash
sudo ./catch-up.sh --no-stack --no-concepts --no-reporting --no-idgen \
                   --no-db-backup --no-compose-up
```

### Pick up a new stack release, including moved image tags

```bash
sudo ./catch-up.sh --yes --pull-images
```

### Reconcile now, reload the EMR later tonight

```bash
sudo ./catch-up.sh --no-compose-up --no-recreate
# then, in the maintenance window:
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo docker compose up -d
sudo docker compose up -d --force-recreate --renew-anon-volumes openmrs
```

### Bring hand-edited repos back onto the release

```bash
sudo ./catch-up.sh --force-repos      # DISCARDS local changes in those clones
```

## 3.8 As a monitoring check

```bash
30 6 * * 1 /var/lib/v1/upgrade-to-v1/catch-up.sh --yes --no-forms --no-idgen \
           --no-compose-up --no-recreate >> /var/log/eregister-catchup.log 2>&1
```

Note what that line switches off. `--yes` answers every confirmation with "yes",
so a scheduled run would otherwise retire and re-import forms, retire the
identifier source, apply the compose files to the stack and reload the EMR
unattended, week after week.

`--no-compose-up` matters most here: without it an unattended run would recreate
whichever containers a freshly-pulled `bahmni-docker-ls` changed, at 06:30 on a
Monday, with nobody watching.

> **A monitoring check should report the site, not change it.** Keep the skips,
> and do the writing runs by hand.

## 3.9 The six things catch-up writes

Everything else in a run is read-only. These are the exceptions, each
individually confirmed and each with a flag that skips it:

| Write | Reversible? | Skip with |
|---|---|---|
| Retire the forms this release replaces | Yes — one `UPDATE`, printed by the run | `--no-retire-forms` |
| Decode HTML entities in the EMR's form JSON | Textual, idempotent | `--no-decode` |
| Import the report definitions | Yes — a pre-import dump is taken first | `--no-reporting` |
| Retire the disused identifier source | Yes — one `UPDATE`, printed by the run | `--no-idgen` |
| `docker compose up -d` on the whole stack | Re-runnable; named volumes untouched | `--no-compose-up` |
| Recreate the EMR service | Re-runnable; 30+ min downtime | `--no-recreate` |

Each of the two database writes earns its place the same way: one table, no
patient data, reversible in a single statement, and **nothing else on the site is
ever going to do it**. Reporting them as gaps would leave those gaps open
forever.
