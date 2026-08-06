To run this script, just copy and paste this line below in your terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/install.sh | bash
```

> [!WARNING]
> If you need to do the upgrade process again, remember to run:
> `docker volume rm $(docker volume ls -q)` to clean all volumes.
> Make sure all volumes are deleted with `docker volume ls`

An example of how to use flags below:

```bash
curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/install.sh | bash -s -- --force --yes
```

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
    ├── backup.sh                # ensure_dir, take_backup
    ├── migrate.sh               # shutdown_old_stack, fetch_repos, run_restore
    ├── rollback.sh              # rollback
    ├── postinstall.sh           # post_verify, next_steps
    ├── concepts.sh              # import_concepts (concept dictionary -> openmrsdb)
    └── autopull.sh              # install_auto_pull (systemd timer / cron.d)
```

# Importing the concept dictionary

At the end of a run the installer loads the concept dictionary from the
`eregister_concepts_release_v1` clone
(`/var/lib/v1/eregister_concepts_release_v1/omrs_concept_dictionary_v1.sql`)
into the `openmrs` database inside the `openmrsdb` container — the scripted
version of that repo's manual `docker cp` + `mysql source` instructions.

The dump is a mysqldump with `DROP TABLE IF EXISTS` + `CREATE TABLE` for the
`concept_*` and `drug*` tables, so it **replaces** them rather than merging.
`drug_order` is one of those tables. Before importing, the current contents of
exactly the tables the file touches are dumped to
`/var/lib/v1/bahmni-backup/concepts-preimport-<timestamp>.sql`; feed that file
back the same way to undo the import.

Re-run it on its own at any time (for example after the auto-pull job pulls a
newer dictionary):

```bash
curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/import-concepts.sh | bash
```
(or, from the upgrade repo: `bash ./import-concepts.sh`)

OpenMRS caches concepts, so restart the EMR service afterwards for the new
dictionary to show up:
`docker compose restart openmrs` (from `/var/lib/v1/bahmni-docker-ls/bahmni-standard`).

Skip or tune it with `--no-concepts` / `EREGISTER_IMPORT_CONCEPTS=0`,
`EREGISTER_CONCEPTS_SQL_NAME` (dump filename) and `EREGISTER_CONCEPTS_DB_WAIT`
(seconds to wait for `openmrsdb`, default 300).

# Keeping the v1 repos up to date

After a successful upgrade the installer offers to schedule a job that
periodically `git pull`s the asset/config repos — `standard-config-ls`,
`implementer-interface-release`, `openmrs-v1-modules`, `clinical-obs-forms`,
and `dhisconnector_mappings_v1` — so a deployed instance tracks their remotes
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

You can configure the cronjob like so:

`sudo crontab -e`

`# Top of every hour (00:00, 01:00, 02:00 ...)`

`0 * * * * /usr/local/bin/eregister-autopull.sh >> /var/log/eregister-autopull.log 2>&1`

Remember to `sudo chmod +x /usr/local/bin/eregister-autopull.sh`


Tune or disable via env vars: `EREGISTER_AUTO_PULL=0` (off),
`EREGISTER_AUTO_PULL_ONCALENDAR` (systemd schedule, default `*-*-* 02:30:00`),
`EREGISTER_AUTO_PULL_CRON` (cron schedule, default `30 2 * * *`).

# Checklist
    - working superman password. ✅
    - login locations are loading correctly ✅
    - able to search for your patients / clients ✅
    - LabonFHIR 1.3.1 ✅
    - FHIR2 1.9.0 ✅
    - DHIS-Connector ✅
