# OctoJoom 4 command interface

OctoJoom remains a standalone Bash program. The Joomla site dashboard and terminal commands call the same handlers. A desktop client can invoke those commands without driving a terminal menu.

## Requirements and existing installations

Use Bash 4 or newer, jq, Docker Engine/Desktop and Docker Compose v2. Archive operations also use tar, gzip, zip/unzip and a SHA-256 implementation. Remote migration uses SSH and rsync. Local trusted HTTPS uses mkcert; install its host trust prerequisites for your operating system. The command interface never opens dependency installers or asks for a password. Privileged filesystem work uses noninteractive elevation and reports failure if elevation is unavailable.

Run `octojoom` for the menu, select Joomla, then **Sites: dashboard and actions**. Existing project discovery keeps the configured Compose repository and project paths. Existing deployment and migration menus remain available. Version 4 projects add a private `.env` and a `project.json` beside their Compose file. Keep custom Compose changes in `docker-compose.override.yml`; generated files are owned by OctoJoom.

## Requests, results and desktop clients

```bash
octojoom site help
octojoom site schema --json
octojoom site list --json
octojoom site info --site example.test --json
```

Commands take long flags or `--config FILE`. `--config -` reads one JSON object from standard input. Use snake_case JSON keys and hyphenated flags. Explicit flags override file values. Boolean flags accept `--enabled=false` or `--enabled false`. Arrays and objects accept JSON. Use `--` to preserve exact developer-tool argument boundaries. No input is evaluated as shell code.

All canonical commands are noninteractive. `--no-interaction` makes that intent explicit for integrations. Supply `--yes` for destructive changes or explicit trust changes after your application has obtained the user's decision. Incomplete requests fail instead of opening a dialog. Interactive container shells, an SQL console without a command, and following logs are terminal streams; use `site exec`, `database console --command`, and bounded logs for JSON clients.

```json
{
  "schema_version": 1,
  "site": "example.test",
  "joomla_version": "5.4.9",
  "php_version": "8.3",
  "admin_email": "developer@example.com",
  "profile": "local",
  "webserver": "apache",
  "database_engine": "mariadb"
}
```

```bash
octojoom site create --config project-request.json --json
```

Select Joomla/PHP tags available in the official Joomla image repository. The runtime validates image contents, PHP version, webserver runtime and database driver before provisioning. Passwords omitted during creation are generated and kept in the private project `.env`. Supply explicit credentials through a private JSON file or stdin when another system needs to provision them.

With `--json`, stdout contains one envelope:

```json
{"schema_version":1,"ok":true,"action":"site:info","data":{},"error":null}
```

Failures set `ok` to false, provide `error.code` and `error.message`, and return the corresponding process status. Diagnostics go to stderr. Status 0 means success; 1 is an operation failure; 2 is an invalid request; 3 is a missing prerequisite or target; 4 is an operation lock. Treat action data as structured data, not formatted terminal text. Discover the current input types and action fields with `site schema`.

Set `--repo-path`, `--project-path` and `--backup-path` to override saved paths. `OCTOJOOM_HOME` selects a separate OctoJoom configuration directory. Paths must be absolute. Do not put credentials in process arguments, status displays or project metadata.

## Site operations

| Command | Purpose |
| --- | --- |
| `site list` | Inventory, optionally filtered by name/state/version. |
| `site info` | Installed/runtime versions, service health, paths and URLs. |
| `site create` | Fresh Joomla with selected PHP, Apache or Nginx/FPM, database and document root. |
| `site configure` | Apply PHP limits and the local HTTP port with recovery. |
| `site php` | Switch PHP while preserving the installed Joomla release. |
| `site webserver` | Switch Apache and Nginx/FPM. |
| `site realign` | Update Joomla database, paths and development URL settings. |
| `site start`, `site stop`, `site restart` | Lifecycle; `--all` supports batch operation. |
| `site delete` | Remove project configuration; data stays unless `--delete-data --yes` is explicit. |
| `site logs`, `site diagnose` | Service logs and dependency/runtime diagnostics. |
| `site open`, `site path` | Open a site/service or retrieve a project path. |
| `site clone`, `site import`, `site migrate` | Independent copies, external Joomla import and one-archive remote migration. |

```bash
octojoom site php --site example.test --php-version 8.2 --yes
octojoom site webserver --site example.test --webserver nginx --yes
octojoom site configure --site example.test --memory-limit 512M --upload-max-filesize 64M --yes
octojoom site clone --site example.test --target-site copy.test --target-key copy --yes
octojoom site stop --site example.test
octojoom site start --all --json
```

PHP switching does not upgrade Joomla core. Requests for incompatible images fail before replacing the runtime. Configuration replacement validates Compose, checks the recreated services and retains a recovery path. Site data and custom overrides are preserved. A creation request can use a custom document root via `--docroot public`; existing project layout is not silently moved.

Use `--install=false` to provision for manual installation. A downloadable Joomla source package requires an HTTPS `--package-url` and its expected `--source-sha256` digest. External imports take website files in `--input`, SQL in `--database-input`, and explicit target identity/runtime choices.

## Databases, backups and recovery

```bash
octojoom database export --site example.test --output /absolute/path/database.sql.gz
octojoom database export --all --json
octojoom database export --site example.test --tables '["prefix_content","prefix_categories"]'
octojoom database import --site example.test --input /absolute/path/database.sql.gz --yes
octojoom database console --site example.test --command 'SELECT 1' --json
octojoom backup create --site example.test --scope full --format tar.gz
octojoom backup create --all --json
octojoom backup list --site example.test --json
octojoom backup restore --input /absolute/path/backup.tar.gz --target-site restored.test --target-key restored --yes
octojoom snapshot create --site example.test --label before-extension-change
octojoom snapshot list --site example.test --json
octojoom snapshot restore --site example.test --input /absolute/path/snapshot.sql.gz --yes
octojoom backup cleanup --site example.test --keep 5 --dry-run
octojoom backup cleanup --site example.test --keep 5 --dry-run=false --yes
```

Full backups contain project configuration, website files and a logical database dump, with a manifest and checksums. Site-scope archives omit companion service configuration. Restore validates the archive before publishing a new target; private host certificate authority keys are excluded. Keep backup files private because project credentials are needed for recovery. SQL restore takes a recovery dump and attempts recovery if the requested import fails. Review the reported recovery path if recovery cannot finish.

MariaDB, MySQL and PostgreSQL are selected per project. An engine change uses a logical export/import into a separate data directory, never reuses another engine's raw database files. `--mode clone` creates an independent target, `--mode replace` replaces the selected environment with recovery data retained, and `--mode fresh` creates an empty independent installation. Cross-family SQL conversion is not implemented: an attempted MySQL-family/PostgreSQL preservation change is refused before mutation. Extension compatibility still matters when choosing the destination database.

```bash
octojoom database switch --site example.test --database-engine mysql --database-version 8.4 \
  --mode clone --target-site mysql-copy.test --target-key mysqlcopy --yes
```

Remote migration sends a single verified compressed archive over SSH/rsync and invokes the same restore command at the destination. Both ends require OctoJoom 4 and its prerequisites. Supply `--remote user@server`, `--direction push|pull`, target identity and destination/source roots when defaults differ. Source files remain available after migration.

## Local HTTPS, sharing and email

```bash
octojoom tls setup --site example.test --yes
octojoom tls disable --site example.test --yes
octojoom share start --site example.test --yes
octojoom share status --site example.test --json
octojoom share stop --site example.test --yes
octojoom mail configure --site example.test --enabled --yes
octojoom mail status --site example.test --json
octojoom mail test --site example.test --json
octojoom mail configure --site example.test --enabled=false --yes
```

Local HTTPS uses mkcert and a dedicated loopback-bound Traefik proxy. The host owns its CA; projects receive only their own certificate/key. `--trust=false` skips trust-store installation, and `--update-hosts=false` leaves hostname resolution to you. HTTP/HTTPS ports are configurable. A shared local proxy must use consistent port settings across sites. The local proxy does not replace the existing production ACME proxy.

External sharing starts a temporary Cloudflare tunnel for the selected web application and returns its URL. It does not expose database, mail or administration-tool ports. Joomla's administrator is part of the application and remains subject to Joomla authentication. Stop sharing when the review ends. Public tunnel creation requires network access to the provider.

Email capture uses Mailpit. Enabling it preserves Joomla's previous mail settings; disabling restores them. The mail test sends through Joomla and checks capture. Optional Redis and Node services are project scoped:

```bash
octojoom service configure --site example.test --service node --enabled --yes
octojoom service configure --site example.test --service redis --enabled --yes
```

## Developer commands, hooks and offline preparation

```bash
octojoom site shell --site example.test
octojoom site exec --site example.test --json -- php -v
octojoom site joomla --site example.test -- list
octojoom site composer --site example.test -- install
octojoom site npm --site example.test -- ci
octojoom site logs --site example.test --tail 100 --json
octojoom site offline --site example.test --yes
octojoom update check --json
```

Composer runs with the project's PHP runtime and a verified cached PHAR when absent from that runtime. npm uses the optional Node service. Offline preparation caches required images, starts and checks the site, and can cache Composer with `--composer-version`. Application dependencies that were never downloaded, external APIs, and public tunnels still need network access.

Hooks are explicit argument arrays, executed in the project runtime without shell evaluation. For example:

```bash
octojoom hook configure --site example.test --event post-start \
  --commands '[["php","cli/joomla.php","cache:clean"]]' --yes
```

Supported events cover start/stop/delete, import/export, backups/restores and Composer. Hook failures propagate to the command result. Imported backups must not silently grant trust to arbitrary hook commands. Disable an event with `--enabled=false`.

Xdebug and automatic Joomla core upgrades through image replacement are outside this release's scope.
