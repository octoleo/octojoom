# Backups and restore points

Open **Joomla Containers → Website Information → select a website → Backups and restore points**. **Back up websites** in the Joomla menu runs the same backup operation for selected or all sites, asking shared options once.

Existing sites need no registration or additional project metadata. Backup preferences use the selected site's existing environment settings. Establishing a private site environment preserves its required Compose values and recognized settings; unrelated sites' credentials are excluded.

## Contents and formats

| Scope | Contents | Restore into an existing site |
| --- | --- | --- |
| `full` | Website storage, logical SQL, selected Compose, scoped environment and referenced site/project configuration | Restores deployment configuration as well as files and SQL; archive must belong to that site's identity |
| `website` | Website/document-root storage plus logical SQL, with the deployment recipe needed for an independent restore | Keeps destination deployment settings and patches the restored application's database connection |
| `database` | Logical SQL and database identity/prefix | Imports into fresh database storage and retains destination website content |
| `files` | Website storage; explicitly excludes SQL | Keeps destination database and connection configuration |

`full` and `website` can restore into a new independent site. Database-only and files-only archives require an explicitly selected existing destination. A website export includes SQL; it is not a files-only export.

Both `tar.gz` and `zip` use the existing `manifest.env`, `compose/`, `project/` package family. Format 2 records logical payload type, scope, selected site, database family, creation time and label. Validated file metadata records modes and numeric ownership for ZIP as well as tar. Internal file hashes detect missing or altered payloads; an adjacent `.sha256` file records the completed archive's transport digest.

Format-1 cold migration archives remain readable and restore through the existing migration importer. Their raw database storage retains the original exact-engine/image and architecture limitations. They are not cross-engine SQL archives.

## Creating backups

```bash
octojoom --type joomla --task backup --container demo.example.test \
  --action create --scope full --format tar.gz --label before-change \
  --destination /backups --timestamp yes --overwrite no \
  --non-interactive --output json

octojoom --type joomla --task backup --container first.example.test \
  --container second.example.test --action create --scope website \
  --format zip --destination /backups --non-interactive --output json

octojoom --type joomla --task backup --all --action create \
  --destination /backups --non-interactive --output json
```

The default is a full, timestamped tar archive with overwrite disabled. Each filename includes the site and scope, plus an optional label and UTC timestamp. Timestamp patterns are saved as `VDM_<ENV>_BACKUP_TIMESTAMP_PATTERN`; the default is `%Y%m%dT%H%M%SZ`. Patterns must produce a safe filename component. A disabled timestamp produces a stable name, and replacing that name still requires explicit overwrite.

Backup creation records running services, pauses application writers, makes the logical export and website copy, then restores the prior running set. It may start a stopped database temporarily. Enabled state does not change. A failure in copying, export or compression does not publish a completed archive or replace a previous successful one. Batch failures preserve successful archives from other sites and return a failing overall status with individual results.

Website bind mounts and existing named volumes are inspected through Compose. Named volumes are read using the configured published application image with its normal entrypoint bypassed; no image is built. Unsupported external mounts, additional volumes or unresolvable Compose dependencies prevent a claimed complete backup before copying. Symbolic links, hard links, special files and unsafe member names are rejected by this archive format.

## Restoring

```bash
octojoom --type joomla --task backup --action restore \
  --file /backups/demo-full.tar.gz --target new \
  --key review --domain example.test --sub-domain review \
  --enable yes --non-interactive --output json

octojoom --type joomla --task backup --container demo.example.test \
  --action restore --file /backups/demo-full.tar.gz --target current \
  --pre-backup yes --confirm yes --destination /backups \
  --non-interactive --output json
```

New-site restore reserves a new project and hostname, realigns the supported Compose identity, and refuses external data paths or existing destination volumes. Managed data mounts created by earlier restores or database changes are normalized in a private copy. Custom labels, networks and captured companions remain editable Compose configuration. Referenced site-local hooks are packaged but imported execution is disabled.

Current-site restore requires a verified full pre-restore backup. It prepares fresh database storage and a separate website tree, imports SQL, and verifies the actual application's database connection and HTTP behavior. The original database storage and website files are retained. A failed candidate restores the original deployment and prior running set; error output identifies retained recovery files. If recovery itself fails, the command returns failure and reports that state.

Database import stays within a compatible family: MySQL/MariaDB SQL or PostgreSQL SQL. A cross-family conversion is not claimed. Image/driver requirements are checked by the shared database tools. A changed or custom layout which cannot be mapped safely is rejected for that restore operation.

`--enable no` still imports and verifies a new destination, then leaves its services stopped and its site disabled. `--enable yes` retains the verified destination running and enabled. Container health, database connectivity and HTTP checks are distinct from archive verification; a matching checksum alone does not establish application restorability.

## Inventory and retention

```bash
octojoom --type joomla --task backup --container demo.example.test --action list

octojoom --type joomla --task backup --action verify \
  --file /backups/demo-full.tar.gz --non-interactive

octojoom --type joomla --task backup --container demo.example.test \
  --action delete --file /backups/demo-full.tar.gz --destination /backups \
  --confirm yes --non-interactive

octojoom --type joomla --task backup --container demo.example.test \
  --action cleanup --destination /backups --retention 5 \
  --confirm yes --non-interactive --output json
```

Listing shows label, date, scope, format, size and path. Verify checks transport and payload integrity without modifying the site. Deletion is limited to a validated archive for the selected site within the selected backup destination. Cleanup keeps the newest configured number and never deletes another site's archives. Retention `0` disables deletion; the menu previews the affected list before confirmation. No scheduler is enabled automatically. An existing scheduler can call the same noninteractive command.

Backups contain selected-site credentials and must be protected accordingly. Files are staged privately and completed archives are mode 600 where Unix permissions apply. Host CA keys, host-wide proxy settings, SSH configuration and unrelated sites' environment assignments are not part of a site backup.
