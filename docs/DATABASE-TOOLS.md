# Database tools

Open **Joomla → Website Information → choose a website → Database tools**.
The selected database, actual engine and Compose service appear without
credentials. Export, import, table selection, SQL console and SQL-file execution
use the same functions as the CLI. Batch export supports explicitly selected
websites or all discovered Joomla websites.

The tools support MariaDB, MySQL and PostgreSQL using the clients in the selected
published database container. They discover actual binaries, including modern
`mariadb`/`mariadb-dump` names, and check dump options against native client help.
No database software is installed on the host. Docker Compose and `jq` are
required; gzip supports compressed SQL and optional `pv` supplies import progress.

## Commands

```bash
octojoom --type joomla --task database --container demo.example.test \
  --action export --file '/backups/demo.sql.gz' --compression gzip --non-interactive

octojoom --type joomla --task database --container demo.example.test \
  --action export --table 'abc_content' --table 'comma,name' \
  --destination /backups --timestamp no --overwrite no --non-interactive

octojoom --type joomla --task database \
  --container first.example.test --container second.example.test \
  --action export --destination /backups --compression gzip --output json --non-interactive

octojoom --type joomla --task database --all --action export \
  --destination /backups --timestamp yes --non-interactive

octojoom --type joomla --task database --container demo.example.test \
  --action import --file '/backups/demo.sql.gz' --import-mode replace \
  --pre-backup yes --delete-source no --non-interactive

octojoom --type joomla --task database --container demo.example.test --action tables --output json
octojoom --type joomla --task database --container demo.example.test --action execute --file changes.sql --non-interactive
octojoom --type joomla --task database --container demo.example.test --action console
```

Repeated `--table` and `--container` arguments preserve literal names. JSON
requests also accept arrays. Commas are never treated as separators. Table
selection comes from the actual selected database; an empty interactive selection
cancels without creating an export. Names containing control characters require
the native console. The console requires a terminal and cannot run as JSON or
noninteractive output.

A supplied `--file` stays exact unless `--timestamp yes` is explicitly requested.
Its `.sql`, `.gz` or `.dump` extension selects plain SQL, gzip SQL or a PostgreSQL
native archive when compression was not supplied. Without an explicit filename,
site names and the saved timestamp/compression choices determine filenames.
`--compression custom` is PostgreSQL-only and uses `pg_dump`/`pg_restore`.
Existing files require explicit `--overwrite yes`.

Successful user exports save `VDM_<ENVKEY>_DATABASE_EXPORT_DIR`,
`VDM_<ENVKEY>_DATABASE_COMPRESSION` and `VDM_<ENVKEY>_DATABASE_TIMESTAMP` in the
selected site's complete effective ENV. New site files preserve all required
Compose references and recognized settings for that site, excluding other sites'
secrets. Distinct host `VDM_DATABASE_*` defaults are initialized only when absent.
Existing host defaults are not changed by another site's export. Read-only table
listing and console access do not save preferences. Backup's lower-level export
API does not change these user preferences.
Successful user imports separately save `VDM_<ENVKEY>_DATABASE_IMPORT_DIR` and
initialize the matching host default, so the file chooser remembers its own
last successful location without changing the export destination.

## Import semantics

`--import-mode` is required explicitly for noninteractive imports:

- `fresh` requires an empty selected database before executing any input.
- `replace` executes the native dump's own scoped DROP/CREATE statements. Exported
  dumps describe only their selected database or selected tables. The tool never
  clears unrelated tables automatically.
- `merge` executes the supplied SQL as written without preliminary clearing. It
  does not remove destructive statements already present in a user-supplied file.

SQL is an intentional expert input, not parsed or rewritten by Octojoom. To
restore selected tables, first export those tables and import that resulting file.
Arbitrary plain SQL is not filtered into tables. PostgreSQL custom archives use
native restoration with error-stop and a transaction; `replace` adds native
clean/if-exists options. Plain PostgreSQL input uses `psql` with `ON_ERROR_STOP`
and a single transaction. MySQL/MariaDB batch clients stop on errors, but DDL can
be partially committed. Keep a backup before replacement. The menu offers this
backup, and `--pre-backup yes` requests the same shared backup action.

Gzip integrity is checked before connection or writes. Native errors, incomplete
compressed files, missing resulting tables or failed Joomla connectivity checks
retain the input. Source deletion happens only after every successful check and
only when explicitly requested. A plain SQL prefix ending at a valid statement
boundary cannot reliably be identified as truncated; checksummed backup packages
provide that additional integrity evidence.

## Isolation and verification

The actual installed Joomla connection must agree with the selected Compose
connection. Its host must identify exactly one service in that project. External
or ambiguous database hosts are refused with an actionable diagnostic. The tools
never choose a similarly named service from another website. Stopped service
capabilities can be inspected in a read-only container, but data operations do
not start database services automatically.
Connectivity verification uses the installed driver's PHP extension: modern
Joomla `pgsql` uses `pdo_pgsql`, while legacy `postgresql` uses `pgsql`. PDO
database-name fields containing semicolons cannot be represented faithfully by
that driver's DSN and fail verification rather than connect to a changed name.

Client credentials are sent through stdin into a private temporary option or
password file inside that database container, and removed after the operation.
Passwords do not appear in command arguments, routine output or JSON results.
Native failure diagnostics are captured privately and reduced to a safe error
category and corrective guidance; SQL text and values are not echoed. Explicit
SQL execution and the interactive console return the results the user requested.

Exports use adjacent private temporary files. Both native client and compression
must succeed, and output must be nonempty before publication. Failure preserves
an existing destination. No-clobber publication also protects against a competing
export creating the same filename. MySQL/MariaDB transactional snapshot flags
cover transactional tables; nontransactional tables and coordinated website-file
backups require quiesced writes. PostgreSQL uses its native consistent dump.
A live SQL export alone is not a consistent whole-website backup.

`--quiet` suppresses routine text, while JSON retains per-site results and exit
status. `--verbose` adds selected-client/service diagnostics without secrets.
`--progress yes` requires `pv` and writes progress only to stderr. A failed batch
row makes the overall operation fail while preserving results for the other rows.

The behavior tests cover targeting, credential transport and cleanup, literal
names, overwrite/compression failures, deletion ordering, preferences, batch
results and the shared menu/CLI path. `tests/integration/database-backups.sh`
exercises real engine exports/imports, selected tables, Unicode/binary values,
invalid SQL, truncated gzip and independent sites in Docker CI.
