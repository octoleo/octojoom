# OctoJoom 4.0.0 implementation

This branch implements the agreed Joomla development and operations workflow while preserving the standalone Bash distribution and existing deployment paths.

## Scope and completion gates

- [ ] Shared noninteractive command API, validated JSON input/output, and documented exit codes.
- [ ] Per-site dashboard/menu using the same operations as terminal commands.
- [ ] Site inventory, actual runtime information, quick access, logs and diagnostics.
- [ ] Database export/import, selected tables, SQL access and batch operations.
- [ ] Verified full/portable backups, restore, named restore points and cleanup.
- [ ] Logical one-archive migration, source-preserving clones and external Joomla import.
- [ ] PHP switching within the same Joomla version with health checks and recovery.
- [ ] Apache and Nginx/FPM, configurable document roots and configuration realignment.
- [ ] MariaDB, MySQL and supported PostgreSQL configurations; safe engine/version change flows.
- [ ] Local trusted HTTPS and per-project temporary external sharing.
- [ ] Existing-site email capture and optional project services.
- [ ] Container development tools, lifecycle hooks, offline preparation and update notices.
- [ ] Cross-platform command tests, real-container integration tests, documentation and 4.0.0 version metadata.

Xdebug and automatic Joomla core upgrades by replacing an image are deferred. Switching PHP for the same installed Joomla release is included. Cross-family database conversion must never be implied by a successful image change: unsupported data conversions are refused before mutation; a fresh independent target is a separate explicit operation.

## Architectural requirements

The TUI collects inputs and invokes the same Bash handlers as the terminal API. Noninteractive operations never invoke whiptail or install host dependencies implicitly. Requests have a versioned JSON representation; results, errors and exit status form a stable desktop integration contract. Passwords and other secrets must not appear in normal status output or diagnostic errors.

Retain project-scoped environment resolution, atomic publication, source preservation, collision checks and the single compressed archive migration model. Local certificate authorities belong to the host and must never be packaged as project credentials. A complete operation includes failure handling and recovery; a menu label or generated configuration alone does not satisfy a completion gate.

Each feature is developed in incremental commits on this branch. The pull request contains the live progress checklist and validation results. This document records the agreed scope and is updated as gates are verified.
