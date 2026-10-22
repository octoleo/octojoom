# Database engines and version changes

Octojoom supports MariaDB, MySQL and PostgreSQL when the selected Joomla image has the required PHP driver and its Joomla release accepts the server version. The actual database image is inspected; PostgreSQL data-directory placement is measured from its `PGDATA`. Installed websites are checked against their own Joomla database driver as well as the image's bundled Joomla code.

The existing default remains MariaDB. New-site setup accepts `--engine mariadb|mysql|postgres` and `--database-image IMAGE:TAG`; the optional customization menu exposes the same choices. Database name, user, password and root password retain their existing scoped ENV keys. New `VDM_<SITE>_DB_ENGINE` and `VDM_<SITE>_DB_IMAGE` values describe that website, while future-site defaults remain separate. PostgreSQL uses its supported initialization variables and phpMyAdmin is omitted for new PostgreSQL sites.

## Change an existing website

Open **Joomla → Website Information → choose a website → Change database**, or choose the same action under **Database tools**. The first choice leaves the database unchanged. Every change requires an explicit target image and data outcome:

| Mode | Result |
| --- | --- |
| `preserve` | Replace the selected website's database storage, import its SQL and verify Joomla's connection. |
| `clone` | Create an independent website at a new key/hostname, then change that clone's database. The source remains intact. |
| `fresh` | Prepare an explicitly empty database. Website services remain stopped until installation or restore; existing content has **not** been migrated. |

```bash
octojoom --task database --action change --container shop.example.test \
  --engine mariadb --database-image mariadb:11.4 \
  --data-mode preserve --pre-backup yes --confirm yes --non-interactive
```

```bash
octojoom --task database --action change --container shop.example.test \
  --engine mysql --database-image mysql:8.4 --data-mode clone \
  --key preview --sub-domain preview --domain example.test \
  --enable yes --confirm yes --non-interactive
```

```bash
octojoom --task database --action change --container scratch.example.test \
  --engine postgres --database-image postgres:18 --data-mode fresh \
  --pre-backup yes --confirm yes --non-interactive
```

These image tags illustrate explicit choices, not an unconditional compatibility promise. The chosen image and installed Joomla must pass the capability checks. Existing credentials are preserved and supplied through private client files; they are not required in command arguments. Some published Joomla PostgreSQL initializers cannot correctly handle whitespace, quotes or backslashes in connection values. That combination is refused before changes, with the supplied values preserved.

## Storage, downtime and recovery

A change always selects a fresh, uniquely named Docker volume. The target engine never opens the previous engine's raw data directory. This applies to version changes within one engine too. The original bind directory or named volume remains untouched by the target and is retained after success.

The workflow locks the selected site's configuration, validates staged Compose and offers an optional complete backup. It stops that project's running writers before the final logical export, then stops the original database. It updates the database image, initialization environment, data mount and health check together with Joomla's host and driver in both Compose and `configuration.php`. Unrelated service fields, extra mounts and custom settings are preserved. Shared ENV files are never rewritten wholesale; a complete site-scoped ENV is prepared instead.

After the fresh server accepts the existing site credentials, preserved SQL is imported with native error stopping. The target table inventory and row counts must match the source, and PHP must connect using Joomla's actual configuration and driver. Previously running services are resumed; a previously stopped website remains stopped. Fresh mode intentionally leaves website services stopped because an empty database is not an installed Joomla site. An existing phpMyAdmin service is retained under a disabled profile when PostgreSQL is selected, so its custom settings are not discarded or launched against an incompatible database.

An export, import, startup or verification failure restores the original Compose, site ENV, installed configuration and previously running services. Recovery files and any candidate storage remain available for inspection. The reported `.database-change.*` directory contains the original configuration and the consistent SQL export when one was completed. Original storage is never automatically pruned. If automatic restart itself fails, inspect the reported recovery location and service status before retrying.

Independent clones use the full logical backup/restore path. Their website files and database storage are separate. Destination key/hostname collisions are refused; a failed later engine change leaves a recoverable destination and the source intact.

## Compatibility boundaries

PostgreSQL and MySQL-family SQL are different dialects. Preserved-data conversion between these families is refused before mutating the source. Choose a fresh target or use a separate, tested migration process.

MariaDB and MySQL exports are not universally interchangeable. Native import and Joomla verification decide whether the specific schema and server versions work. Unsupported statements, collations, data types, permissions or dump-client directives fail the operation and restore the source. A successful image pull or container startup alone does not establish compatibility. Custom database commands, entrypoints and server configuration/initialization mounts require manual adaptation before switching engines.

The stage editor supports the block-style Compose service layout emitted by Octojoom and ordinary environment mappings. Shared website configuration files, ambiguous database mounts, unsupported YAML structures and external database connections are refused for this action without limiting unrelated site operations.

See [Database tools](DATABASE-TOOLS.md) for logical SQL import/export and [Backups](BACKUPS.md) for complete website recovery. `tests/unit/database-change.bats` checks staging and failure semantics; the real Docker acceptance workflow verifies installed Joomla access, preserved data, fresh storage, rollback and clone independence. Unit doubles alone do not establish server compatibility.

## References

- [Joomla 5.4 technical requirements](https://manual.joomla.org/docs/5.4/get-started/technical-requirements/)
- [MariaDB logical dump documentation](https://mariadb.com/docs/server/clients-and-utilities/backup-restore-and-import-clients/mariadb-dump)
- [MariaDB dump-file compatibility change](https://mariadb.org/mariadb-dump-file-compatibility-change/)
- [MySQL `mysqldump` documentation](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html)
- [PostgreSQL `pg_dump` documentation](https://www.postgresql.org/docs/current/app-pgdump.html)
- [Official MySQL image initialization settings](https://github.com/docker-library/docs/blob/master/mysql/content.md)
- [Official PostgreSQL image data-directory and initialization settings](https://github.com/docker-library/docs/blob/master/postgres/content.md)
