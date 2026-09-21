# 9. Configuration reference

Everything is configured in one of two ways: a **command-line flag**, or an
`EREGISTER_*` **environment variable**. Where both exist, the flag is a
shorthand for the variable and the two are listed together.

Variables are read at startup, so they work equally well inline:

```bash
sudo EREGISTER_FORM_RETIRE_NAME_LIKE='%2027%' ./catch-up.sh
```

…exported:

```bash
export EREGISTER_INSTALL_BASE=/srv
sudo -E ./catch-up.sh
```

…or through a piped one-liner:

```bash
curl -fsSL <raw>/catch-up.sh | sudo EREGISTER_BAHMNI_PASS='…' bash -s -- --yes
```

## 9.1 Flags by script

### `install.sh`

| Flag | Variable | Default |
|---|---|---|
| `-y`, `--yes` | `EREGISTER_ASSUME_YES=1` | `0` |
| `--force` | — | off |
| `--install-dir DIR` | `EREGISTER_INSTALL_BASE` | `/var/lib` |
| `--target-ref REF[,…]` | `EREGISTER_TARGET_REF` | *(empty — per-repo defaults)* |
| `--no-concepts` | `EREGISTER_IMPORT_CONCEPTS=0` | `1` |
| `--no-db-backup` | `EREGISTER_DB_BACKUP=0` | `1` |
| `--no-forms` | — | *inert in this script* |
| `--no-color` | — | auto |
| `-h`, `--help` | — | — |

### `catch-up.sh`

| Flag | Variable | Default |
|---|---|---|
| `-y`, `--yes` | `EREGISTER_ASSUME_YES=1` | `0` |
| `--decode`, `--decode-only` | `EREGISTER_CATCHUP_DECODE_ONLY=1` | `0` |
| `--no-stack` | `EREGISTER_CATCHUP_STACK_REPO=0` | `1` |
| `--no-forms` | `EREGISTER_IMPORT_FORMS=0` | `1` |
| `--no-retire-forms` | `EREGISTER_FORM_RETIRE=0` | `1` |
| `--no-publish` | `EREGISTER_FORM_PUBLISH=0` | `1` |
| `--no-decode` | `EREGISTER_FORM_DECODE=0` | `1` |
| `--no-concepts` | `EREGISTER_CATCHUP_DB_CHECK=0` + `EREGISTER_CONCEPT_IMPORT=0` | `1` |
| `--no-reporting` | `EREGISTER_IMPORT_REPORTING=0` | `1` |
| `--no-idgen` | `EREGISTER_IDGEN_RETIRE=0` | `1` |
| `--no-db-backup` | `EREGISTER_DB_BACKUP=0` | `1` |
| `--no-compose-up` | `EREGISTER_CATCHUP_COMPOSE_UP=0` | `1` |
| `--pull-images` | `EREGISTER_CATCHUP_COMPOSE_PULL=1` | `0` |
| `--no-recreate` | `EREGISTER_CATCHUP_RECREATE=0` | `1` |
| `--force-repos` | `EREGISTER_CATCHUP_FORCE_REPOS=1` | `0` |
| `--install-dir DIR` | `EREGISTER_INSTALL_BASE` | `/var/lib` |
| `--no-color` | — | auto |

> [!NOTE]
> `--no-forms` implies `--no-decode`, `--no-retire-forms` **and** `--no-publish`.
> `--decode` and `--no-decode` together are an error.

### `import-concepts.sh`

| Flag | Meaning |
|---|---|
| `--schedule` | Install the daily job instead of importing now |
| `--yes`, `--install-dir DIR`, `--no-color`, `--help` | As above |

### `import-forms.sh`, `ocl-fix.sh`

`--yes`, `--install-dir DIR`, `--no-color`, `--help`.

## 9.2 Core

| Variable | Default | Meaning |
|---|---|---|
| `EREGISTER_INSTALL_BASE` | `/var/lib` | Install base; everything lives in `<base>/v1` |
| `EREGISTER_ASSUME_YES` | `0` | Non-interactive |
| `EREGISTER_TARGET_REF` | *(empty)* | Comma-separated ref preference list for every repo |
| `EREGISTER_LIB_DIR` | *(beside the script)* | Where to find `lib/` |
| `EREGISTER_RAW_BASE` | the repo's raw `main` URL | Where to fetch modules from |

## 9.3 The 0.92 source stack

| Variable | Default | Meaning |
|---|---|---|
| `EREGISTER_OLD_DOCKER_DIR` | `$HOME/bahmni_docker` | Where the 0.92 stack lives |
| `EREGISTER_EMR_CONTAINER` | `bahmni_docker-emr-service-1` | The 0.92 EMR container |
| `EREGISTER_EMR_CONTAINER_ALT` | `bahmni_docker_emr_service_1` | Fallback name |
| `EREGISTER_DB_NAME` | `openmrs` | Database to dump and restore |
| `EREGISTER_DB_USER` | `root` | Database user |
| `EREGISTER_DB_PASS` | *(prompted)* | Database password |

## 9.4 The v1 stack

| Variable | Default | Meaning |
|---|---|---|
| `EREGISTER_DB_SERVICE` | `openmrsdb` | Compose service hosting the database |
| `EREGISTER_EMR_SERVICE` | `openmrs` | Compose service hosting the EMR |
| `EREGISTER_REPORTS_SERVICE` | `reports` | Compose service for reports |
| `EREGISTER_OCL_DIR` | `/openmrs/data/configuration/ocl` | OCL dir *inside* the EMR service |

## 9.5 Repository refs

| Variable | Default |
|---|---|
| `EREGISTER_REF_BAHMNI_DOCKER` | `Bokang-changes` |
| `EREGISTER_REF_STANDARD_CONFIG` | `Bokang-changes` |
| `EREGISTER_REF_CONFIG_092` | `main` |
| `EREGISTER_REF_OPENMRS_MODULES` | `main` |
| `EREGISTER_REF_IMPL_INTERFACE` | `main` |
| `EREGISTER_REF_OBS_FORMS` | `main` |
| `EREGISTER_REF_DHIS_MAPPINGS` | `master` |
| `EREGISTER_REF_CONCEPTS` | `main` |
| `EREGISTER_REF_REPORTING` | `master` |
| `EREGISTER_UPGRADE_REPO` | `https://github.com/Lesotho-eRegister-v1/upgrade-to-v1` |
| `EREGISTER_UPGRADE_REF` | `main` |
| `EREGISTER_UPGRADE_REPO_DIR` | `<base>/v1/upgrade-to-v1` |

`EREGISTER_TARGET_REF` supersedes all of the per-repo refs.

## 9.6 Clinical forms

See [chapter 4](04-forms.md) for what each one does.

| Variable | Default |
|---|---|
| `EREGISTER_IMPORT_FORMS` | `1` |
| `EREGISTER_BAHMNI_URL` | `https://localhost` |
| `EREGISTER_BAHMNI_USER` | `superman` |
| `EREGISTER_BAHMNI_PASS` | *(prompted)* |
| `EREGISTER_FORMS_DIR` | `<base>/v1/clinical-obs-forms` |
| `EREGISTER_FORM_IMPORT_INSECURE` | `1` |
| `EREGISTER_FORM_IMPORT_SCRIPT` | `/usr/local/bin/bahmni-form-import.sh` |
| `EREGISTER_FORM_IMPORT_RUNNER` | `/usr/local/bin/eregister-form-import.sh` |
| `EREGISTER_FORM_IMPORT_ENV` | `/etc/eregister/form-import.env` |
| `EREGISTER_FORM_IMPORT_LOG` | `/var/log/eregister-form-import.log` |
| `EREGISTER_FORM_IMPORT_UNIT` | `eregister-form-import` |
| `EREGISTER_FORM_IMPORT_CRON` | `30 3 * * *` |
| `EREGISTER_FORM_IMPORT_ONCALENDAR` | `*-*-* 03:30:00` |
| `EREGISTER_FORM_IMPORT_SELF_PULL` | `1` |
| `EREGISTER_FORM_PUBLISH` | `1` |
| `EREGISTER_FORM_RETIRE` | `1` |
| `EREGISTER_FORM_RETIRE_NAME_LIKE` | `%2026%` |
| `EREGISTER_FORM_RETIRE_REASON` | `deploying latest forms with the latest changes - kgatman` |
| `EREGISTER_FORM_RETIRE_BY` | `1` |
| `EREGISTER_FORM_DECODE` | `1` |
| `EREGISTER_FORM_DECODE_DIR` | `/home/bahmni/clinical_forms` |
| `EREGISTER_FORM_DECODE_MAX_PASSES` | `5` |

## 9.7 Concept dictionary

| Variable | Default |
|---|---|
| `EREGISTER_IMPORT_CONCEPTS` | `1` |
| `EREGISTER_CONCEPTS_SQL_NAME` | *(empty — newest match wins)* |
| `EREGISTER_CONCEPTS_SQL_PATTERN` | `omrs_concept_dictionary*.sql` |
| `EREGISTER_CONCEPT_IMPORT` | `1` |
| `EREGISTER_CONCEPT_IMPORT_RUNNER` | `/usr/local/bin/eregister-concept-import.sh` |
| `EREGISTER_CONCEPT_IMPORT_LOG` | `/var/log/eregister-concept-import.log` |
| `EREGISTER_CONCEPT_IMPORT_UNIT` | `eregister-concept-import` |
| `EREGISTER_CONCEPT_IMPORT_CRON` | `30 4 * * *` |
| `EREGISTER_CONCEPT_IMPORT_ONCALENDAR` | `*-*-* 04:30:00` |
| `EREGISTER_CONCEPT_IMPORT_SELF_PULL` | `1` |
| `EREGISTER_CONCEPT_IMPORT_FIRST_RUN` | `1` |
| `EREGISTER_CONCEPT_IMPORT_FIRST_DELAY_SEC` | `10800` |
| `EREGISTER_CONCEPT_IMPORT_RESTART_EMR` | `0` |

## 9.8 Report definitions

| Variable | Default |
|---|---|
| `EREGISTER_IMPORT_REPORTING` | `1` |
| `EREGISTER_REPORTING_SQL_NAME` | *(empty — every match)* |
| `EREGISTER_REPORTING_SQL_PATTERN` | `*.sql` |

## 9.9 Identifier source

| Variable | Default |
|---|---|
| `EREGISTER_IDGEN_RETIRE` | `1` |
| `EREGISTER_IDGEN_RETIRE_ID` | `14` |
| `EREGISTER_IDGEN_RETIRE_REASON` | `No longer in use` |
| `EREGISTER_IDGEN_RETIRE_BY` | `1` |

## 9.10 Database backups

| Variable | Default |
|---|---|
| `EREGISTER_DB_BACKUP` | `1` |
| `EREGISTER_DB_BACKUP_DIR` | `<base>/v1/db-backups` |
| `EREGISTER_DB_BACKUP_RUNNER` | `/usr/local/bin/eregister-db-backup.sh` |
| `EREGISTER_DB_BACKUP_LOG` | `/var/log/eregister-db-backup.log` |
| `EREGISTER_DB_BACKUP_UNIT` | `eregister-db-backup` |
| `EREGISTER_DB_BACKUP_CRON` | `30 1 * * *` |
| `EREGISTER_DB_BACKUP_ONCALENDAR` | `*-*-* 01:30:00` |
| `EREGISTER_DB_BACKUP_KEEP` | `14` |
| `EREGISTER_DB_BACKUP_COMPRESS` | `1` |
| `EREGISTER_DB_BACKUP_FIRST_RUN` | `1` |

## 9.11 Auto-pull

| Variable | Default |
|---|---|
| `EREGISTER_AUTO_PULL` | `1` |
| `EREGISTER_AUTO_PULL_SCRIPT` | `/usr/local/bin/eregister-autopull.sh` |
| `EREGISTER_AUTO_PULL_LOG` | `/var/log/eregister-autopull.log` |
| `EREGISTER_AUTO_PULL_UNIT` | `eregister-autopull` |
| `EREGISTER_AUTO_PULL_CRON` | `30 2 * * *` |
| `EREGISTER_AUTO_PULL_ONCALENDAR` | `*-*-* 02:30:00` |

## 9.12 Catch-up behaviour

| Variable | Default |
|---|---|
| `EREGISTER_CATCHUP_STACK_REPO` | `1` |
| `EREGISTER_CATCHUP_DB_CHECK` | `1` |
| `EREGISTER_CATCHUP_DECODE_ONLY` | `0` |
| `EREGISTER_CATCHUP_COMPOSE_UP` | `1` |
| `EREGISTER_CATCHUP_COMPOSE_PULL` | `0` |
| `EREGISTER_CATCHUP_RECREATE` | `1` |
| `EREGISTER_CATCHUP_FORCE_REPOS` | `0` |
| `EREGISTER_CATCHUP_HTTP_TIMEOUT` | `15` |
