# 10. Operations runbook

Worked examples for the tasks that actually come up. Each one is a complete
recipe, not a fragment.

## 10.1 Upgrade a 0.92 site to v1

```bash
# 1. From the network, interactively — you confirm every step
curl -fsSL --retry 8 --retry-max-time 180 \
  https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/install.sh | bash
```

Then, **after waiting 30+ minutes for the EMR to boot**:

```bash
# 2. Fix the OCL concept names
cd /var/lib/v1/upgrade-to-v1 && sudo ./ocl-fix.sh

# 3. Deploy the forms and the report definitions
sudo ./catch-up.sh
```

> [!WARNING]
> Step 3 is not optional. `install.sh` clones the forms and the report
> definitions but imports neither. Until `catch-up.sh` has run, neither is on
> the site.

## 10.2 Deploy a new release of the 2026 forms

The normal case. Someone has pushed new form exports to `clinical-obs-forms`.

```bash
cd /var/lib/v1/upgrade-to-v1
sudo ./catch-up.sh
```

Answer yes at:

- `Retire these N form(s) before importing?` — retires the outgoing set
- `Run the form import now?` — deploys the incoming set
- `Recreate 'openmrs' now?` — reloads the EMR so it serves them

If you only want the forms touched and nothing else:

```bash
sudo ./catch-up.sh --no-stack --no-concepts --no-reporting \
                   --no-idgen --no-db-backup --no-compose-up
```

### Verify afterwards

```bash
sudo tail -n 20 /var/log/eregister-form-import.log
```

```sql
SELECT name, version, retired FROM form
WHERE name LIKE '%2026%' ORDER BY name, version DESC;
```

## 10.3 Change the form-retirement pattern for a new year

```bash
sudo EREGISTER_FORM_RETIRE_NAME_LIKE='%2027%' \
     EREGISTER_FORM_RETIRE_REASON='deploying 2027 forms' \
     ./catch-up.sh
```

To make it permanent, change the default in `lib/core/config.sh` and push.

## 10.4 Forms are deployed but show as unpublished

A form imported through the Implementer Interface — or by a version of this
script from before publishing existed — sits in **Draft**, and is not offered in
the clinical app until it is published.

Publish everything that is deployed, without re-importing anything:

```bash
sudo /usr/local/bin/bahmni-form-import.sh -k --publish-only \
     -r /var/lib/v1/clinical-obs-forms
```

Seconds per form, and it cannot change what any form contains. To see what would
happen first:

```bash
sudo /usr/local/bin/bahmni-form-import.sh -k --publish-only --dry-run \
     -r /var/lib/v1/clinical-obs-forms
```

An ordinary `catch-up.sh` run fixes this too — publication is re-asserted on
forms that are skipped as unchanged — but `--publish-only` is the targeted, fast
version.

### Check what is still in Draft

```sql
SELECT name, version FROM form
WHERE published = 0 AND retired = 0 ORDER BY name;
```

### Keep a particular form unpublished

Publication re-asserts, so a hand-unpublished form comes back. On a site where
that matters:

```bash
sudo ./catch-up.sh --no-publish
```

## 10.5 A form did not deploy

```bash
# 1. What did the importer say?
sudo tail -n 60 /var/log/eregister-form-import.log

# 2. Unresolved concepts?
ls -l /var/lib/v1/form-import/*.importErrors.txt
cat /var/lib/v1/form-import/*.importErrors.txt
```

If concepts are missing, the dictionary has not caught up:

```bash
sudo ./import-concepts.sh          # then re-run the form import
```

If the form is simply being skipped as unchanged:

```bash
sudo /usr/local/bin/bahmni-form-import.sh -k --force \
     -r /var/lib/v1/clinical-obs-forms
```

## 10.6 Forms render `&lt;` instead of `<`

```bash
sudo ./catch-up.sh --decode
```

Seconds, not minutes. Then restart the EMR so it re-reads the files:

```bash
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo docker compose restart openmrs
```

If a second decode run still reports escaping, the nesting is deeper than the
default five passes:

```bash
sudo EREGISTER_FORM_DECODE_MAX_PASSES=12 ./catch-up.sh --decode
```

## 10.7 Pick up a new stack release

Someone has pushed new compose files to `bahmni-docker-ls`.

```bash
# in a maintenance window
cd /var/lib/v1/upgrade-to-v1
sudo ./catch-up.sh --pull-images
```

`--pull-images` matters when the release moves an image tag *in place*. Without
it, the host deploys images it already has.

To check what moved before applying anything:

```bash
sudo ./catch-up.sh --no-compose-up --no-recreate
# read the 'repo bahmni-docker-ls' row, then decide
```

## 10.8 Undo a form retirement

```bash
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo docker compose exec -T openmrsdb mysql -uroot -p openmrs -e "
  UPDATE form SET retired = 0, retired_by = NULL, date_retired = NULL,
         retire_reason = NULL
  WHERE retire_reason = 'deploying latest forms with the latest changes - kgatman';"
```

Then pass `--no-retire-forms` on subsequent runs, or the next catch-up retires
them again.

## 10.9 Undo an identifier-source retirement

```bash
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo docker compose exec -T openmrsdb mysql -uroot -p openmrs -e "
  UPDATE idgen_identifier_source
  SET retired = 0, retired_by = NULL, date_retired = NULL, retire_reason = NULL
  WHERE id = 14;"
```

Then pass `--no-idgen`, for the same reason.

To see the table first:

```sql
SELECT id, name, retired FROM idgen_identifier_source;
```

## 10.10 Undo a report-definition import

```bash
ls -lt /var/lib/v1/bahmni-backup/reporting-preimport-*.sql | head

cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo cat /var/lib/v1/bahmni-backup/reporting-preimport-20260921_141203.sql \
  | sudo docker compose exec -T openmrsdb mysql -uroot -p openmrs
```

## 10.11 Undo a concept-dictionary import

```bash
ls -lt /var/lib/v1/bahmni-backup/concepts-preimport-*.sql | head

cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo cat /var/lib/v1/bahmni-backup/concepts-preimport-20260921_040501.sql \
  | sudo docker compose exec -T openmrsdb mysql -uroot -p openmrs
```

## 10.12 Restore the database from a nightly dump

```bash
# check it first
gzip -t /var/lib/v1/db-backups/latest.sql.gz && echo "gzip OK"
gzip -dc /var/lib/v1/db-backups/latest.sql.gz | tail -n 3   # -> "Dump completed"

# restore
gzip -dc /var/lib/v1/db-backups/latest.sql.gz \
  | ( cd /var/lib/v1/bahmni-docker-ls/bahmni-standard \
      && sudo docker compose exec -T openmrsdb mysql -uroot -p )

# then reload the EMR
cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
sudo docker compose up -d --force-recreate --renew-anon-volumes openmrs
```

## 10.13 Wire catch-up into monitoring

```bash
sudo crontab -e
```

```cron
30 6 * * 1 /var/lib/v1/upgrade-to-v1/catch-up.sh --yes --no-forms --no-idgen \
           --no-compose-up --no-recreate >> /var/log/eregister-catchup.log 2>&1
```

Exit status is `0` only when there are no `GAP` rows, so any monitoring system
that watches exit codes works unchanged.

> [!WARNING]
> Keep every one of those skips. `--yes` answers every confirmation, so without
> them a scheduled run would retire and re-import forms, retire the identifier
> source, apply the compose files and reload the EMR unattended — at 06:30 on a
> Monday, with nobody watching.

## 10.14 Re-point a site at a different branch

```bash
sudo EREGISTER_REF_OBS_FORMS=testing ./catch-up.sh
```

The repo is currently on `main`, so catch-up reports it as off-release and leaves
it alone. Force the move:

```bash
sudo EREGISTER_REF_OBS_FORMS=testing ./catch-up.sh --force-repos
```

To move **every** repo at once:

```bash
sudo ./catch-up.sh --force-repos --install-dir /var/lib
# with EREGISTER_TARGET_REF set, if you want a single ref list
```

## 10.15 Move the whole install somewhere else

```bash
sudo ./install.sh --install-dir /srv
# everything then lives under /srv/v1
```

Every later run needs the same flag:

```bash
sudo ./catch-up.sh --install-dir /srv
```

or set it once:

```bash
export EREGISTER_INSTALL_BASE=/srv
```

## 10.16 Re-run an interrupted upgrade

```bash
cat /var/lib/v1/.eregister-upgrade-complete
```

| Contents | Do this |
|---|---|
| `stage=complete` | Nothing. Run `catch-up.sh` instead |
| `stage=migrated` | Re-run `install.sh` — it will redo the upgrade and finish the outstanding steps |
| *(file absent)* | Re-run `install.sh` |

> [!CAUTION]
> A re-run at `stage=migrated` **reloads the database from the pre-upgrade
> dump**, replacing anything entered since it was made.

## 10.17 Check that a release is actually publishable

After adding or renaming anything under `lib/` or `bin/`, push it, then:

```bash
./tests/check-published.sh
```

That verifies every module is reachable over raw HTTP — which is what the
`curl | bash` one-liners fetch. A half-published branch fails here rather than
mid-run on a site.
