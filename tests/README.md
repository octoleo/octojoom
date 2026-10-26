# Octojoom tests

Run the complete portable suite from the repository root:

```bash
bash tests/run.sh
```

Run one area while developing:

```bash
bash tests/run.sh tests/unit/cli-menus.bats
```

Run the command and site-management suites together:

```bash
bash tests/run.sh tests/unit/cli-automation.bats tests/unit/cli-existing-operations.bats \
  tests/unit/site-information.bats tests/unit/setup-defaults.bats \
  tests/unit/site-alignment.bats tests/unit/php-runtime.bats tests/unit/webserver-docroot.bats
```

Run the migration suites together:

```bash
bash tests/run.sh tests/unit/migration-package.bats tests/unit/migration-import.bats \
  tests/unit/migration-flow.bats tests/unit/migration-remote.bats
```

Run the database and backup suites together:

```bash
bash tests/run.sh tests/unit/database-cli.bats tests/unit/database-setup.bats \
  tests/unit/database-tools.bats tests/unit/database-change.bats \
  tests/unit/site-backups.bats tests/unit/backup-validation.bats
```

Bash 4 or newer, Git, and standard shell utilities are required. The runner
downloads bats-core v1.11.1 into the ignored `tests/.cache` directory when Bats
is unavailable. macOS needs a current Homebrew Bash; Windows uses Git Bash.
Every test has its own temporary home. Docker, whiptail, sudo, SSH, package
managers, and system services use sandboxed stand-ins. These tests never
install software or change the machine's containers, hosts file, or settings.
On Linux, installed Docker Compose also validates generated configuration.

## Coverage

| Area | What the tests check |
| --- | --- |
| CLI and menus | Option forms, missing values, dispatch, cancellation, exit status, and configured paths |
| Command automation | No-dialog execution, early input validation, literal JSON arguments, explicit false/empty values, JSON envelopes, and menu-operation parity |
| Bash discovery | Local-only completion, idempotent installation/removal, fresh-shell activation, login-file precedence, and existing startup-file preservation |
| Expert configuration | Effective per-site ENV, validated replacement, stable Compose project identity, original running-state discovery, stopped-site preservation, and rollback |
| Website information | Enabled versus running state, unavailable Docker, site facts and routes, secret exclusion, selected-site actions, and bind/named-volume paths |
| Configuration and dialogs | Secret persistence, literal input, permissions, validation, random values, and prompt cancellation |
| Joomla setup | Single and bulk project-folder defaults, explicit named-volume opt-out, cancellation, generated Compose, environment values, and feature options |
| Guided setup and defaults | One customization fork, saved-default precedence, manual versus automatic installation, headless preflight, and staged publication failures |
| Configuration alignment | Effective Compose equivalence, complete scoped ENV, custom-field preservation, idempotence, per-site batch failure reporting, and recoverable publication |
| PHP runtime | Published-tag compatibility, measured runtime checks, selective INI changes, custom-directive preservation, stopped-site handling, and rollback |
| Webserver and document root | Apache/Nginx configuration, companion mounts, routing preservation, supported root selection/moves, custom-layout refusal, and failed-change recovery |
| Database engines | Engine-aware setup, published-image capability checks, fresh target storage, configuration preservation, and failed-change recovery |
| Database tools | Selected database discovery, literal credentials and table names, private SQL exports, native client failures, and CLI/menu selection |
| Backups and restore points | Archive validation, backup scopes, independent restore identities, current-site recovery, batch operations, and explicit overwrite/deletion |
| Lifecycle | Enable, disable, edit, start, stop, delete, clone, permission repair, and failure preservation |
| OpenSSH | Configuration, public keys, user settings, and lifecycle |
| Traefik and Portainer | Templates, networks, setup, certificate storage, and lifecycle |
| Domains and hosts | Exact matching, deduplication, deletion, host tokens, and platform dispatch |
| Install and update | Package-manager commands, download and service failures, staged replacement, and uninstall safeguards |
| Migration | Remote quoting, staged publication, verified transfers, pull, and failure rollback |
| Complete migration packaging | Scoped environment values, companion files, stopped-source snapshots, source restart, archive validation, and cleanup on failure |
| Complete migration import | Credential preservation, destination identity/path/network changes, HTTP/HTTPS conversion, collision refusal, and activation guards |
| Complete migration flow | Push/pull source discovery, one-archive transfer, checksum verification, destination import, cancellation, and retained recovery archives |
| Clone helpers | Identity rewriting, configuration changes, environment copying, source preservation, and unsafe aliases |
| Test harness | Function loading, isolated paths, scripted answers, and injected command failures |

Tests exercise observable behavior and failure paths. A function being loaded
by the harness does not mean every possible input or real infrastructure
combination has been tested.

## Configuration compatibility

Octojoom reads `.env` files as data containing `VDM_` assignments. It never
executes them as shell scripts. Existing generated configuration remains
supported. Hand-written configuration must use literal values and absolute
paths rather than shell commands or shell expressions such as `$HOME/Docker`.
New writes preserve dollar signs, quotes, backslashes, and backticks literally;
they reject embedded carriage returns and newlines. Invalid assignments and
invalid boolean settings fail before any values from the file are applied.

## Real Docker regressions

Separate Ubuntu CI jobs also run:

```bash
bash tests/integration/clone.sh
bash tests/integration/migration.sh
bash tests/integration/php-runtime.sh
bash tests/integration/web-runtime.sh
OCTOJOOM_DB_TEST_ENGINE=mariadb bash tests/integration/database-backups.sh
OCTOJOOM_DB_TEST_ENGINE=mysql bash tests/integration/database-backups.sh
OCTOJOOM_DB_TEST_ENGINE=postgres bash tests/integration/database-backups.sh
```

These need Linux, a running Docker daemon, Docker Compose v2, network access to
the official images, and root or passwordless sudo for container-owned bind
mounts. Migration also requires GNU tar and gzip; PHP and web runtime checks
require `jq`, `curl`, and `sha256sum`. Database and backup checks also need
`zip`, `unzip`, and util-linux `script` for the console terminal check.
The scripts create temporary, uniquely
named or labeled resources and remove their own resources on exit. They never
prune the daemon or its images. PHP and web checks publish only ephemeral
loopback HTTP ports.

| CI job | Script | Real acceptance scope |
| --- | --- | --- |
| Docker clone integration | `clone.sh` | Cold database copy and independent cloned website/database |
| Docker migration integration | `migration.sh` | Complete archive, destination realignment, source preservation, and independent destination writes |
| Docker PHP runtime integration | `php-runtime.sh` | Published PHP-image change, effective INI values, unchanged installed-version fixture/database, and rejected-candidate preservation |
| Docker web runtime integration | `web-runtime.sh` | Real Joomla installation, Apache/Nginx round trip, nested-root move, frontend/admin/SEF/API/assets, and preserved site data |
| Docker database and backups (MariaDB, MySQL, PostgreSQL) | `database-backups.sh` | Real Joomla installation, native SQL operations, Unicode/binary data, ZIP/tar restores, bind/named-volume storage, batch operations, and database changes onto fresh storage |

The clone test checks a real cold database copy and confirms Apache/PHP in the
cloned Joomla image can use its independent database after the source database
is stopped.

The migration test exercises the actual exporter, archive extractor, and
destination preparation helper. Its source and destination use different
Octojoom homes, project keys, project paths, and external Docker networks. It
verifies the following against real Joomla/PHP and MariaDB containers:

- Source services are stopped during the filesystem snapshot and restarted.
- One archive includes the database, website, Compose file, and an explicitly
  referenced Compose-relative configuration file.
- An unrelated shared environment secret is excluded; database name, user,
  passwords, table prefix, and application secret are preserved, including a
  password containing dollar and hash characters.
- Destination Compose and Joomla settings switch from HTTPS to HTTP, use the
  destination paths/network, and keep a private per-project `.env` without
  modifying the destination shared environment.
- The migrated application starts and reads its copied database with the source
  database already stopped. Subsequent file/database writes are independent.
- Source website hashes, Compose, environment values, and database marker are
  unchanged by destination import and writes.

Clone and migration use minimal JConfig/SQL fixtures. The PHP runtime test
also uses a minimal application/configuration/database fixture, with the image's
Joomla manifest: it verifies a compatible published PHP change without changing
that installed-version marker or database container, then measures effective
INI settings and checks rejected-candidate preservation. These three tests do
not run Joomla's installer or exercise a complete Joomla extension stack.

The web runtime test invokes headless setup and the real Joomla installer. It
checks the frontend, an administrator login with a real CSRF token/cookie flow,
a rewritten SEF route, API JSON responses (including legitimate authentication
errors), static assets, and an uploaded file. It switches Apache to Nginx/FPM,
stops the site for an explicitly requested bind-mount move to a nested root,
then switches back to Apache. Installed Joomla and PHP versions, site files,
the database container, and a database marker must survive these changes.
The real root-move fixture uses bind storage; named-volume root handling has
portable coverage, not equivalent real-Docker move acceptance.

The database and backup matrix installs Joomla separately for each engine.
It exports and imports actual SQL, checks selected-table operations, Unicode
and binary data, failed imports, overwrite refusal and conditional source-file
deletion. PostgreSQL also exercises its native archive format; MariaDB opens
the actual SQL console through a PTY. ZIP/tar restores run with the source
services stopped and preserve uploaded-file contents, numeric ownership and
mode. Destination writes must remain independent. It also checks current-site
restore with a pre-restore backup, batch operations, independent database-change
clones, and database-version changes that retain the old storage and restore
the original project-folder bind paths. MariaDB/MySQL checks then cold-clone
and package/prepare a raw migration from that site, confirming independent
files and SQL with the source stopped. These exercise local archive workers;
they do not establish actual SSH transport. Fresh mode
must leave an empty database with the website stopped. The MySQL row changes
successfully to MariaDB; the MariaDB row requires an incompatible MySQL import
to reach the actual importer and then restore the original deployment. It also
restores the legacy raw-project archive format. A failed or unfinished matrix
row is not acceptance for that engine, even when the portable tests pass.

None of these scripts proves public proxy routing, DNS, browser certificate
trust, ACME issuance, or real SSH transport. The portable flow tests verify
push/pull orchestration with command stand-ins; destination activation tests
simulate proxy, health, and HTTP/HTTPS failures. Deployment acceptance still
needs the intended hosts, proxy, DNS, and extension settings.

## Validation limits

The portable suite tests installer commands with stand-ins. It does not
install Docker Desktop on macOS or Windows, alter Linux package repositories,
or configure live Cloudflare, public DNS, ACME, and remote SSH servers. Those
systems require deployment acceptance checks in the target environment.
Complete Joomla migration quiesces its source services for the snapshot,
restarts those previously running, and publishes only a new destination. It
does not perform a production write freeze, incremental synchronization, DNS
cutover, or source deletion. Its cold database archive requires matching
architectures and an immutable database image digest. Unsupported named
volumes, symlinks, external databases, and custom layouts are refused.

Legacy folder-only migration copies files; quiesce database services before
moving raw database storage on both source and destination. Remote file migration requires rsync
with `--protect-args` support on both systems and an SSH account that can read
the source and write the destination. Ownership and permission changes can
require noninteractive sudo on the remote host. A failed publication retains
the previous destination or reports the retained recovery backup.
Joomla clone supports the generated bind-mount layout and refuses
layouts it cannot rewrite safely, including Docker named-volume clones,
site-specific alternate project bases, and unsupported external dependencies.
Clone and complete migration carry supported Compose-relative companion files
and retain generated Apache or Nginx/FPM layouts, including configured nested
document roots. Both require canonical project-folder storage; complete
migration also retains its raw database image and architecture requirements.
Clones and complete migrations share a lock per Joomla repository. An
interrupted process can leave `joomla/.clone.lock`; remove that empty directory
only after verifying that no clone or migration is running. Other interactive operations share progress files;
run those operations sequentially.

The expert Compose-folder transfer copies that selected folder. Shared parent
`.env` credentials and separate project volumes are not included by that
legacy action; use complete Joomla migration to package them together with
project-scoped values. Complete-migration failures/cancellation may retain
credential-bearing recovery archives. Check the reported paths and destination
state before retrying, then clean up archives after recovery.
The selected-site PHP runtime controls measure the image's scan directory and
effective configuration. Custom images and arbitrary Apache rules still need
compatible runtime/layout checks; Nginx conversion cannot infer an equivalent
for custom `.htaccess` rules and requires an explicit supported configuration.
Document-root file moves are explicit and limited to supported stopped bind
storage. Validate ownership and image-user IDs on the intended host, especially
for macOS and custom images.
Windows Git Bash does not enforce Unix permission bits. Protect configuration,
credentials, and SSH directories with NTFS access controls for the deployment
account; restrictive Unix modes in the portable tests do not verify those ACLs.
Pin image versions for production deployments. Treat Docker socket access as
administrative host access, and configure trusted proxy ranges explicitly
when forwarding client headers through a proxy.

Docker's official installation instructions do not cover SUSE. Install its
Docker packages and Compose manually before using Octojoom there.

Passing workflows only block merge when branch protection requires them.
Require `ShellCheck`, `Tests (ubuntu-latest)`, `Tests (macos-latest)`,
`Tests (windows-latest)`, `Docker clone integration`,
`Docker migration integration`, `Docker PHP runtime integration`, and
`Docker web runtime integration`, and each `Docker database and backups`
matrix job on protected branches. A portable-suite pass
alone does not establish the real-Docker acceptance results.
