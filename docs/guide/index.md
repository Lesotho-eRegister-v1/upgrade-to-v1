---
title: "eRegister Lesotho — v1 Upgrade Toolkit"
subtitle: "Operations and reference guide"
---

# eRegister Lesotho — v1 Upgrade Toolkit

This guide documents the scripts that take an eRegister (Bahmni) site from
**0.92 to v1**, and that keep a v1 site current afterwards.

eRegister is an EMR built on Bahmni. The toolkit lives in the
`upgrade-to-v1` repository and is designed to be run either from a checkout or
straight off the network with `curl … | bash`.

## The three things you will actually run

| Script | When | What it does |
|---|---|---|
| `install.sh` | **Once**, to move a site from 0.92 to v1 | Backs up the old database, freezes the 0.92 stack, clones the v1 sources, restores the data, starts v1, installs the scheduled jobs |
| `catch-up.sh` | **Repeatedly**, on a live v1 site | Reconciles the site against the current release: repos, helper scripts, scheduled jobs, forms, report definitions — then applies the compose files and reloads the EMR |
| `ocl-fix.sh` | **Once**, ~30+ minutes after v1 first starts | Undoes the concept-name changes OCL makes during its first import |

Three smaller helpers do one job each, and are covered where that job is
documented:

- `import-forms.sh` — the clinical form import, on its own
- `import-concepts.sh` — the concept dictionary, on its own
- `bin/bahmni_form_import.sh` — the form importer itself (installed by the above)

> [!CAUTION]
> **The single most important rule in this guide:** once a site is on v1, do
> **not** re-run `install.sh` to pick up changes. It freezes the stack, restores
> a backup and restarts everything. Run `catch-up.sh` instead.

## Quick start

Upgrade a 0.92 site:

```bash
curl -fsSL --retry 8 --retry-max-time 180 \
  https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/install.sh \
  | sudo bash
```

Reconcile a live v1 site:

```bash
curl -fsSL --retry 8 --retry-max-time 180 \
  https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/catch-up.sh \
  | sudo bash
```

Both are safe to run from a git checkout instead:

```bash
git clone https://github.com/Lesotho-eRegister-v1/upgrade-to-v1
cd upgrade-to-v1
sudo ./install.sh          # or: sudo ./catch-up.sh
```

## How to read this guide

| Chapter | Read it when |
|---|---|
| [1. Architecture and layout](01-architecture.md) | You want to know where things live on disk and how the scripts are put together |
| [2. The upgrade: `install.sh`](02-upgrade.md) | You are moving a site from 0.92 to v1 |
| [3. Reconciling a live site: `catch-up.sh`](03-catch-up.md) | You are keeping a v1 site current — the chapter you will re-read most |
| [4. Clinical observation forms](04-forms.md) | Forms are missing, stale, escaped, or need retiring |
| [5. The concept dictionary](05-concepts.md) | Concepts are missing or a new dictionary has been released |
| [6. OpenMRS report definitions](06-reporting.md) | The Reports app is missing reports |
| [7. Database backups](07-backups.md) | You need to take, verify or restore a dump |
| [8. Scheduled jobs](08-scheduled-jobs.md) | A nightly job is not running, or you want to change a schedule |
| [9. Configuration reference](09-configuration.md) | You need the exact name of a flag or environment variable |
| [10. Operations runbook](10-runbook.md) | You want a worked example for a specific task |
| [11. Troubleshooting](11-troubleshooting.md) | Something failed and you need to know what it means |

## Conventions used in this guide

- `<base>` is the install base, `/var/lib` unless `--install-dir` says otherwise.
  Everything the toolkit creates lives under `<base>/v1`.
- Commands shown with `sudo` need root. The scripts detect this themselves and
  will use `sudo` where required, so running them without it is also fine
  provided the invoking user can `sudo` without a password prompt mid-run.
- Where a step can be skipped, the flag that skips it is named inline.
- Output samples are real, and are shown without the ANSI colour the scripts
  actually print.
