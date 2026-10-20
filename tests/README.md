# Octojoom tests

Run the complete portable suite from the repository root:

```bash
bash tests/run.sh
```

Run one area while developing:

```bash
bash tests/run.sh tests/unit/v4-cli.bats tests/unit/v4-tui.bats
```

Run all OctoJoom 4.0 unit and API suites:

```bash
bash tests/run.sh tests/unit/v4-*.bats
```

Bash 4 or newer, jq, Git, and standard shell utilities are required. The runner
downloads bats-core v1.11.1 into the ignored `tests/.cache` directory when Bats
is unavailable. macOS needs a current Homebrew Bash; Windows uses Git Bash and
native jq 1.7 or newer. Each test has a temporary home. External operations
normally use sandboxed stand-ins for Docker, whiptail, sudo, SSH, package
managers, and system services. The tests do not install software or change
existing containers, the system hosts file, or certificate trust. The CI
workflow installs its own test prerequisites before invoking the runner.

The default runner includes all Bats suites and the two standalone clone
regression scripts. It does **not** run the real-container integration scripts.
`BATS_TEST_TIMEOUT` sets the per-test deadline (120 seconds by default).
`BATS_JOBS` enables parallel Bats execution when GNU parallel is available.

## Portable coverage and platform checks

| Suite | What the tests check |
| --- | --- |
| `v4-cli.bats` | Flags and JSON requests, aliases, literal argument arrays, schema and action validation, ambiguous batch targets, no-prompt execution, JSON results and exit status, metadata, locks, scoped Compose environment, and Windows argument/CRLF handling |
| `v4-completion.bats` | Bash command/action discovery, action-specific options, enum and path values, site names, literal quoting, and read-only completion without operation dispatch |
| `v4-tui.bats` | Every advertised operation has a handler and menu schema; required and conditional fields, explicit false defaults, secret fields, SQL command results, failure details, recovery paths, and empty-inventory actions remain available |
| `v4-runtime.bats` | Apache/Nginx and all three database configurations, scoped credentials, PHP settings, installed-Joomla version pinning, failed runtime-change recovery, source download verification, override preservation, and Windows host/container path boundaries |
| `v4-database.bats` | SQL exports and selection, snapshots, full and ZIP archives, checksum/path validation, partial-import recovery, independent restores, replacement rollback, retention, hook trust, and one-archive migration orchestration |
| `v4-network.bats` | Local TLS routing and rollback, hosts-file ownership and conflicts, private companion ports, tunnel ownership, mail configuration restoration, and native Windows paths and line endings |
| `v4-tools.bats` | Site inventory and runtime facts, lifecycle and batch failures, safe deletion and permission repair, command output/status, literal hooks, verified Composer, on-demand Node, and offline preparation |
| `v4-update.bats` | Explicit update confirmation, download and syntax failures, atomic replacement and recovery, interruption handling, lock ownership, symlink refusal, and downgrade protection |
| Legacy CLI, menus and configuration | Option forms, cancellation, dispatch, configured paths, secret persistence, literal environment values, permissions, and validation |
| Legacy setup and lifecycle | Single/bulk deployment, Compose generation, enable/disable/start/stop/delete, clone, and failure preservation |
| Legacy host integrations | OpenSSH, Traefik, Portainer, domains/hosts, package-manager commands, updates, and uninstall safeguards |
| Legacy migration and clone | Remote quoting, cold-copy packaging/import, staged publication, checksum validation, source preservation, rollback, and recovery archives |
| Test harness | Function loading, isolated paths, scripted answers, and injected command failures |

CI runs the portable suite on Ubuntu, macOS, and Windows. On Linux, available
Docker Compose also validates generated configuration. The Windows job requires
the native Docker CLI and Compose v2 and runs a separate `docker compose config`
check for generated Windows bind paths. Large JSON request, result and archive
regressions also run before the full Windows suite to catch native transport
failures early. It does not start a Docker daemon or
containers. This verifies the native configuration boundary, **not Docker
Desktop runtime behavior**. macOS coverage is the portable suite, not a live
Docker Desktop deployment.

Tests exercise observable behavior and failure paths. A function being loaded
by the harness does not mean every possible input or infrastructure combination
has been tested. The TUI tests check shared schemas and menu behavior; the real
container scenarios below invoke the same actions through the public command API.

## Configuration compatibility

Octojoom reads `.env` files as data containing `VDM_` assignments. It never
executes them as shell scripts. Existing generated configuration remains
supported. Hand-written configuration must use literal values and absolute
paths rather than shell commands or shell expressions such as `$HOME/Docker`.
New writes preserve dollar signs, quotes, backslashes, and backticks literally;
they reject embedded carriage returns and newlines. Invalid assignments and
invalid boolean settings fail before any values from the file are applied.

## OctoJoom 4.0 real-container acceptance

Four separate Ubuntu CI scenarios exercise the public JSON command interface
against real containers. Run one explicitly on a disposable Linux Docker host:

```bash
V4_SCENARIO=lifecycle bash tests/integration/v4.sh
V4_SCENARIO=mysql bash tests/integration/v4.sh
V4_SCENARIO=postgres bash tests/integration/v4.sh
V4_SCENARIO=migration bash tests/integration/v4.sh
```

The migration scenario delegates to `tests/integration/v4-migration.sh`.
All scenarios require a reachable Docker daemon, Docker Compose v2, jq, curl,
GNU/Linux shell utilities, network access to the required images and downloads,
and root or passwordless sudo for container-owned files. The database/lifecycle
scenarios also require tar, gzip, zip, and unzip. Lifecycle requires mkcert and
Python 3; migration requires Python 3, OpenSSH client/server, and rsync. The
workflow provisions these prerequisites. Lifecycle refuses to run alongside an
existing `octojoom-local-proxy` container or `octojoom_local` network.

| Scenario | Real behavior exercised |
| --- | --- |
| `lifecycle` | Fresh Joomla installation with MariaDB; shared backup/recovery checks below; PHP 8.2 to 8.3 while retaining the installed Joomla release; Apache to Nginx/FPM; Joomla API authentication responses; local HTTPS; mail capture; Joomla CLI, Composer, Node/npm and Redis; per-site database viewer enable/disable and phpMyAdmin/Adminer switching; permission repair; temporary public review URL; MariaDB to MySQL replacement |
| `mysql` | Fresh Joomla installation with MySQL; shared backup/recovery checks; MySQL to MariaDB replacement with retained recovery archive and previous storage |
| `postgres` | Fresh Joomla installation with PostgreSQL; shared backup/recovery checks; refusal of unsupported PostgreSQL-to-MySQL data conversion before creating a destination |
| `migration` | Fresh Joomla/MariaDB installation; actual SSH and rsync push and pull between separate OctoJoom homes; one verified logical archive per transfer; destination identity/path changes; source preservation and independent restored sites |

The three database scenarios currently install Joomla 5.4.9 with PHP 8.2,
using MariaDB 11.4.12, MySQL 8.4, or PostgreSQL 16. They verify the running
application and database, structured site facts, and literal command arguments.
They export a selected SQL table with a checked checksum, restore a named
SQL-only snapshot without overwriting later file edits, and deliberately fail an
SQL import **after** a schema change to verify recovery of the original database
and application. They also create and restore a full portable archive that
excludes raw database storage, stop the entire source stack to prove destination
independence, check batch export results, and delete only the selected restored
site. MySQL-family replacement checks retain the old storage and recovery archive.

Lifecycle adds these service checks:

- The PHP swap preserves Joomla's core-file hash and site data. Nginx/FPM serves
  both Joomla API route forms without exposing `configuration.php` source.
- Local HTTPS uses an isolated mkcert CA, temporary hosts file, and loopback
  ports. curl explicitly trusts that CA and checks the HTTP-to-HTTPS redirect.
  The test does not install system/browser trust or change the system hosts file.
- Joomla's actual mailer delivers a message into the private Mailpit inbox;
  disabling capture restores the original mail settings, including secrets.
- Database viewer changes retain the selected site's SQL data and leave a second
  site's viewer and database unchanged. phpMyAdmin and Adminer serve the same
  local HTTPS hostname; disabling the viewer removes its container and route.
  Mail capture uses its own local HTTPS hostname and removes that route when disabled.
- Verified Composer runs in the selected PHP runtime. An on-demand Node container
  builds a project fixture and exits. Redis answers PING without a published
  host port. Permission repair restores `www-data` access and protects
  `configuration.php`, then resumes the site.
- A real temporary Cloudflare tunnel exposes only the generated Joomla fixture.
  The test fetches its marker and homepage through the public HTTPS URL, then
  stops the tunnel and checks its removal. This gate needs external Cloudflare,
  DNS, and network availability; public-route readiness has a bounded retry.

Migration starts a private loopback SSH server with generated client/host keys,
strict host verification, and noninteractive authentication. Both ends use the
same Linux Docker host but different homes and project roots. Push and pull each
create an independent destination that works with its source stopped; subsequent
writes leave the source unchanged. This tests real transport, not deployment on
a separate remote machine, WAN reliability, or production DNS cutover.

The scripts use temporary homes and scoped resources. Exit traps remove their
containers, networks, tunnel, temporary SSH server, and files; they never prune
the Docker daemon or images. Each CI scenario has a 32-minute execution deadline
inside a 35-minute job, leaving time for cleanup. No scenario tests Xdebug or
upgrading Joomla core by replacing its Docker image.

## Legacy real Docker regressions

Separate Ubuntu CI jobs retain these legacy checks:

```bash
bash tests/integration/clone.sh
bash tests/integration/migration.sh
```

These require Linux, a running Docker daemon, Docker Compose v2, network access
to the official images, and root or passwordless sudo for container-owned bind
mounts. Migration also requires GNU tar and gzip. Both scripts create temporary,
uniquely labeled resources and remove those resources on exit without pruning
the daemon or images. CI gives each script a 12-minute deadline in a 15-minute job.

These exercise the **legacy cold physical database copy**, distinct from the
version 4 logical SQL archive workflow. Clone verifies that Apache/PHP in the
cloned Joomla image uses its independent database after the source database
stops. Migration exercises the exporter, extractor, and destination preparation
with different homes, keys, paths, and external Docker networks. It checks
source stop/restart, companion configuration packaging, scoped credentials,
HTTPS-to-HTTP realignment, private per-project environment files, and independent
file/database writes without changing the source.

These two legacy scripts use minimal JConfig/SQL fixtures. They do not run
Joomla's installer, certificate issuance, or real SSH transport. The four v4
scenarios above supply those additional checks within their stated scope.

## Validation limits

Portable installer tests use command stand-ins. They do not install Docker
Desktop, change Linux package repositories, or configure live operating-system
services. Full container acceptance currently runs only on Linux. Actual macOS
and Windows Docker Desktop deployments, OS/browser certificate-trust installation,
ACME issuance, custom proxy/DNS configurations, and Joomla extension compatibility
still require acceptance checks in the intended environment. Temporary Cloudflare
review and loopback SSH coverage do not establish production tunnel or remote
host compatibility.

Version 4 portable backups and migrations use logical SQL and site files rather
than raw database directories. Tests establish the engine/version combinations
above, including MariaDB/MySQL replacement; they do not promise arbitrary SQL
portability between database families. PostgreSQL-to-MySQL conversion is refused.
Migration creates an independent destination; production write freezes,
incremental synchronization, DNS cutover, and source deletion are outside these
acceptance scenarios. Check retained recovery paths after any failed operation.

The following restrictions describe the **legacy cold-copy paths**:

- Complete legacy Joomla migration stops source services for the filesystem
  snapshot and restarts those previously running. Its raw database archive
  requires matching architectures and an immutable database image digest.
  Unsupported named volumes, symlinks, external databases, and custom layouts
  are refused.
- Legacy folder-only migration copies files. Quiesce database services before
  moving raw database storage. Remote file migration requires rsync with
  `--protect-args` support and an SSH account that can read/write the selected
  locations; ownership changes may require noninteractive sudo.
- Legacy clone and complete migration share a repository lock. An interrupted
  process can leave `joomla/.clone.lock`; remove that empty directory only after
  verifying that no clone or migration is running. Other legacy interactive
  operations share progress files and should run sequentially.
- The expert Compose-folder transfer includes only that folder, not shared
  parent `.env` credentials or separate project volumes. Legacy complete
  migration packages these with project-scoped values. Failed or cancelled
  migration can retain credential-bearing recovery archives; inspect the
  reported destination state before retrying and remove archives after recovery.

Legacy PHP override helpers require a host `www-data` account or explicit numeric
container UID/GID values. Validate those IDs for macOS and custom images.
Windows Git Bash does not enforce Unix permission bits. Protect configuration,
credentials, and SSH directories with NTFS access controls; portable mode-bit
tests do not verify those ACLs. Pin image versions for production deployments.
Treat Docker socket access as administrative host access and configure trusted
proxy ranges explicitly when forwarding client headers.

Docker's official installation instructions do not cover SUSE. Install its
Docker packages and Compose manually before using Octojoom there.

## Required CI checks

The workflow runs for pushes to `master`/`staging`, pull requests targeting those
branches, and manual dispatch. ShellCheck v0.10.0 checks the application and test
scripts. Passing workflows only block merge when branch protection requires them.
Require all of these statuses:

- `ShellCheck`
- `Tests (ubuntu-latest)`
- `Tests (macos-latest)`
- `Tests (windows-latest)`
- `Docker clone integration`
- `Docker migration integration`
- `OctoJoom 4.0 workflow (lifecycle)`
- `OctoJoom 4.0 workflow (mysql)`
- `OctoJoom 4.0 workflow (postgres)`
- `OctoJoom 4.0 workflow (migration)`
