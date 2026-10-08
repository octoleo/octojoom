# Octojoom tests

Run the complete portable suite from the repository root:

```bash
bash tests/run.sh
```

Run one area while developing:

```bash
bash tests/run.sh tests/unit/cli-menus.bats
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

## Real Docker regression

The Ubuntu CI job also runs:

```bash
bash tests/integration/clone.sh
```

This needs a running Docker daemon, Docker Compose, network access to the
official images, and permission to copy container-owned bind mounts. It uses
temporary, uniquely identified resources and removes them on exit. It checks
a real cold database copy and that Apache/PHP in the cloned Joomla image can
use its independent database after the source database is stopped. It uses a
minimal JConfig/SQL fixture; Joomla's installer and application routing are
outside this regression's scope.

## Validation limits

The portable suite tests installer commands with stand-ins. It does not
install Docker Desktop on macOS or Windows, alter Linux package repositories,
or configure live Cloudflare, public DNS, ACME, and remote SSH servers. Those
systems require deployment acceptance checks in the target environment.
Migration copies files; quiesce database services before moving raw database
storage on both source and destination. Remote file migration requires rsync
with `--protect-args` support on both systems and an SSH account that can read
the source and write the destination. Ownership and permission changes can
require noninteractive sudo on the remote host. A failed publication retains
the previous destination or reports the retained recovery backup.
Joomla clone supports the generated bind-mount layout and refuses
layouts it cannot rewrite safely, including Docker named-volume clones.
Clones run one at a time per Joomla repository. An interrupted process can
leave `joomla/.clone.lock`; remove that empty directory only after verifying
that no clone is running. Other interactive operations share progress files;
run those operations sequentially.

Container-folder migration copies that selected folder. Shared parent `.env`
credentials and separate project volumes require their own migration.
PHP overrides currently require a host `www-data` account or explicit numeric
container UID/GID values. Validate those IDs for macOS and custom images.
Pin image versions for production deployments. Treat Docker socket access as
administrative host access, and configure trusted proxy ranges explicitly
when forwarding client headers through a proxy.

Docker's official installation instructions do not cover SUSE. Install its
Docker packages and Compose manually before using Octojoom there.

Passing workflows only block merge when branch protection requires them.
Require `ShellCheck`, `Tests (ubuntu-latest)`, `Tests (macos-latest)`,
`Tests (windows-latest)`, and `Docker clone integration` on protected branches.
