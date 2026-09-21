# 11. Troubleshooting

## 11.1 `curl: (22) The requested URL returned error: 503`

That is **raw.githubusercontent.com**, not your server and not the upgrade.

The raw host throttles and has short outages. When it answers `503` (or `429`),
`curl -f` gives up with exit `22` and the one-liner never reaches `bash`. Nothing
has been changed on the machine at that point — the fetch failed before any work
started, so it is always safe to run the command again.

Measured on 2026-09-12: three of five requests to the same raw URL returned
`503`, the rest `200`, all served by the same edge. It comes and goes within
seconds, which is exactly what retrying fixes.

Every command in this guide carries retry flags:

```bash
curl -fsSL --retry 8 --retry-max-time 180 <url> | bash
```

`--retry-delay` is deliberately **not** set: without it curl backs off
exponentially (1s, 2s, 4s, 8s …), which spreads the attempts across a
minutes-long wobble instead of hammering the same dead edge for ten seconds.

Two things to know when reading the output:

- A `curl: (22) … 503` line **followed by the script running** is a retry that
  succeeded. curl prints the error for each attempt; the run is fine.
- `503` repeated until the command dies means the raw host is down for longer
  than the retries cover. Wait a few minutes, or bypass the raw host entirely by
  running from a checkout, which fetches over git instead:

  ```bash
  git clone https://github.com/Lesotho-eRegister-v1/upgrade-to-v1
  cd upgrade-to-v1 && sudo ./catch-up.sh
  ```

Once a script is running it is largely past this: the entry points fetch `lib/`
by shallow-cloning the repo **first** (github.com, not the raw host), and only
fall back to per-file raw downloads. The fragile moment is the outer
`curl … | bash`.

## 11.2 `fatal: detected dubious ownership in repository`

Site clones end up owned by whoever created them. Since git 2.35 a repo owned by
someone other than the current user is refused outright.

Every git call in the toolkit already passes `-c safe.directory='*'`, so this
should not appear from the scripts themselves. If you see it running git by hand:

```bash
git -c safe.directory='*' -C /var/lib/v1/clinical-obs-forms status
```

Do **not** `chown -R` the clones as a fix. The scripts run as root and as the
operator at different times; the ownership relaxation is per-invocation and
deliberate.

## 11.3 A repo row says `SKIP … uncommitted local changes`

```
  — SKIP  repo  standard-config-ls  uncommitted local changes — left untouched; --force-repos to reset it onto Bokang-changes
```

This is working as designed. Sites hand-edit config, and silently discarding
that would be the one destructive thing catch-up could do.

Decide which you want:

```bash
# see what changed
sudo git -c safe.directory='*' -C /var/lib/v1/standard-config-ls status
sudo git -c safe.directory='*' -C /var/lib/v1/standard-config-ls diff

# keep the changes: commit them, then re-run catch-up normally
# discard them: 
sudo ./catch-up.sh --force-repos
```

The same row appears for a detached HEAD and for a repo on a different branch
than the release pins. The detail text says which.

## 11.4 `openmrsdb:openmrs is not accepting connections right now`

Expected straight after an upgrade or an EMR recreate. A freshly started v1 stack
needs 30+ minutes before its database answers — hours on site hardware.

Nothing is wrong. The affected steps report a `GAP` and move on. Re-run
`catch-up.sh` once the stack is up.

To check progress:

```bash
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo docker compose ps
sudo docker compose logs --tail 50 openmrs
```

## 11.5 The form import fails or does nothing

| Symptom | Cause | Fix |
|---|---|---|
| `not runnable (missing runner or credentials)` | `catch-up.sh` has never completed step 2 on this host | Run `catch-up.sh` again, or `import-forms.sh` |
| `not run — the EMR rejected the stored password` | Password changed | You will be prompted; the new one is verified before it is saved |
| `imported 0/48` | Every form is already current | Nothing wrong. `--force` to redeploy anyway |
| `<form>.importErrors.txt` written | Concepts unresolved | Import the dictionary, then re-run |
| `run failed — see /var/log/…` | Usually the EMR still booting | Wait; the daily job retries |

```bash
sudo tail -n 60 /var/log/eregister-form-import.log
ls -l /var/lib/v1/form-import/
```

## 11.6 Forms deploy but stay unpublished

A form in **Draft** is deployed but not offered in the clinical app. The
Implementer Interface's Import button always leaves one there, and so did this
script before publishing was added.

```bash
sudo /usr/local/bin/bahmni-form-import.sh -k --publish-only \
     -r /var/lib/v1/clinical-obs-forms
```

```sql
SELECT name, version FROM form WHERE published = 0 AND retired = 0 ORDER BY name;
```

If publishing itself is failing, the importer says which endpoint refused it:

| Message | Meaning |
|---|---|
| `publish endpoint answered HTTP 404 — trying the core form resource` | `bahmnicore` is older than the `bahmniie` publish endpoint, or the module is absent. The fallback usually still works |
| `ERROR publishing: bahmniie said 404/405 and /form/<uuid> said HTTP 403` | The account lacks the privilege to manage forms. Use an account with form-management rights |
| `ERROR: publish returned OK but '<name>' is still unpublished` | The endpoint accepted the call but nothing changed — check the OpenMRS log |
| `WARNING: cannot publish '<name>' — the server does not list it` | The form name in the JSON export does not match anything on the server |

Run with `-v` to see the endpoint fallback decisions.

If a form keeps coming *back* published after you unpublish it by hand, that is
the re-assertion working as designed — see
[§4.5](04-forms.md#45-publishing). Use `--no-publish`.

## 11.7 Forms were retired but never came back

The retirement clears the recorded sha256 so the importer redeploys them. If
that could not happen you would have seen:

```
[⚠] Could not rewrite /var/lib/v1/.bahmni_form_import_state.json; the retired
[⚠] forms may be skipped as 'unchanged'. Force them with:
[⚠]   sudo /usr/local/bin/bahmni-form-import.sh --force -r /var/lib/v1/clinical-obs-forms
```

Run exactly that. Then confirm:

```sql
SELECT name, version, retired FROM form
WHERE name LIKE '%2026%' ORDER BY name, version DESC;
```

You should see a new, un-retired version above the retired ones. If you need the
old set back immediately, see [§10.8](10-runbook.md#108-undo-a-form-retirement).

## 11.8 The decode says `still escaped after 5 pass(es)`

The escaping nests deeper than the default cap:

```bash
sudo EREGISTER_FORM_DECODE_MAX_PASSES=12 ./catch-up.sh --decode
```

If it says the folder does not exist inside the container:

```
[✘] /home/bahmni/clinical_forms does not exist in the 'openmrs' container — set EREGISTER_FORM_DECODE_DIR
```

Find the real path:

```bash
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo docker compose exec openmrs sh -c 'ls -d /home/bahmni/* 2>/dev/null'
```

## 11.9 A nightly job is not producing files

```
  ✔ OK   cron    eregister-db-backup  systemd timer active (next: Mon 01:30)
  ✘ GAP  backup  newest dump          newest dump is 51h old
```

The timer exists but the runs are failing. Run it by hand and watch:

```bash
sudo /usr/local/bin/eregister-db-backup.sh
sudo tail -n 40 /var/log/eregister-db-backup.log
```

The most common cause is a compose service rename, so the runner cannot find
`openmrsdb`. Check:

```bash
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard && sudo docker compose ps
```

A leftover `.part` file means a run was interrupted mid-write:

```bash
ls -l /var/lib/v1/db-backups/*.part
sudo rm /var/lib/v1/db-backups/*.part   # then re-run the job
```

## 11.10 Changes were pulled but the site does not show them

Pulling a repo changes files on disk. It does not deploy anything. Which step is
missing depends on what changed:

| Changed | What still has to happen |
|---|---|
| `standard-config-ls`, `openmrs-v1-modules`, `implementer-interface-release` | The EMR must be recreated — `catch-up.sh` step 11 |
| `clinical-obs-forms` | The form import must run, then the EMR restart |
| `eregister_concepts_release_v1` | The concept import must run, then the EMR restart |
| `openmrs_reporting_release` | `catch-up.sh` imports it, then the EMR restart |
| `bahmni-docker-ls` | `docker compose up -d` — `catch-up.sh` step 10 |

If you ran catch-up with `--no-recreate`, none of the EMR-side changes are live
yet:

```bash
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo docker compose up -d --force-recreate --renew-anon-volumes openmrs
```

## 11.11 The upgrade failed part-way

If the old stack had already been frozen, rollback ran automatically:

```
[⚠] Upgrade failed — initiating rollback to eRegister Lesotho 0.92.
[✔] Old stack restarted.
[⚠] Your database backup is preserved at: /var/lib/v1/bahmni-backup/openmrsdb_backup.sql
```

The backup is always preserved. If the automatic restart did not work:

```bash
cd ~/bahmni_docker && sudo docker compose start
```

Then read the error above the rollback lines — it names the file and line that
failed.

## 11.12 `install.sh` says "already installed" but work is missing

```bash
cat /var/lib/v1/.eregister-upgrade-complete
```

`stage=complete` means the installer finished. If something is genuinely
missing — a scheduled job, the forms, the report definitions — that is what
`catch-up.sh` is for. It is almost never right to re-run `install.sh` with
`--force`, because that reloads the database from the pre-upgrade dump.

## 11.13 Getting more detail out of a run

```bash
# every command, as it runs
sudo bash -x ./catch-up.sh --decode

# the importer, verbosely
sudo /usr/local/bin/bahmni-form-import.sh -k -v --dry-run \
     -r /var/lib/v1/clinical-obs-forms

# what a scheduled run did
sudo journalctl -u eregister-form-import.service -n 100
```

## 11.14 Where the logs are

```
/var/log/eregister-db-backup.log
/var/log/eregister-autopull.log
/var/log/eregister-form-import.log
/var/log/eregister-concept-import.log
```

Plus `journalctl -u <unit>` on a systemd host, and whatever the stack itself
writes:

```bash
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo docker compose logs --tail 100 openmrs
```
