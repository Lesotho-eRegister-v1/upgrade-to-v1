curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/install.sh | bash
lib/ not found locally — fetching the modules …
Modules obtained by cloning https://github.com/Lesotho-eRegister-v1/upgrade-to-v1.

  ┌────────────────────────────────────────────────────────────┐
  │                                                            │
  │     ███  eRegister Lesotho — Upgrade to v1                 │
  │                                                            │
  │     ⏳  Initializing migration…………                         │
  │     🔍  Checking prerequisites…….                          │
  │     ✨  Doing the magic………                                 │
  │                                                            │
  └────────────────────────────────────────────────────────────┘

[ℹ] Elevation required for /var/lib; will use sudo.

==> Resolved configuration
  App            : eRegister Lesotho
  Time           : 2026-09-12 22:31:31 (SAST)
  Current ver    : none
  Target ver     : v1
  Ref override   : (none — using the per-repo defaults below)
  Default refs   : docker=Bokang-changes  config=Bokang-changes  092=main
                   modules=main  impl-interface=main  obs-forms=main
  OS / Arch      : linux / amd64
  Pkg manager    : apt-get
  Install base   : /var/lib
  v1 dir         : /var/lib/v1
  eRegister_HOME : /var/lib/v1
  Concept dict   : /var/lib/v1/eregister_concepts_release_v1/omrs_concept_dictionary*.sql (newest) -> openmrsdb:openmrs
  Concept job    : first run ~3h after install, then daily 30 4 * * * -> /usr/local/bin/eregister-concept-import.sh
  Report defs    : /var/lib/v1/openmrs_reporting_release (cloned here; imported by ./catch-up.sh)
  Clinical forms : /var/lib/v1/clinical-obs-forms (cloned here; imported by ./catch-up.sh)
  DB backup      : openmrsdb:openmrs -> /var/lib/v1/db-backups (daily: 30 1 * * *, keep 14)
  Old stack      : /home/kgatman/bahmni_docker
  EMR container  : bahmni_docker-emr-service-1
  Privilege      : sudo
  Non-interactive: no
[⚠] Cautious mode: you will be asked to confirm EVERY step before it runs.
[⚠] Answer 'n' at any prompt to stop safely (with rollback if the old stack
[⚠] has already been frozen). Anything that is neither a yes nor a no is
[⚠] treated as a slip: the prompt asks whether you meant to stop, and repeats
[⚠] itself if you did not. Use --yes to auto-confirm all steps.
Begin the upgrade 0.92 -> v1? [y/N]: y
Next step: Check for, and install if missing, required dependencies (git, docker, …) — proceed? [y/N]: y
[✔] All dependencies present.
Next step: Create the temp workspace and the v1 folders under /var/lib — proceed? [y/N]: y
[ℹ] Working dir: /tmp/eregister-v1.69PQ5v

==> Preparing directories
[ℹ] v1 folder already exists: /var/lib/v1
[ℹ] bahmni-backup folder already exists: /var/lib/v1/bahmni-backup

==> Backup
[✔] Reusing the backup already in /var/lib/v1/bahmni-backup:
[✔]   /var/lib/v1/bahmni-backup/openmrsdb_backup.sql (299M)
[ℹ] The restore below loads THIS file. To retake it instead, re-run with
[ℹ] --force while the 0.92 EMR container is running.

==> Migration
Next step: Freeze (stop, not remove) the running 0.92 stack at /home/kgatman/bahmni_docker — proceed? [y/N]:
[⚠] Step declined by user: Freeze (stop, not remove) the running 0.92 stack at /home/kgatman/bahmni_docker
[✘] Upgrade aborted by user before completion. No further changes made.
kgatman@inyenius-linuxius-maxiamus:~$ ls
 Botha_Bothe_Hosp_04_07_2025.sql        Public                                 Videos                    dhis2-core           node_modules           snap
 Desktop                                PycharmProjects                        'VirtualBox VMs'          dhis2-server-tools   oasistv                ubuntu-20.04.6-desktop-amd64.iso
 Documents                              R                                      bahmniDev                 h2o-3.46.0.9         openclaw-workspace     v1
 Downloads                              Templates                              cag-1.0.3-SNAPSHOT.omod   h2o-3.46.0.9.zip     openmrsdb_backup.sql
 Leseli_Mediclinic_emr_24_03_2026.sql  'The Introduction of Firestz.osp'       chap-core                 install.log          package-lock.json
 Music                                  'The Introduction of Firestz_assets'   chap.log                  install.sh           package.json
 Pictures                               Untitled.blend                         composelogs.txt           make.log             projects
kgatman@inyenius-linuxius-maxiamus:~$ docker ps
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
kgatman@inyenius-linuxius-maxiamus:~$ curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/install.sh | bash
lib/ not found locally — fetching the modules …
Modules obtained by cloning https://github.com/Lesotho-eRegister-v1/upgrade-to-v1.

  ┌────────────────────────────────────────────────────────────┐
  │                                                            │
  │     ███  eRegister Lesotho — Upgrade to v1                 │
  │                                                            │
  │     ⏳  Initializing migration…………                         │
  │     🔍  Checking prerequisites…….                          │
  │     ✨  Doing the magic………                                 │
  │                                                            │
  └────────────────────────────────────────────────────────────┘

[ℹ] Elevation required for /var/lib; will use sudo.

==> Resolved configuration
  App            : eRegister Lesotho
  Time           : 2026-09-12 22:32:08 (SAST)
  Current ver    : none
  Target ver     : v1
  Ref override   : (none — using the per-repo defaults below)
  Default refs   : docker=Bokang-changes  config=Bokang-changes  092=main
                   modules=main  impl-interface=main  obs-forms=main
  OS / Arch      : linux / amd64
  Pkg manager    : apt-get
  Install base   : /var/lib
  v1 dir         : /var/lib/v1
  eRegister_HOME : /var/lib/v1
  Concept dict   : /var/lib/v1/eregister_concepts_release_v1/omrs_concept_dictionary*.sql (newest) -> openmrsdb:openmrs
  Concept job    : first run ~3h after install, then daily 30 4 * * * -> /usr/local/bin/eregister-concept-import.sh
  Report defs    : /var/lib/v1/openmrs_reporting_release (cloned here; imported by ./catch-up.sh)
  Clinical forms : /var/lib/v1/clinical-obs-forms (cloned here; imported by ./catch-up.sh)
  DB backup      : openmrsdb:openmrs -> /var/lib/v1/db-backups (daily: 30 1 * * *, keep 14)
  Old stack      : /home/kgatman/bahmni_docker
  EMR container  : bahmni_docker-emr-service-1
  Privilege      : sudo
  Non-interactive: no
[⚠] Cautious mode: you will be asked to confirm EVERY step before it runs.
[⚠] Answer 'n' at any prompt to stop safely (with rollback if the old stack
[⚠] has already been frozen). Anything that is neither a yes nor a no is
[⚠] treated as a slip: the prompt asks whether you meant to stop, and repeats
[⚠] itself if you did not. Use --yes to auto-confirm all steps.
Begin the upgrade 0.92 -> v1? [y/N]: y
Next step: Check for, and install if missing, required dependencies (git, docker, …) — proceed? [y/N]: y
[✔] All dependencies present.
Next step: Create the temp workspace and the v1 folders under /var/lib — proceed? [y/N]: y
[ℹ] Working dir: /tmp/eregister-v1.qeXkeF

==> Preparing directories
[ℹ] v1 folder already exists: /var/lib/v1
[ℹ] bahmni-backup folder already exists: /var/lib/v1/bahmni-backup

==> Backup
[✔] Reusing the backup already in /var/lib/v1/bahmni-backup:
[✔]   /var/lib/v1/bahmni-backup/openmrsdb_backup.sql (299M)
[ℹ] The restore below loads THIS file. To retake it instead, re-run with
[ℹ] --force while the 0.92 EMR container is running.

==> Migration
Next step: Freeze (stop, not remove) the running 0.92 stack at /home/kgatman/bahmni_docker — proceed? [y/N]: y

[ℹ] Shutting down eRegister Lesotho 0.92
[⚠] No docker-compose.yml at /home/kgatman/bahmni_docker; nothing to shut down.
Next step: Clone the v1 source repos, asset repos and 0.92 config into /var/lib/v1 — proceed? [y/N]: y

==> Fetching v1 sources
[ℹ] Repo exists, updating: /var/lib/v1/bahmni-docker-ls @ Bokang-changes
remote: Total 0 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)
From https://github.com/Lesotho-eRegister-v1/bahmni-docker-ls
 * branch            Bokang-changes -> FETCH_HEAD
Already on 'Bokang-changes'
Your branch is up to date with 'origin/Bokang-changes'.
HEAD is now at 32da449 fixing the Implementer Interface mount; curtesty of ntate @petershale21
[✔] Ready: /var/lib/v1/bahmni-docker-ls @ Bokang-changes (32da449)
[ℹ] Repo exists, updating: /var/lib/v1/standard-config-ls @ Bokang-changes
remote: Total 0 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)
From https://github.com/Lesotho-eRegister-v1/standard-config-ls
 * branch            Bokang-changes -> FETCH_HEAD
Already on 'Bokang-changes'
Your branch is up to date with 'origin/Bokang-changes'.
HEAD is now at df72b65 Merge pull request #9 from jobo-R/HTS_Fixes
[✔] Ready: /var/lib/v1/standard-config-ls @ Bokang-changes (df72b65)

[⚠] The openmrs-v1-modules repo is ~246 MB, so this step will pause here for a while on a slow connection. This is expected — let it run.

[ℹ] Repo exists, updating: /var/lib/v1/openmrs-v1-modules @ main
remote: Total 0 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)
From https://github.com/Lesotho-eRegister-v1/openmrs-v1-modules
 * branch            main       -> FETCH_HEAD
Already on 'main'
Your branch is up to date with 'origin/main'.
HEAD is now at a7d55b5 1.5.5
[✔] Ready: /var/lib/v1/openmrs-v1-modules @ main (a7d55b5)
[ℹ] Repo exists, updating: /var/lib/v1/implementer-interface-release @ main
remote: Total 0 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)
From https://github.com/Lesotho-eRegister-v1/implementer-interface-release
 * branch            main       -> FETCH_HEAD
Already on 'main'
Your branch is up to date with 'origin/main'.
HEAD is now at b377498 Merge pull request #1 from Lesotho-eRegister-v1/refactor/import-logic
[✔] Ready: /var/lib/v1/implementer-interface-release @ main (b377498)
[ℹ] Repo exists, updating: /var/lib/v1/clinical-obs-forms @ main
remote: Total 0 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)
From https://github.com/Lesotho-eRegister-v1/clinical-obs-forms
 * branch            main       -> FETCH_HEAD
Already on 'main'
Your branch is up to date with 'origin/main'.
HEAD is now at 18758c6 11 Sept 2026
[✔] Ready: /var/lib/v1/clinical-obs-forms @ main (18758c6)
[ℹ] Repo exists, updating: /var/lib/v1/dhisconnector_mappings_v1 @ master
remote: Total 0 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)
From https://github.com/Lesotho-eRegister-v1/dhisconnector_mappings_v1
 * branch            master     -> FETCH_HEAD
Already on 'master'
Your branch is up to date with 'origin/master'.
HEAD is now at b3d68e7 adding standard naming
[✔] Ready: /var/lib/v1/dhisconnector_mappings_v1 @ master (b3d68e7)
[ℹ] Repo exists, updating: /var/lib/v1/eregister_concepts_release_v1 @ main
remote: Total 0 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)
From https://github.com/Lesotho-eRegister-v1/eregister_concepts_release_v1
 * branch            main       -> FETCH_HEAD
Already on 'main'
Your branch is up to date with 'origin/main'.
HEAD is now at f4894ba 20260804
[✔] Ready: /var/lib/v1/eregister_concepts_release_v1 @ main (f4894ba)
[ℹ] Repo exists, updating: /var/lib/v1/openmrs_reporting_release @ master
remote: Total 0 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)
From https://github.com/Lesotho-eRegister-v1/openmrs_reporting_release
 * branch            master     -> FETCH_HEAD
Already on 'master'
Your branch is up to date with 'origin/master'.
HEAD is now at c4e79f7 fixing CITC automated reports
[✔] Ready: /var/lib/v1/openmrs_reporting_release @ master (c4e79f7)
[ℹ] Repo exists, updating: /var/lib/v1/bahmni-backup/bahmni_config @ main
remote: Total 0 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)
From https://github.com/eRegister/bahmni_config092
 * branch            main       -> FETCH_HEAD
Already on 'main'
Your branch is up to date with 'origin/main'.
HEAD is now at 30a2b10 Merge pull request #314 from mzntlamelle/patch-18
[✔] Ready: /var/lib/v1/bahmni-backup/bahmni_config @ main (30a2b10)
Next step: Run restore_bahmni_standard.sh to load the backup into the v1 stack — proceed? [y/N]: y

==> Restoring data into v1
[ℹ] Running restore (this can take a while)…
INFO - Starting Database Restore...
INFO - Initializing mysql Restore for database: openmrs
INFO - Starting openmrsdb Container
[+] up 4/4
 ✔ Network bahmni-standard_default                Created                                                                                                                              0.1s
 ✔ Volume bahmni-standard_configuration_checksums Created                                                                                                                              0.0s
 ✔ Volume bahmni-standard_openmrsdbdata           Created                                                                                                                              0.0s
 ✔ Container bahmni-standard-openmrsdb-1          Created                                                                                                                              0.1s
INFO - Waiting for openmrsdb container to initialise
mysql: [Warning] Using a password on the command line interface can be insecure.
INFO - Starting MySQL Restore for database: openmrs
mysql: [Warning] Using a password on the command line interface can be insecure.
INFO - Initializing mysql Restore for database: bahmni_reports
WARN - DB backup file for bahmni_reports not found at /var/lib/v1/bahmni-backup/reportsdb_backup.sql. Skipping restore
INFO - Initializing postgres Restore for database: clinlims
WARN - DB backup file for clinlims not found at /var/lib/v1/bahmni-backup/openelisdb_backup.sql. Skipping restore
INFO - Initializing postgres Restore for database: odoo
WARN - DB backup file for odoo not found at /var/lib/v1/bahmni-backup/odoodb_backup.sql. Skipping restore
INFO - Initializing postgres Restore for database: odoo
WARN - DB backup file for odoo not found at /var/lib/v1/bahmni-backup/odoo_10_db_backup.sql. Skipping restore
INFO - Initializing postgres Restore for database: pacs_db
WARN - DB backup file for pacs_db not found at /var/lib/v1/bahmni-backup/dcm4cheedb_backup.sql. Skipping restore
INFO - Initializing postgres Restore for database: pacs_integration_db
WARN - DB backup file for pacs_integration_db not found at /var/lib/v1/bahmni-backup/pacs_integrationdb_backup.sql. Skipping restore
INFO - Starting File System Restore...
[+] up 7/7
 ✔ Volume bahmni-standard_bahmni-patient-images  Created                                                                                                                               0.0s
 ✔ Volume bahmni-standard_bahmni-document-images Created                                                                                                                               0.0s
 ✔ Volume bahmni-standard_bahmni-lab-results     Created                                                                                                                               0.0s
 ✔ Volume bahmni-standard_bahmni-queued-reports  Created                                                                                                                               0.0s
 ✔ Volume bahmni-standard_bahmni-uploaded-files  Created                                                                                                                               0.0s
 ✔ Volume bahmni-standard_dcm4chee-archive       Created                                                                                                                               0.0s
 ✔ Container bahmni-standard-restore_volumes-1   Created                                                                                                                               0.1s
Attaching to restore_volumes-1
restore_volumes-1  | INFO - Starting File System Restore into volume mounts....
restore_volumes-1  | ERROR - Source directory for patient_images does not exist or is empty. So skipping restore for patient_images.
restore_volumes-1  | ERROR - Source directory for document_images does not exist or is empty. So skipping restore for document_images.
restore_volumes-1  | ERROR - Source directory for clinical_forms does not exist or is empty. So skipping restore for clinical_forms.
restore_volumes-1  | ERROR - Source directory for configuration_checksums does not exist or is empty. So skipping restore for configuration_checksums.
restore_volumes-1  | ERROR - Source directory for uploaded_results does not exist or is empty. So skipping restore for uploaded_results.
restore_volumes-1  | ERROR - Source directory for reports does not exist or is empty. So skipping restore for reports.
restore_volumes-1  | ERROR - Source directory for uploaded-files does not exist or is empty. So skipping restore for uploaded-files.
restore_volumes-1  | ERROR - Source directory for dcm4chee_archive does not exist or is empty. So skipping restore for dcm4chee_archive.
restore_volumes-1  | INFO - -e
restore_volumes-1 exited with code 0
Going to remove bahmni-standard-restore_volumes-1
[+] remove 1/1
 ✔ Container bahmni-standard-restore_volumes-1 Removed                                                                                                                                 0.0s
[✔] Restore completed.
Next step: Start eRegister v1 via run-bahmni.sh (falls back to 'docker compose up -d' on error) — proceed? [y/N]: y

==> Starting eRegister v1
[ℹ] Launching via run-bahmni.sh…
Docker version >= 20.10.13, using Docker Compose V2
Docker Compose version: Docker Compose version v5.0.2
---
bahmni-standard
Please select an option:
------------------------
1) START Bahmni services
2) STOP  Bahmni services
3) LOGS: Show OpenMRS Logs
4) LOGS: Show LOGS of a service
5) SSH into a Container
6) START Bahmni Analytics (Mart and Metabase)
7) PULL latest images from Docker hub for Bahmni
8) RESET and ERASE All Volumes/Databases from docker!
9) RESTART a service
0) STATUS of all services
-------------------------
Invalid option selected
[✔] eRegister v1 started via run-bahmni.sh.
[ℹ] Starting the reports service (reports)…
[+] up 5/5
 ✔ Volume bahmni-standard_reportsdbdata   Created                                                                                                                                      0.0s
 ✔ Container bahmni-standard-reportsdb-1  Created                                                                                                                                      0.1s
 ✔ Container bahmni-standard-bahmni-web-1 Created                                                                                                                                      0.1s
 ✔ Container bahmni-standard-openmrsdb-1  Running                                                                                                                                      0.0s
 ✔ Container bahmni-standard-reports-1    Created                                                                                                                                      0.1s
[✔] Reports service 'reports' started.
Next step: Run post-install verification and finalize the upgrade — proceed? [y/N]: y

==> Post-install verification
[✔] eRegister_HOME persisted to /etc/profile.d/eregister.sh (takes effect in new login shells).
[✔] Verification passed.

==> Scheduling the daily database backup
[ℹ] The job runs daily (30 1 * * *) and, in one run:
[ℹ]   • dumps 'openmrs' from the openmrsdb service (consistent snapshot,
[ℹ]     no locking — the site keeps working while it runs)
[ℹ]   • gzips it to /var/lib/v1/db-backups/openmrs_<stamp>.sql.gz
[ℹ]   • verifies the dump is complete before keeping it
[ℹ]   • deletes all but the newest 14 dumps
[ℹ] It runs BEFORE the nightly repo pull, form import and concept import, so
[ℹ] each dump is of the database as it stood before any of them ran.
[⚠] These dumps live on the SAME machine as the database. That covers a bad
[⚠] import or a deleted patient; it does NOT cover the disk or the server
[⚠] dying. Copy /var/lib/v1/db-backups off this host as well.
Install the daily database backup? [y/N]: y
[✔] database backup folder ready: /var/lib/v1/db-backups
[✔] Installed database backup script: /usr/local/bin/eregister-db-backup.sh (mode 0755)
Created symlink '/etc/systemd/system/timers.target.wants/eregister-db-backup.timer' → '/etc/systemd/system/eregister-db-backup.timer'.
[✔] systemd timer enabled: eregister-db-backup.timer (OnCalendar=*-*-* 01:30:00)
[ℹ] Status: systemctl status eregister-db-backup.timer   Run now: systemctl start eregister-db-backup.service
[ℹ] Taking a database backup now (log: /var/log/eregister-db-backup.log) …
[✔] Database backup written under /var/lib/v1/db-backups.
2026-09-12T22:35:45+0200 DUMP  openmrsdb:openmrs -> openmrs_20260912_223545.sql.gz
2026-09-12T22:35:45+0200 DISK  533G free on /
mysqldump: [Warning] Using a password on the command line interface can be insecure.
2026-09-12T22:35:51+0200 OK    openmrs_20260912_223545.sql.gz (57M)
2026-09-12T22:35:51+0200 KEEP  1 dump(s) retained (limit 14)
2026-09-12T22:35:51+0200 === db backup run end (rc=0) ===
[ℹ] Run one by hand at any time:  sudo /usr/local/bin/eregister-db-backup.sh   (log: /var/log/eregister-db-backup.log)
[ℹ] Restore one with:
[ℹ]   gzip -dc /var/lib/v1/db-backups/latest.sql.gz | (cd /var/lib/v1/bahmni-docker-ls/bahmni-standard && docker compose exec -T openmrsdb mysql -uroot -p)

==> Scheduling the concept-dictionary import
[ℹ] The job runs daily (30 4 * * *) and, in one run:
[ℹ]   • fast-forwards /var/lib/v1/eregister_concepts_release_v1
[ℹ]   • picks the newest omrs_concept_dictionary*.sql in it
[ℹ]   • imports it into openmrsdb:openmrs — ONLY if its content changed
[ℹ] It is separate from the daily form import, and leaves it untouched.
[ℹ] Nothing is imported right now: the instance has only just been started
[ℹ] and needs hours to finish booting. The FIRST import is scheduled for
[ℹ] ~3h from now, and the daily job carries on from there.
[⚠] An import replaces the concept_*/drug* tables (a pre-import backup is taken
[⚠] first), and the new dictionary is only visible once the EMR restarts.
Install the scheduled concept-dictionary import? [y/N]: y
[ℹ] The scheduled import needs a local checkout of this repo — cloning into /var/lib/v1/upgrade-to-v1
[ℹ] Cloning https://github.com/Lesotho-eRegister-v1/upgrade-to-v1 @ main -> /var/lib/v1/upgrade-to-v1
Cloning into '/var/lib/v1/upgrade-to-v1'...
remote: Enumerating objects: 38, done.
remote: Counting objects: 100% (38/38), done.
remote: Compressing objects: 100% (36/36), done.
remote: Total 38 (delta 1), reused 13 (delta 0), pack-reused 0 (from 0)
Receiving objects: 100% (38/38), 123.61 KiB | 492.00 KiB/s, done.
Resolving deltas: 100% (1/1), done.
[✔] Ready: /var/lib/v1/upgrade-to-v1 @ main (30e626b)
[✔] Installed concept-import runner: /usr/local/bin/eregister-concept-import.sh
Created symlink '/etc/systemd/system/timers.target.wants/eregister-concept-import.timer' → '/etc/systemd/system/eregister-concept-import.timer'.
[✔] systemd timer enabled: eregister-concept-import.timer (OnCalendar=*-*-* 04:30:00)
[✔] First concept import scheduled for ~2026-09-13 01:35 SAST.
[ℹ]   Check:  systemctl list-timers eregister-concept-import-first.timer
[ℹ]   Cancel: sudo systemctl stop eregister-concept-import-first.timer
[ℹ]   Log:    /var/log/eregister-concept-import.log
[⚠] It is a transient timer: a reboot before then drops it, and the
[⚠] daily job (30 4 * * *) becomes the first import instead.
[ℹ] After an import the job logs that openmrs needs a restart; it does not
[ℹ] restart it (set EREGISTER_CONCEPT_IMPORT_RESTART_EMR=1 to change that).
[ℹ] Run it now with: sudo /usr/local/bin/eregister-concept-import.sh   (log: /var/log/eregister-concept-import.log)
Install the auto-update job that periodically pulls the v1 asset/config repos? [y/N]: y

==> Scheduling automatic updates for the v1 repos
[ℹ] Repos kept in sync with their remotes:
[ℹ]   • /var/lib/v1/standard-config-ls
[ℹ]   • /var/lib/v1/implementer-interface-release
[ℹ]   • /var/lib/v1/openmrs-v1-modules
[ℹ]   • /var/lib/v1/clinical-obs-forms
[ℹ]   • /var/lib/v1/dhisconnector_mappings_v1
[ℹ]   • /var/lib/v1/eregister_concepts_release_v1
[ℹ]   • /var/lib/v1/openmrs_reporting_release
[✔] Installed updater script: /usr/local/bin/eregister-autopull.sh
Created symlink '/etc/systemd/system/timers.target.wants/eregister-autopull.timer' → '/etc/systemd/system/eregister-autopull.timer'.
[✔] systemd timer enabled: eregister-autopull.timer (OnCalendar=*-*-* 02:30:00)
[ℹ] Status: systemctl status eregister-autopull.timer   Run now: systemctl start eregister-autopull.service

══════════════════════════════════════════════════════════════
 ✔ eRegister Lesotho upgraded to v1
══════════════════════════════════════════════════════════════

  Install dir : /var/lib/v1
  DB backup   : /var/lib/v1/bahmni-backup/openmrsdb_backup.sql (299M)
  v1 stack    : /var/lib/v1/bahmni-docker-ls
  Environment : eRegister_HOME=/var/lib/v1 (persisted in /etc/profile.d/eregister.sh)

  The v1 stack has been started (run-bahmni.sh, or 'docker compose up -d').

  What to do next:
    1. cd /var/lib/v1/bahmni-docker-ls/bahmni-standard
    2. Confirm services are healthy:
         docker compose ps
    3. If anything is down, bring it up with:
         docker compose up -d
    4. After the instance is FULLY up and the OCL import has finished
       (~30+ min), apply the OCL concept-name fix (run once):
         curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/ocl-fix.sh | bash
       (or, from the upgrade repo:  ./ocl-fix.sh)
    5. Once verified, the old install in /home/kgatman/bahmni_docker can be archived.

  Concept dictionary:
    newest omrs_concept_dictionary*.sql in /var/lib/v1/eregister_concepts_release_v1
    has NOT been imported yet, and that is deliberate — the instance
    needs hours to finish booting first. The FIRST import runs on its own
    ~3h from now; import it sooner with ./import-concepts.sh if you want.
    From here on it keeps itself current: eregister-concept-import runs daily
    (30 4 * * *) via /usr/local/bin/eregister-concept-import.sh, pulls the concepts
    repo and imports a dump ONLY when its content has changed.
    Check now:   sudo /usr/local/bin/eregister-concept-import.sh
    Log:         /var/log/eregister-concept-import.log
    Import by hand at any time:
         curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/import-concepts.sh | bash
       (or, from the upgrade repo:  ./import-concepts.sh)
    NOTE: OpenMRS caches concepts — the EMR must restart before a newly
    imported dictionary is visible. The job logs this; it does not restart it.

  Report definitions:
    /var/lib/v1/openmrs_reporting_release
    Cloned, not imported: the database is minutes old at this point. The
    catch-up script loads them into 'openmrs' (one table, serialized_object,
    dumped to /var/lib/v1/bahmni-backup first) and skips the work when they are already in:
         curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/catch-up.sh | bash
       (or, from the upgrade repo:  ./catch-up.sh)

  Clinical observation forms:
    /var/lib/v1/clinical-obs-forms
    are cloned but NOT imported, and nothing is scheduled to import
    them: /usr/local/bin/eregister-form-import.sh does not exist yet. The catch-up script
    installs it and does the first import, once the EMR is answering —
    into https://localhost as 'superman', daily at 30 3 * * * thereafter.
    Only forms whose content changed are deployed, and a changed form goes out
    as a NEW version — the live one is never overwritten.
    Set it up and import (do this once the EMR answers — 30+ min from now):
         curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/catch-up.sh | bash
       (or, from the upgrade repo:  ./catch-up.sh)
    Forms only, without the rest of the catch-up:
         curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/import-forms.sh | bash
       (or, from the upgrade repo:  ./import-forms.sh)
    Once installed —
    Import now:  sudo /usr/local/bin/eregister-form-import.sh
    Log:         /var/log/eregister-form-import.log
    State:       /var/lib/v1/.bahmni_form_import_state.json
    Credentials: /etc/eregister/form-import.env (mode 0600)

  Database backups:
    The 'openmrs' database in the openmrsdb service
    is dumped nightly at 30 1 * * * by
    /usr/local/bin/eregister-db-backup.sh
    (systemd: eregister-db-backup.timer, or /etc/cron.d/eregister-db-backup), keeping the newest 14.
    Dumps:       /var/lib/v1/db-backups/openmrs_<stamp>.sql.gz  (newest: latest.sql.gz)
    Take one:    sudo /usr/local/bin/eregister-db-backup.sh
    Log:         /var/log/eregister-db-backup.log
    Restore one: gzip -dc /var/lib/v1/db-backups/latest.sql.gz \
                   | (cd /var/lib/v1/bahmni-docker-ls/bahmni-standard && docker compose exec -T openmrsdb mysql -uroot -p)
    A dump that mysqldump did not finish writing is never kept — it is left as
    a .part file and the run is logged as a failure, so a truncated backup can
    never quietly take the place of a good one.
    ⚠ These dumps are on the SAME disk as the database. They undo a bad
    import or a deleted record; they do NOT survive losing this machine.
    Copy /var/lib/v1/db-backups to somewhere else as well.

  Auto-updates:
    The asset/config repos
    (standard-config-ls, implementer-interface-release, openmrs-v1-modules,
    clinical-obs-forms, dhisconnector_mappings_v1,
    eregister_concepts_release_v1, openmrs_reporting_release)
    are pulled on a schedule by /usr/local/bin/eregister-autopull.sh
    (systemd: eregister-autopull.timer, or /etc/cron.d/eregister-autopull).
    Run a sync now:  /usr/local/bin/eregister-autopull.sh
    Log:             /var/log/eregister-autopull.log

  Re-running this script is safe (idempotent). Use --force to redo a
  completed upgrade. To pick up later changes to these scripts without a full
  re-run, use the catch-up script instead — it reconciles the repos, helpers and
  scheduled jobs in place, reports on service health, and reloads the EMR
  service at the end (--no-recreate to leave even that alone):
       curl -fsSL https://raw.githubusercontent.com/Lesotho-eRegister-v1/upgrade-to-v1/refs/heads/main/catch-up.sh | bash
     (or, from the upgrade repo:  ./catch-up.sh)

  ⚠ Please wait ~30+ minutes before using eRegister. The v1 services
    need time to fully start up, and this can take considerably longer
    depending on the server hardware hosting eRegister.
[✔] Done.