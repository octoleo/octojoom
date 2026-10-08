# Octojoom tests

Run the complete portable suite from the repository root:

```bash
bash tests/run.sh
```

Run one area while developing:

```bash
bash tests/run.sh tests/unit/cli-menus.bats
```

Run the migration suites together:

```bash
bash tests/run.sh tests/unit/migration-package.bats tests/unit/migration-import.bats \
  tests/unit/migration-flow.bats tests/unit/migration-remote.bats
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
| Configuration and dialogs | Secret persistence, literal input, permissions, validation, random values, and prompt cancellation |
| Joomla setup | Single and bulk deployment, generated Compose, environment values, persistence, and feature options |
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
```

These need Linux, a running Docker daemon, Docker Compose v2, network access to
the official images, and root or passwordless sudo for container-owned bind
mounts. Migration also requires GNU tar and gzip. Both scripts create
temporary, uniquely labeled resources and remove those resources on exit.
They never prune the daemon or its images.

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

Both use minimal JConfig/SQL fixtures. They do not run Joomla's installer,
public routing, certificate issuance, or a real SSH transport. The portable
flow tests verify push/pull orchestration with command stand-ins; destination
activation tests simulate proxy, health, and HTTP/HTTPS failures. Deployment
acceptance still needs the intended hosts, proxy, DNS, and extension settings.

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
layouts it cannot rewrite safely, including Docker named-volume clones.
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
PHP overrides currently require a host `www-data` account or explicit numeric
container UID/GID values. Validate those IDs for macOS and custom images.
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
`Tests (windows-latest)`, `Docker clone integration`, and
`Docker migration integration` on protected branches.
