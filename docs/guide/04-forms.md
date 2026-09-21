# 4. Clinical observation forms

The `clinical-obs-forms` repo holds Bahmni **Form Builder JSON exports**.
`bin/bahmni_form_import.sh` replays what the Implementer Interface's "Import"
button does — concept UUID fix-up, `POST /form`, save body, save translations —
over the EMR's REST API, so those exports become live forms without anyone
clicking through the UI. It then does the one thing that button does **not**:
it publishes the form (§4.5).

> [!IMPORTANT]
> **`install.sh` does none of this.** The forms deploy over the REST API, and at
> the moment the upgrade finishes the EMR needs 30+ minutes before it answers
> one. The entire step — importer, credentials, runner, schedule and the first
> import — belongs to `catch-up.sh`, with `import-forms.sh` as the forms-only
> entry point.

## 4.1 What gets installed

| Path | What |
|---|---|
| `/usr/local/bin/bahmni-form-import.sh` | The importer itself |
| `/usr/local/bin/eregister-form-import.sh` | The wrapper cron/systemd runs |
| `/etc/eregister/form-import.env` | Credentials, mode `0600`, root-owned |
| `/var/lib/v1/.bahmni_form_import_state.json` | Per-form sha256 + version |
| `/var/lib/v1/form-import/` | Scratch dir for `importErrors.txt` |
| `/var/log/eregister-form-import.log` | The log |
| `eregister-form-import.timer` or `/etc/cron.d/eregister-form-import` | Daily at 03:30 |

The runner is a **bare-environment wrapper**: no `lib/`, no PATH assumptions, its
own log. It sources the env file, optionally refreshes the clone, then runs the
importer over the whole folder.

## 4.2 The order of operations in a catch-up run

```
_cu_forms_import
 ├─ is the runner installed and are there credentials?   → GAP if not
 ├─ "Run the form import now?"                           → SKIP if declined
 ├─ re-check the EMR password                            → GAP if rejected
 ├─ _forms_retire_stale     ← retire the outgoing set
 └─ run_form_import         ← deploy the incoming set, and publish it
_cu_forms_decode            ← always, even if nothing was imported
```

The retirement sits **inside** the import step, after the confirmation and the
credential check. That is deliberate: retiring the 2026 forms and then not
deploying the new ones would leave the site with nothing to fill in. The two
halves must not come apart.

## 4.3 Retiring the forms a release replaces

Straight before the import, every **live** form whose name matches the configured
pattern is marked retired:

```sql
UPDATE form SET retired = 1, retired_by = 1, date_retired = NOW(),
       retire_reason = 'deploying latest forms with the latest changes - kgatman'
WHERE name LIKE '%2026%' AND retired = 0;
```

This is how the year's outgoing set stops being offered at the same moment the
incoming one lands.

**OpenMRS retires rather than deletes.** The rows stay, and every observation
ever recorded against those forms keeps resolving. One `UPDATE` undoes it, and
the run prints it:

```
[ℹ] Undo it with:
[ℹ]   UPDATE form SET retired = 0, retired_by = NULL, date_retired = NULL,
[ℹ]          retire_reason = NULL WHERE retire_reason = 'deploying latest forms with the latest changes - kgatman';
```

### Why `AND retired = 0`

It is the script's own addition to the statement, for the same reason
`idgen.sh` carries it: without it, every run rewrites `date_retired` on rows
retired months ago, so the site loses the date they were actually retired and the
report claims a change it did not make.

### Why the import state is edited too

The importer deploys a form only when its **file** changed — and retiring a form
does not change its file. Without intervention the very forms just retired would
be skipped as "unchanged", and the site would be left with **no live copy of them
at all**.

So the retirement blanks the recorded `sha256` for exactly the retired form
names. It deliberately **keeps the recorded version**: the importer deploys
`max(state version, server version) + 1`, and a retired form is not in the
server's answer, so dropping the version could make it redeploy a number that
already exists on a retired row.

```
[ℹ] Cleared the recorded hash of the retired forms so the import redeploys them.
```

This is best-effort. If `jq` is missing or the state file cannot be rewritten,
you get a warning naming the manual fallback:

```
sudo /usr/local/bin/bahmni-form-import.sh --force -r /var/lib/v1/clinical-obs-forms
```

### Before it writes, it shows you

```
[ℹ] 12 live form(s) in 'openmrs' match name LIKE '%2026%':
    • ANC Intake 2026 (Nurse's)
    • HIV Treatment and Care Follow Up 2026
    …
[⚠] Retiring them stops them being offered. The rows are kept and the
[⚠] observations already recorded against them are NOT touched — this is reversible.
Retire these 12 form(s) before importing? [y/N]:
```

### Configuration

| Variable | Default | Meaning |
|---|---|---|
| `EREGISTER_FORM_RETIRE` | `1` | `0` (or `--no-retire-forms`) skips it |
| `EREGISTER_FORM_RETIRE_NAME_LIKE` | `%2026%` | SQL `LIKE` pattern matched against `form.name` |
| `EREGISTER_FORM_RETIRE_REASON` | `deploying latest forms with the latest changes - kgatman` | Written to `retire_reason` |
| `EREGISTER_FORM_RETIRE_BY` | `1` | `users.user_id` recorded as the retiring user |

Values are escaped before being interpolated into the SQL: backslashes first
(MySQL's own escape character), then single quotes.

### Report rows

| Status | Row | When |
|---|---|---|
| `FIXED` | `N form(s) retired (reason: …)` | Rows were retired |
| `OK` | `no live form matches name LIKE '%2026%' in openmrs` | Nothing to do |
| `SKIP` | `left alone (--no-retire-forms)` / `declined — N form(s) left live` | Disabled or declined |
| `GAP` | `openmrsdb:openmrs not reachable — nothing retired` | Database still booting |
| `GAP` | `N form(s) still live after the UPDATE` | The write did not take |

`no-db` is a `GAP` rather than a `SKIP` on purpose: the forms the release
replaces are still being offered, and nothing else on the site will retire them.

> [!NOTE]
> The **nightly** `eregister-form-import` job does not retire. Retiring a form set
> is a release action, not something that should happen unattended at 03:30.

## 4.4 The import

### Change detection

The importer keys its state file on **server URL + form name** and stores a
sha256 of the source file:

```json
{
  "https://localhost|HIV Treatment and Care Follow Up 2026": {
    "version": "3",
    "sha256": "ab12…",
    "form_uuid": "…",
    "file": "forms/HIV….json",
    "imported_at": "2026-08-24T09:12:03Z"
  }
}
```

So:

- a file **unchanged** since its last import → skipped, nothing deployed
- a same-named file holding a **new export** → counts as new work, deployed as
  the next version
- a file merely re-checked-out by the auto-pull job (new mtime, same bytes) →
  skipped

Hashing the export rather than the fixed-up payload means the question asked is
"did the author change the form?", independent of concepts being re-resolved on
every run.

Keying on the URL as well as the name keeps a dev run from convincing a later
prod run that a form is already up to date.

### Versioning

A changed form goes out as a **new version**; nothing live is overwritten.

```
last version 3 (state 3, server 3) — deploying 4
```

The target is `max(state version, server version) + 1`. The state file is the
record of what the script deployed, but the **server is the authority** —
someone may have saved a newer version in the Implementer Interface, or the
state file may have been lost.

### Concept validation

A form whose concepts are not in the dictionary is **not** deployed. The run
writes `<form>.importErrors.txt` into `/var/lib/v1/form-import/` listing the
unresolved names. That is usually a sign the concept dictionary has not caught
up — see [chapter 5](05-concepts.md).

`--skip-validation` bypasses it; `--dry-run` validates without deploying.

### Concurrency

Two overlapping runs would both read the same "last version" and deploy the same
number, so runs are serialised with `flock` on `<state file>.lock`. Where
`flock` is absent (stock macOS) the lock is simply skipped.

### Importer flags

```bash
/usr/local/bin/bahmni-form-import.sh [options] <file-or-dir>...
```

| Flag | Meaning |
|---|---|
| `--url URL` | EMR base URL |
| `--user` / `--password` | Credentials |
| `-k`, `--insecure` | Accept the stack's self-signed certificate |
| `-r`, `--recursive` | Recurse into directories |
| `-f`, `--force` | Deploy even when the file is unchanged |
| `--no-publish` | Leave the form in Draft (what the Import button does) |
| `--publish-only` | Publish what is already deployed; import nothing |
| `--dry-run` | Validate concepts only; deploy nothing |
| `--skip-validation` | Deploy without resolving concept references |
| `--version N` | Pin the version instead of bumping |
| `--no-bump` | Do not increment the version |
| `--state FILE` | Use a different state file |
| `--delay N` | Pause between forms |
| `-v`, `--verbose` | More output |

## 4.5 Publishing

**This is the step the Implementer Interface leaves to you.** Importing a form
there puts it in **Draft**; you then click "Publish" separately, and until you
do the form is not offered in the clinical app at all.

Deploying dozens of forms and then clicking Publish dozens of times is exactly
the work this script exists to remove, so it publishes by default, over the same
endpoint that button uses:

```
POST /openmrs/ws/rest/v1/bahmniie/form/publish?formUuid=<uuid>
```

Using the Bahmni endpoint rather than just flipping the `published` column means
whatever else Bahmni does on publish comes along with it. Where that endpoint is
missing — an older `bahmnicore`, or a stack without the module — the importer
falls back to the core OpenMRS form resource:

```
POST /openmrs/ws/rest/v1/form/<uuid>     {"published": true}
```

Either way the result is **read back** from the server before it is reported: a
`200` from the publish endpoint is not the same thing as a published form.

```
  form uuid 4f2a…
  saved body, version 4
  published version 4
  imported 'ANC Intake 2026' as version 4
```

### It re-asserts

A form that is skipped as **unchanged** is still checked, and published if it is
not:

```
=== ANC Intake 2026.json
  unchanged since version 3 — skipping (--force to import anyway)
  published version 3
```

That is what fixes a site whose forms were deployed before any of this existed:
they sit there as drafts, their files have not changed, so no ordinary import
would ever touch them again. One normal catch-up run now publishes the lot.

It costs one `GET` per unchanged form, and a `POST` only when there is something
to fix. A run where everything is already published makes no writes at all.

> [!WARNING]
> **The flip side is deliberate.** A form you unpublish by hand is published
> again by the next run. Use `--no-publish` /
> `EREGISTER_FORM_PUBLISH=0` on a site where that matters.

### Publishing without importing

For a site whose forms are already deployed and only need publishing:

```bash
sudo /usr/local/bin/bahmni-form-import.sh -k --publish-only \
     -r /var/lib/v1/clinical-obs-forms
```

No concept resolution, no `POST /form`, no version bump — seconds per form
rather than minutes, and it cannot change what any form contains.

```
=== ANC Intake 2026.json
  published version 3

=== HIV Follow Up 2026.json

published 1/2 form(s); nothing was imported (--publish-only)
```

`--dry-run` alongside it reports what each form's current state is without
changing anything:

```bash
sudo /usr/local/bin/bahmni-form-import.sh -k --publish-only --dry-run \
     -r /var/lib/v1/clinical-obs-forms
```

### Which version gets published

The **newest** version of that form name on the server. Older versions are left
exactly as they are — publishing v4 does not touch v1–v3.

### Turning it off

| Where | How |
|---|---|
| `catch-up.sh` | `--no-publish` (and `--no-forms` implies it) |
| The importer | `--no-publish` |
| Anywhere | `EREGISTER_FORM_PUBLISH=0`, which reaches the daily job as `BAHMNI_PUBLISH=0` in `/etc/eregister/form-import.env` |

## 4.6 Decoding the deployed form JSON

A deployed form can come back out of the EMR with the markup in its labels
HTML-escaped — `&amp;` `&lt;` `&gt;` where the author wrote `&` `<` `>`. The
clinical app then renders the entity text itself, and forms that reference those
fields throw errors.

The fix is textual: decode the three entities in place, in the folder the EMR
keeps inside its own container (`/home/bahmni/clinical_forms` by default).

### Why repeatedly

**The escaping nests.** `&amp;lt;` is `&lt;` that was escaped a second time, and
one pass over it only gets back as far as `&lt;` — so a single pass can leave a
file that is still wrong, and still wrong in a way the same pass would fix.

It therefore runs again until a pass finds nothing left to change, rather than a
fixed number of times: five levels of nesting take five passes, a site with one
stops after the second, and `EREGISTER_FORM_DECODE_MAX_PASSES` (default 5) caps
it so a pathological file cannot spin forever.

Idempotent, and cheap on a clean folder: the first pass matches nothing and it
stops there. That is what makes it safe on every catch-up run.

It runs **before** the EMR is recreated at the end of a catch-up, so the reloaded
instance reads the decoded files.

### Return codes

| Code | Meaning |
|---|---|
| `0` | Clean — nothing left escaped |
| `1` | Could not run (no docker compose, no stack dir, exec failed) |
| `3` | The folder does not exist inside the container — set `EREGISTER_FORM_DECODE_DIR` |
| `4` | Still escaped after the maximum passes — raise `EREGISTER_FORM_DECODE_MAX_PASSES` |

### Decode on its own

```bash
sudo ./catch-up.sh --decode
```

Seconds instead of a full run. See [§3.6](03-catch-up.md#36-decode-only-mode).

> [!NOTE]
> `--decode` and `--no-decode` are not a toggle pair. `--no-decode` skips this
> step inside a normal run; `--decode` makes this step the *only* thing the run
> does. Passing both is an error.

## 4.7 `import-forms.sh` — forms on their own

Sets up (or re-installs and re-schedules) the whole form-import machinery
without the rest of the catch-up:

```bash
curl -fsSL --retry 8 --retry-max-time 180 \
  https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/import-forms.sh | bash
```

or, from the checkout:

```bash
bash ./import-forms.sh
```

Note: this script does **not** retire forms. The retirement is a release action
owned by `catch-up.sh`.

## 4.8 Running the import by hand

```bash
# the scheduled job, right now
sudo /usr/local/bin/eregister-form-import.sh

# validate concepts only, deploy nothing
sudo /usr/local/bin/bahmni-form-import.sh -k --dry-run -r /var/lib/v1/clinical-obs-forms

# re-deploy everything, ignoring the state file
sudo /usr/local/bin/bahmni-form-import.sh -k --force -r /var/lib/v1/clinical-obs-forms

# publish everything that is deployed but still in Draft
sudo /usr/local/bin/bahmni-form-import.sh -k --publish-only -r /var/lib/v1/clinical-obs-forms

# what happened last night
sudo tail -n 50 /var/log/eregister-form-import.log

# which forms does the site think it has deployed?
sudo jq 'keys' /var/lib/v1/.bahmni_form_import_state.json
```

### Inspecting forms in the database

```sql
-- every version of the 2026 forms, live and retired, published or draft
SELECT form_id, name, version, published, retired, date_retired
FROM form WHERE name LIKE '%2026%' ORDER BY name, version;

-- anything still sitting in Draft
SELECT name, version FROM form
WHERE published = 0 AND retired = 0 ORDER BY name;

-- what this script retired
SELECT COUNT(*) FROM form
WHERE retire_reason = 'deploying latest forms with the latest changes - kgatman';
```

## 4.9 Configuration summary

| Variable | Default |
|---|---|
| `EREGISTER_IMPORT_FORMS` | `1` (`--no-forms` disables) |
| `EREGISTER_BAHMNI_URL` | `https://localhost` |
| `EREGISTER_BAHMNI_USER` | `superman` |
| `EREGISTER_BAHMNI_PASS` | *(prompted)* |
| `EREGISTER_FORMS_DIR` | `<base>/v1/clinical-obs-forms` |
| `EREGISTER_FORM_IMPORT_INSECURE` | `1` (self-signed cert) |
| `EREGISTER_FORM_IMPORT_CRON` | `30 3 * * *` |
| `EREGISTER_FORM_IMPORT_ONCALENDAR` | `*-*-* 03:30:00` |
| `EREGISTER_FORM_IMPORT_SELF_PULL` | `1` — refresh the clone before importing |
| `EREGISTER_FORM_PUBLISH` | `1` (`--no-publish` disables) |
| `EREGISTER_FORM_RETIRE` | `1` (`--no-retire-forms` disables) |
| `EREGISTER_FORM_RETIRE_NAME_LIKE` | `%2026%` |
| `EREGISTER_FORM_RETIRE_REASON` | `deploying latest forms with the latest changes - kgatman` |
| `EREGISTER_FORM_RETIRE_BY` | `1` |
| `EREGISTER_FORM_DECODE` | `1` (`--no-decode` disables) |
| `EREGISTER_FORM_DECODE_DIR` | `/home/bahmni/clinical_forms` |
| `EREGISTER_FORM_DECODE_MAX_PASSES` | `5` |
