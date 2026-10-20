# OctoJoom 4 command interface

OctoJoom remains a standalone Bash program. The Joomla site dashboard and terminal commands call the same handlers. A desktop client can invoke those commands without driving a terminal menu.

## Requirements and existing installations

Use Bash 4 or newer and jq. Native Windows jq must be version 1.7 or newer so JSON output uses Unix line endings; OctoJoom preserves literal JSON values while translating filesystem arguments at the native command boundary. Site operations also need Docker Engine/Desktop, a reachable Docker daemon and Docker Compose v2 with `up --wait` support. On Windows, configure Docker Desktop to use Linux containers and enable Developer Mode or use an elevated terminal for native symbolic links. OctoJoom refuses directory-copy substitutes for enabled-site links. Help, version and schema discovery do not contact Docker. Archive operations use tar, gzip and a SHA-256 implementation; ZIP archives additionally need zip, unzip and zipinfo. Downloads, update checks and local certificate verification use curl. Remote migration uses SSH with noninteractive authentication and rsync with `--protect-args` support on both hosts. Local trusted HTTPS uses mkcert; install its host trust prerequisites for your operating system. The command interface never opens dependency installers or asks for a password. Privileged filesystem work uses noninteractive elevation and reports failure if elevation is unavailable.

Run `octojoom` for the menu, select Joomla, then **Sites: dashboard and actions**. Existing project discovery keeps the configured Compose repository and project paths. Existing deployment and migration menus remain available. Version 4 projects add a private `.env` and a `project.json` beside their Compose file. Keep custom Compose changes in `docker-compose.override.yml`; generated files are owned by OctoJoom.

## Requests, results and desktop clients

```bash
octojoom site help
octojoom site schema --json
octojoom site list --json
octojoom site info --site example.test --json
```

Commands take long flags or `--config FILE`. `--config -` reads exactly one JSON object from standard input; the action group and action remain command arguments. Use snake_case JSON keys and hyphenated flags. `schema_version` defaults to 1; other versions, unknown fields, incorrect types and control characters are rejected. Explicit flags override file values. Boolean flags accept `--enabled`, `--enabled=false` or `--enabled false`. Arrays and objects accept JSON. Supply developer-tool arguments as an `args` array or after `--` to preserve exact argument boundaries. Request values are parsed as data, without shell expansion.

Canonical commands do not prompt for missing settings or confirmation. `--no-interaction` makes that intent explicit for integrations. Supply `--yes` for destructive changes or explicit trust changes after your application has obtained the user's decision. Incomplete requests fail instead of opening a dialog. Interactive container shells, an SQL console without a command, and following logs are terminal streams; use `site exec`, `database console --command`, and bounded logs for JSON clients.

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

Select Joomla/PHP tags available in the official Joomla image repository; both versions are required. The runtime validates image contents, PHP version, webserver runtime and database driver before provisioning. A full Joomla version pins that exact patch; a major.minor version accepts that release line. Automatic installation requires an administrator email, an alphabetic administrator username, site/administrator names of at least three characters and an administrator password of at least 13 characters. Passwords omitted during creation are generated and kept in the private project `.env`. Supply explicit credentials through a private JSON file or stdin when another system needs to provision them.

With `--json`, stdout contains one envelope:

```json
{"schema_version":1,"ok":true,"action":"site:info","data":{},"error":null}
```

Failures set `ok` to false, provide `error.code` and `error.message`, and return the corresponding process status. Diagnostics go to stderr. Status 0 means success; 1 is an operation failure; 2 is an invalid request; 3 is an unavailable prerequisite or target; 4 is an operation lock. Developer commands preserve their child process status, which can use other codes, and their `data` can include `stdout`, `stderr` and `exit_code` even on failure. Treat action data as structured data, not formatted terminal text. Discover the current input types and action fields with `site schema`. jq must already be installed to produce JSON envelopes.

Set `--repo-path`, `--project-path` and `--backup-path` to override saved paths. `OCTOJOOM_HOME` selects the home base: configuration is read from `$OCTOJOOM_HOME/.config/octojoom`, with default project roots under that base. Without it, `$HOME` is used. These root paths must be absolute, non-root paths without `.` or `..` components. Keep credentials in a private JSON file or stdin rather than process arguments, status displays or project metadata.

New actions also accept the existing style, for example `octojoom --type joomla --task info --container example.test --json`. For an existing setup task, add `--no-interaction`, `--json` or `--config` to select the v4 command interface; existing menu workflows remain available.

## Site operations

| Command | Purpose |
| --- | --- |
| `site list` | Inventory, optionally filtered by Joomla version prefix and running/stopped state. |
| `site info` | Installed/runtime versions, service health, paths and URLs. |
| `site create` | Fresh Joomla with selected PHP, Apache or Nginx/FPM, database and document root. |
| `site download` | Download a verified full Joomla package into an empty directory, without Docker. |
| `site configure` | Apply PHP limits and the local HTTP port with recovery. |
| `site php` | Switch PHP while preserving the installed Joomla release. |
| `site webserver` | Switch Apache and Nginx/FPM. |
| `site realign` | Update Joomla database, paths and development URL settings. |
| `site start`, `site stop`, `site restart` | Lifecycle; `--all` supports batch operation. |
| `site delete` | Remove project configuration; data stays unless `--delete-data --yes` is explicit. |
| `site logs`, `site diagnose` | Service logs and dependency/runtime diagnostics. |
| `site open`, `site path` | Open a site/service or retrieve a project path. |
| `site permissions` | Restore runtime ownership and Joomla file/directory permissions. |
| `site clone`, `site import`, `site migrate` | Independent copies, external Joomla import and one-archive remote migration. |

```bash
octojoom site php --site example.test --php-version 8.2 --yes
octojoom site webserver --site example.test --webserver nginx --yes
octojoom site configure --site example.test --memory-limit 512M --upload-max-filesize 64M --yes
octojoom site clone --site example.test --target-site copy.test --target-key copy --yes
octojoom site stop --site example.test
octojoom site start --all --json
```

`site start` enables the site's startup link by default; `--enable=false` starts it without adding that link. `site stop` leaves the link unchanged unless `--disable` is supplied. Restart preserves the enabled state. Start/restart wait for the database, Joomla runtime, Nginx when selected, and enabled mail/Redis services; `--timeout` defaults to 120 seconds. Batch lifecycle commands accept `--all` instead of `--site` and return each site's result and error. Deletion always requires `--yes`; when retaining data, it saves recoverable project configuration and scoped credentials in the reported recovery directory.

`site path` returns the document root by default, or the project root with `--target project`. `site open` accepts `--target site|admin|database|mail|directory`; add `--print` to return the address/path without launching an application. Local site addresses use the actual assigned port. Before using a development hostname such as `example.test`, map it to loopback in your hosts file; local TLS setup and offline preparation can manage this entry.

`site permissions --site example.test --yes` resets the managed document root to the selected Joomla image's `www-data` ownership: directories become `0755`, regular files `0644`, and `configuration.php` `0600`. This also removes executable bits from regular files. It verifies the effective Compose bind mount, skips symlinks and other mounted filesystems, and preserves the original running/enabled state. The result reports file/directory counts and skipped symlinks. A symlinked document root or configuration file is refused; custom volumes that replace the managed document root must be corrected first.

PHP switching does not upgrade Joomla core. It selects an image containing the installed Joomla patch with the requested PHP version; if that image is unavailable or incompatible, the request fails before runtime replacement. Configuration replacement validates Compose, checks recreated services and restores the previous configuration if recreation fails. Already-cached database image tags are not refreshed by a PHP or settings change. Site data and custom overrides are preserved. A creation request can use a normalized relative document root such as `--docroot public/joomla`; existing project layout is not moved. Supported legacy bind-mounted projects obtain verified runtime metadata when adopted; named-volume legacy layouts require migration before these operations.

The local profile publishes HTTP and database administration tools on loopback only, with an available random HTTP port by default; set `--http-port` for a fixed port. Create local sites with `--tls-mode none`, then run `tls setup` for workstation trust and hostname setup. The server profile requires an existing proxy network; select it with `--network` and use `--tls-mode acme` with the configured certificate resolver. Creation can enable `--mail`, `--redis` and `--node`; email capture is applied after successful automatic installation.

Use `--activate=false` to prepare a stopped project, and `--install=false` for manual installation. A downloadable Joomla source package requires an HTTPS `--package-url` and its expected `--source-sha256` digest. External imports take website files in `--input`, SQL in `--database-input`, and explicit target identity/runtime choices.

`site download --output /absolute/empty/directory --joomla-version latest` resolves the current stable full installation package from Joomla's official GitHub release. An exact version selects that release. The command checks the official SHA-256 digest before extraction; custom `--package-url` downloads require `--source-sha256`. It creates fresh files only and cannot update an existing Joomla site. For older releases without an official SHA-256 in the release metadata, supply an explicit package URL and a trusted checksum.

Switching Apache and Nginx also updates an existing local HTTPS route. Stop an active review share before switching the webserver, then start sharing again to obtain a working review URL.

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
octojoom snapshot restore --site example.test --input /absolute/path/snapshot.tar.gz --yes
octojoom backup cleanup --site example.test --keep 5 --dry-run
octojoom backup cleanup --site example.test --keep 5 --dry-run=false --yes
```

Full backups contain project files and a logical database dump, with a manifest and checksums; raw database directories and internal recovery data are excluded. Site-scope archives include only the Joomla document root from the project directory. Both scopes retain Compose companions, scoped environment values and metadata needed to reconstruct the runtime, including service settings and hook definitions. Restore validates the archive before publishing a new target; private host certificate authority keys are excluded and archived hooks are inactive unless explicitly trusted. Keep backup files private because project credentials are needed for recovery. Archives accept regular files and directories; links and special files are refused before packaging or extraction. Legacy adoption requires a supported bind-mounted Joomla layout; named-volume projects retain their legacy management paths. SQL restore takes a recovery dump and attempts recovery if the requested import fails. Review the reported recovery path if recovery cannot finish.

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

Local HTTPS requires a site created with `--profile local`. It uses mkcert and a dedicated Traefik proxy bound to `127.0.0.1`. The CA stays in mkcert's workstation store; the proxy receives only the leaf certificates and keys kept in OctoJoom's private local TLS directory. CA private keys are never copied into a project, proxy, or backup. The proxy uses a file provider and has no Docker socket access.

The default `tls setup --yes` installs trust and adds a marked hosts-file entry for the selected hostname. On Linux or macOS, authorize `sudo -v` separately if needed, then repeat the command from your normal user account. In Windows Git Bash, use an Administrator terminal with mkcert installed. In WSL, the Linux trust store and Windows browser trust store are separate; configure trust in the browser's host OS as well. OctoJoom never asks for an elevation password. `--trust=false` (also `--install-trust=false`) skips trust installation and requires an existing mkcert CA; `--update-hosts=false` leaves name resolution to your DNS or hosts-file setup. Existing manual loopback mappings remain untouched, and conflicting remote mappings are refused.

Use `--http-port 8080 --https-port 8443` if ports 80/443 are occupied. Every site sharing this local proxy must use the same port pair. The proxy is separate from the production ACME proxy, and OctoJoom refuses to take over a same-named proxy owned by another configuration directory. Disabling TLS removes that site's route and leaf certificate/key, retains its local hostname for HTTP, and stops the proxy when no TLS routes remain. It retains the reusable proxy configuration, network, and workstation CA trust. Deleting the site also removes its marked hosts-file entry.

External sharing requires a running local-profile site. It starts a temporary Cloudflare tunnel directly to that site's private HTTP web service and returns an HTTPS review URL. It preserves the public hostname for Joomla-generated links and does not route through the local certificate proxy. It does not expose database, mail or administration-tool ports. Joomla's administrator is part of the application and remains subject to Joomla authentication. `share status` reports the live container state and URL; `share stop` removes the site's tunnel container and saved URL. Stop sharing when the review ends. Public tunnel creation requires outbound access to Cloudflare and is intended for temporary review, not production hosting.

Email capture is restricted to local-profile sites and uses Mailpit. Enabling it preserves Joomla's previous mail settings before pointing Joomla's SMTP transport at the private Mailpit service; disabling restores those settings. Mailpit's inbox is bound to loopback with an automatically assigned port, available through `mail status` or `site open --target mail`; use `--mail-port` during configuration to choose a fixed port. SMTP is not published on the host. `mail test` verifies that Joomla still points at this site's capture service, then sends a test through Joomla to `capture@example.test`. View it in the inbox; the command does not send through an external SMTP provider.

Optional Redis and Node services are project scoped:

```bash
octojoom service configure --site example.test --service node --enabled --yes
octojoom service configure --site example.test --service redis --enabled --yes
```

Redis is a private cache service; enabling it does not change Joomla's cache/session configuration or install PHP extensions into the Joomla image. Node runs as an on-demand tool service used by `site npm`; choose its image with `--node-image`. Disable either with `--enabled=false`. Neither service publishes a host port.

## Developer commands, hooks and offline preparation

```bash
octojoom site shell --site example.test
octojoom site exec --site example.test --json -- php -v
octojoom site joomla --site example.test -- list
octojoom site composer --site example.test -- install
octojoom site npm --site example.test -- ci
octojoom site logs --site example.test --tail 100 --json
octojoom site offline --site example.test --composer-version 2.10.3 --json
octojoom update check --json
```

`site exec` passes arguments literally to the selected service (`web` by default). `--service` also accepts `frontend`, `db`, `mail`, `database-ui`, `redis`, `node`, or an exact service name from that project's Compose configuration. `--workdir` selects an absolute container directory and defaults to `/var/www/html`. `site shell` requires a terminal and supports a custom executable after `--`. `site joomla` invokes the installed `cli/joomla.php` with PHP and defaults to its command list. Bounded developer-command results contain stdout, stderr and the child exit status, with a 16 MiB limit for each output stream. Use a terminal shell for interactive output. Logs default to the web service and the last 100 lines; `--follow` streams until interrupted and cannot return JSON.

Composer uses the project's PHP runtime. When Composer is absent, OctoJoom downloads and verifies a cached PHAR, then runs it in a one-shot container using the selected Joomla image. `--composer-version` selects an explicit Composer 2 release and forces the PHAR path; the default fallback is 2.10.3. Composer always receives `--no-interaction`. npm uses the web runtime if npm is installed there, otherwise the configured Node service runs on demand. Enabling Node is required for that fallback. Composer/npm default to reporting their version when no arguments are supplied.

Offline preparation applies to local-profile sites. It adds an owned hosts-file entry by default, pulls/builds the project's images including the optional Node tools profile, starts the site, and waits for readiness. `--update-hosts=false` leaves the hosts file unchanged; the result reports whether a loopback entry exists. Use `--all` instead of `--site` for a batch of local projects. Supplying `--composer-version` also prepares that PHAR in the local cache. Run this while connected and install application dependencies before disconnecting. Package downloads, external APIs and public tunnels still need network access. Offline preparation preserves the existing enabled-site link.

`update check` compares the installed OctoJoom version with the `master` channel and reports `current`, `available` and `update_available`. `--channel staging` checks the staging channel. This command does not install an update or execute downloaded code.

Hooks are explicit argument arrays, executed in order in the site's Joomla runtime at `/var/www/html`, without shell evaluation. A stopped runtime uses a one-shot container with the command as its entrypoint. Empty argument strings are preserved; executables must be nonempty, and control characters are rejected. Each event permits up to 32 commands with up to 128 arguments per command. For example:

```bash
octojoom hook configure --site example.test --event post-start \
  --commands '[["php","cli/joomla.php","cache:clean"]]' --yes
```

Configure an existing site's event with `hook configure`; disable it with `--enabled=false`. New site creation and external import can supply the same definitions through a `hooks` object in the request:

```json
{"hooks":{"pre-import":[["php","-v"]],"post-import":[["php","cli/joomla.php","cache:clean"]]}}
```

| Events | Operation |
| --- | --- |
| `pre-start`, `post-start` | Explicit start/restart, initial creation, and offline preparation. |
| `pre-stop`, `post-stop` | Explicit stop/restart. |
| `pre-delete` | Site deletion, before containers/configuration are removed. |
| `pre-import`, `post-import` | External Joomla site import. |
| `pre-export-db`, `post-export-db` | Explicit SQL export. |
| `pre-import-db`, `post-import-db` | SQL import into an existing site, including database snapshot restore. |
| `pre-backup`, `post-backup` | Archive/snapshot creation, including recovery and clone-source backups. |
| `pre-restore`, `post-restore` | Full/site archive restore, including cloning and database replacement. |
| `pre-composer`, `post-composer` | Composer commands. |

An internal temporary stop/start during backup or restore does not trigger the explicit lifecycle events. A failed hook stops the remaining commands and returns a failed operation. Pre-operation failures prevent the following operation; post-operation failures report failure after the completed change. Arbitrary hook side effects are not rolled back. A successful import/restore or a published backup remains available if its post-hook fails; inspect the command result and recovery paths.

Archive hooks are inactive by default. Restore preserves them in `imported-hooks.json` for review; use `--trust-hooks` only when you want the archived commands to run. This rule also applies to clones and migrations. When replacing an existing site without trusting archived hooks, the destination keeps its own configured hooks. Its trusted `pre-restore` runs before replacement. The newly provisioned target's `pre-restore` runs only for a new destination with explicitly trusted hooks. Database-only snapshot restore retains the existing site's hooks and does not load commands from its archive.

Xdebug and automatic Joomla core upgrades through image replacement are outside this release's scope.

## Updating the OctoJoom executable

```bash
octojoom update check --channel master --json
octojoom update apply --channel master --yes --json
octojoom update apply --channel staging --install-path /usr/local/bin/octojoom --yes
```

`update apply` replaces the installed OctoJoom program. It does not change Joomla core or project containers. The default target is the running OctoJoom executable, then the executable on `PATH`, falling back to `/usr/local/bin/octojoom`. Supply an absolute `--install-path` for another installation. The target must already be an executable OctoJoom file; symbolic-link targets are refused, so specify the actual executable path.

The updater downloads only from the official `master` or `staging` branch over HTTPS. Before replacement it checks the program identity, shebang, version and Bash syntax without running any downloaded code. It stages the replacement in the installation directory and atomically renames it into place. A separate recovery copy of the previous executable is retained; its path appears in `recovery_path`. Validation failures preserve the installed program, and interrupted publication attempts restore the recovery copy. Restart OctoJoom after a successful update.

Use `sudo -v` separately if the installation directory requires elevation; the updater uses `sudo -n` and never requests a password. Concurrent updates use an installation lock. Downloads older than the installed version are refused unless `--force --yes` explicitly requests a downgrade. `update check` only reports availability and does not replace files.
