# 1. Architecture and layout

## 1.1 The repository

```
upgrade-to-v1/
├── install.sh              the upgrade (0.92 -> v1)
├── catch-up.sh             reconcile a live v1 site
├── import-forms.sh         the form import, standalone
├── import-concepts.sh      the concept dictionary, standalone
├── ocl-fix.sh              the post-startup OCL concept-name fix
├── bin/
│   └── bahmni_form_import.sh   the form importer (installed to /usr/local/bin)
├── lib/
│   ├── core/               config, logging, traps, prompt, cli
│   ├── system/             platform, privilege, deps
│   └── upgrade/            verify, detect, backup, migrate, rollback,
│                           postinstall, concepts, reporting, forms, idgen,
│                           autopull, dbbackup, oclfix, catchup
└── tests/
    └── check-published.sh  verifies every module is reachable over raw HTTP
```

All logic lives in functions inside `lib/`. The entry scripts hold only their
own `main()` and the module list they need.

## 1.2 Module loading and the `curl | bash` path

Each entry script declares the modules it needs, in dependency order:

```bash
EREGISTER_MODULES=(
  core/config.sh
  core/logging.sh
  core/traps.sh
  core/prompt.sh
  core/cli.sh
  system/platform.sh
  ...
)
```

If `lib/` sits next to the script, it is sourced from there. If it does not —
the `curl | bash` case, where only one file was downloaded — the script fetches
the modules itself:

1. **Shallow clone** of the repo. One request, always a self-consistent tree,
   and it resolves the remote's default branch by itself.
2. **File by file** from `EREGISTER_RAW_BASE`, if the clone fails.

It proceeds only once **every** module in the list is present, so a
half-published branch fails here with a message naming the missing file, rather
than with curl's opaque `(56) … error: 404` somewhere in the middle of a run.

> Override the module location with `EREGISTER_LIB_DIR` — useful for a system
> install where `lib/` lives somewhere other than beside the script.
>
> After adding or renaming anything under `lib/` or `bin/`, push it and run
> `./tests/check-published.sh`. That is what the one-liners fetch.

## 1.3 On-disk layout

Everything lives under `<base>/v1`, where `<base>` is `/var/lib` by default:

```
/var/lib/v1/
├── bahmni-docker-ls/               the v1 stack (compose files)
│   └── bahmni-standard/            <- RESTORE_DIR: where compose runs
│       ├── docker-compose.yml
│       ├── restore_bahmni_standard.sh
│       └── run-bahmni.sh
├── standard-config-ls/             Bahmni/clinical app config
├── openmrs-v1-modules/             OpenMRS omods (~246 MB)
├── implementer-interface-release/  the Implementer Interface build
├── clinical-obs-forms/             Form Builder JSON exports
├── dhisconnector_mappings_v1/      DHIS2 connector mappings
├── eregister_concepts_release_v1/  concept dictionary dumps
├── openmrs_reporting_release/      report definitions (serialized_object dump)
├── upgrade-to-v1/                  this repo, kept current by catch-up.sh
├── bahmni-backup/
│   ├── openmrsdb_backup.sql        the 0.92 dump the restore reads
│   ├── bahmni_config/              the 0.92 config (pinned, restore-only)
│   ├── concepts-preimport-*.sql    taken before each dictionary import
│   └── reporting-preimport-*.sql   taken before each report-definition import
├── db-backups/                     the rolling nightly dumps (mode 0700)
│   ├── openmrs_<stamp>.sql.gz
│   └── latest.sql.gz               symlink to the newest
├── form-import/                    scratch dir for unattended form imports
├── .eregister-upgrade-complete     the stage marker (see §2.6)
├── .bahmni_form_import_state.json  per-form sha256 + version
├── .eregister_concept_import_state sha256 of the imported dictionary
└── .eregister_reporting_import_state
```

Outside `<base>`:

```
/usr/local/bin/bahmni-form-import.sh        the form importer
/usr/local/bin/eregister-form-import.sh     the wrapper cron/systemd runs
/usr/local/bin/eregister-concept-import.sh  the concept import runner
/usr/local/bin/eregister-db-backup.sh       the nightly database backup
/usr/local/bin/eregister-autopull.sh        the repo sync
/etc/eregister/form-import.env              EMR credentials (mode 0600)
/var/log/eregister-*.log                    one log per job
```

> **Why the state files live in `<base>/v1` and not inside the clones:** the
> auto-pull job runs `git reset --hard` on those clones. A deployment record
> stored inside one would be wiped by a routine sync.

## 1.4 The repositories

| Repo | Default ref | Role | Auto-pulled? |
|---|---|---|---|
| `bahmni-docker-ls` | `Bokang-changes` | The v1 stack — compose files | **No** (pinned) |
| `standard-config-ls` | `Bokang-changes` | Clinical app configuration | Yes |
| `openmrs-v1-modules` | `main` | OpenMRS omods (~246 MB) | Yes |
| `implementer-interface-release` | `main` | Implementer Interface build | Yes |
| `clinical-obs-forms` | `main` | Form Builder JSON exports | Yes |
| `dhisconnector_mappings_v1` | `master` | DHIS2 connector mappings | Yes |
| `eregister_concepts_release_v1` | `main` | Concept dictionary dumps | Yes |
| `openmrs_reporting_release` | `master` | Report definitions | Yes |
| `bahmni_config092` | `main` | The 0.92 config, beside the backup | **No** (restore-only) |
| `upgrade-to-v1` | `main` | This toolkit | Self-updated by `catch-up.sh` |

Two deliberate exclusions from the auto-pull job:

- **`bahmni-docker-ls`** holds the compose files the running stack reads. It
  must not drift underneath a running instance, so it moves only when a human
  runs `catch-up.sh`.
- **`bahmni_config` (0.92)** is historical. It is what the restore reads; it is
  checked for presence and never updated.

### Pinning a ref across all repos

The repos do not share a branch name, so `--target-ref` takes a
**comma-separated preference list**, tried in order against each remote. The
first ref that exists on that remote wins; the repo's own default is the last
resort:

```bash
sudo ./install.sh --target-ref Bokang-changes,main
```

That resolves to `Bokang-changes` on the stack repos and `main` on the asset
repos, in one flag. The ref is resolved against the remote **before** cloning,
so a bad ref fails loudly rather than silently landing on the default branch.

A full 40-character SHA is also accepted, and is handled specially: `git clone
--branch` rejects a raw SHA, so the repo is cloned in full and the commit is
checked out afterwards.

## 1.5 Privilege

The scripts detect whether they need elevation and how to get it:

```
[ℹ] Elevation required for /var/lib; will use sudo.
```

Everything that writes under `<base>` or to `/usr/local/bin`, `/etc` or
`/var/log` goes through an internal `as_root` helper, so the scripts work both
when run as root and when run by a user who can `sudo`.

### Repository ownership

Site clones end up owned by whoever created them — root when the installer ran
under `sudo`, the operator when it did not. Since git 2.35 a repo whose owner is
not the current user is refused outright:

```
fatal: detected dubious ownership in repository at '/var/lib/v1/...'
```

That is how a root-run cron job quietly stops updating a user-owned clone: every
command fails, and the caller reads it as "no branch" or "not a repo". Every git
call in the toolkit therefore goes through a wrapper:

```bash
git_here() { git -c safe.directory='*' "$@"; }
```

This relaxes **only** the ownership check, for that one invocation. File
permissions still apply exactly as before.

## 1.6 Prompting

The scripts are "cautious by default": every step that changes something is
confirmed individually.

- An answer that is neither yes nor no is treated as a slip — the prompt asks
  whether you meant to stop, and repeats itself if you did not.
- Prompts read from `/dev/tty`, never from the script's own stdin. This is what
  makes `curl … | bash` work: stdin is the script itself.
- End-of-input on `/dev/tty` takes the advertised default rather than spinning.
- `--yes` (or `EREGISTER_ASSUME_YES=1`) answers yes to everything. Required for
  unattended runs, and worth thinking about carefully — see §3.11.

Passwords are never echoed, never passed on a command line where another user
could see them in `ps`, and never hard-coded:

- The 0.92 database password is prompted, or read from `EREGISTER_DB_PASS`.
- The EMR password is prompted, or read from `EREGISTER_BAHMNI_PASS`, and is
  stored `0600` in `/etc/eregister/form-import.env` for the unattended runs.
- Inside containers, `MYSQL_PWD` or the container's own `MYSQL_ROOT_PASSWORD` is
  used, so the password never lands on a process list.
