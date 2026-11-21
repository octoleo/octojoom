# Commands and shell discovery

OctoJoom keeps its `--type TYPE --task TASK` interface and the same operation
functions used by the menus. Run `octojoom --help` for the task names available
in the installed executable. `--container example.test` alone still means
`--type joomla --task enable --container example.test`.

Use `--non-interactive` for automation. A supplied type/task/container with no
input terminal also selects this mode. It never installs dependencies, opens an
editor or asks a question. Missing required setup values fail before host paths,
networks or deployment files are created. An invocation without arguments still
opens the normal menu. The existing `--yes` keeps each question's original
**default**, including No for questions whose default is No; it is not a request
to enable a new site or delete data.

## Common values and output

Long options accept `--name value` and `--name=value`. Existing short options
remain available. Boolean options take `true`/`false` (`yes`/`no` and `1`/`0` are
also accepted). `--non-interactive`, `--yes`, `--sudo`, `--quiet`, `--verbose`,
`--no-progress`, `--all`, `--short`, `--follow`, and `--move-files` are switches.
`--quiet` and `--verbose` also accept an explicit boolean, and are mutually
exclusive. An empty `--extensions=`, `--commands=`, `--error-reporting=`, or `--label=` remains an
explicit empty value. Explicit request presence is kept separately from values.

Direct options override JSON options, which override saved applicable defaults.
Per-site `.env` still **replaces**, rather than merges with, shared type `.env`.
`--repo-path` and `--project-path` select configured absolute paths. Read-only
commands and completion do not create missing configuration directories.

Text data is written to stdout; notices, progress and errors go to stderr in
headless/JSON mode. `--quiet` suppresses notices and progress, never errors.
`--no-progress` and `--progress no` suppress progress; `--progress yes` requests it
where the operation supports it. Interactive long-running actions show a progress
bar with the current stage and elapsed time. Its percentage reflects completed
stages, not an estimated duration; operations without finer-grained stages keep
the percentage steady while elapsed time updates. Native authorization and input
prompts temporarily take control of the terminal. No progress dialog opens in
headless mode, without an input terminal, or with `--output json`. Text stage
messages, where supplied by the operation, go to stderr; JSON, quiet and
no-progress modes suppress them. Progress never enters stdout or changes native
command failure statuses. `--verbose` is accepted as a shared logging preference;
individual operations may provide no additional debug output. Native commands
retain their failure status. `--output json` requires `jq` and produces one
object, for example:

```json
{"success":true,"task":"info","action":"","container":"example.test","data":{},"error":null,"exit_status":0}
```

`data` contains a handler's structured object/array where available, otherwise
its text result. On failure, `success` is false and `exit_status` is nonzero;
details remain on stderr. Routine site information does not include passwords.
Explicit `config --action read` is a credential-bearing configuration view.
Streaming `logs --follow`, interactive `shell`, and the database SQL console
require text output. The SQL console also requires an input terminal;
`database --action execute --file FILE` is its noninteractive counterpart.

| Status | Meaning |
| --- | --- |
| 0 | Operation completed |
| 1 | Operation/dependency/configuration failure (some existing operations retain more specific statuses) |
| 17 | Invalid command, missing required request input or unsupported task |
| Other nonzero | Native command failure or an existing cancellation/operation status |

### Optional JSON request

JSON is transport, never stored site metadata. Structured requests default to
headless mode unless their options explicitly request interactive collection.
`jq` is required for JSON requests/results and some runtime operations. Parsing
ordinary flags and Bash completion do not require it.
Use `--input-json request.json`, or `--input-json -` to read stdin. The accepted
schema has these fields only:

```json
{
  "type": "joomla",
  "task": "setup",
  "options": {
    "key": "example",
    "domain": "example.test",
    "sub-domain": "site",
    "auto-install": false,
    "enable": false,
    "non-interactive": true
  },
  "args": []
}
```

Top-level `container` and `action` are optional. `options` uses long option names
without `--`, with string, boolean or number values. For batch database exports
and backups, `container` also accepts a nonempty string array; `options.container`
accepts the same values when no top-level container is supplied. `options.table`
accepts a string or nonempty string array. These are the only array-valued options.
`args` is a literal string array, equivalent to arguments after `--`. Unknown fields/options, NUL bytes and
invalid booleans are rejected. No request is evaluated as shell code. Supply
credentials in a protected JSON file/stdin or saved environment file rather
than putting them into shell history. Protect request files with mode `600` on
Unix, and suitable account ACLs on Windows.

Repeated `--container` and `--table` preserve each value literally: a comma in a
table name is part of that name. An explicit CLI selection replaces the complete
JSON selection on its first occurrence; further occurrences append to that CLI
selection. Batch operations accept selected containers or `--all`, not both.
A batch uses `--destination` so each site receives a distinct output filename;
a shared `--file` is rejected. Other operations retain one selected container.

```json
{
  "type": "joomla",
  "task": "database",
  "action": "export",
  "container": ["first.example.test", "second.example.test"],
  "options": {
    "destination": "/private backups",
    "compression": "gzip",
    "table": ["cms_content", "archive,2025"],
    "timestamp": false,
    "overwrite": false
  }
}
```

## Menu and command coverage

The command names below are public `TYPE__TRuST__TASK` handlers. Selections are
explicit; omitted optional choices use the operation's saved/default values.
Each new feature extends these same handlers and completion discovery.

| Menu operation | Type / task | Required selection or additional options | Data/result and completion |
| --- | --- | --- | --- |
| Joomla → Setup new container | `joomla setup` | `--key`, domain explicit/saved; optional `--env-key`, `--sub-domain`, `--image-source`, `--image-tag`, `--customize`, `--auto-install`, `--enable` | Same questionnaire/defaults/generator; image, runtime and boolean options |
| Joomla → Bulk setup | `joomla bulk` | domain, subdomain prefix; optional `--number` (2–99) and setup choices | Same bulk generator; individual deployment outcomes |
| Joomla → Website Information | `joomla list`, `info` | `info`: `--container`; list: optional `--short`, `--version-prefix` | Inventory/details; available website names |
| Selected website lifecycle | `joomla start`, `stop`, `restart`, `redeploy` | `--container`; optional service where supported | Preserves enabled state; affected services/status |
| Existing enable/disable | `joomla` or `openssh`, `enable` / `disable` | `--container` | Original enable/disable semantics and status |
| Existing all-enabled start/stop | `joomla` or `openssh`, `up` / `down` | No individual target | Original batch behavior and status |
| Selected website logs | `joomla logs` | `--container`; optional `--service`, `--tail`, `--follow` | Raw log stream/status; services and options |
| Selected website directory | `joomla path` | `--container` | Resolved actual host path; named volumes explain unavailable host paths |
| Selected website browser/folder actions | `joomla open` | `--container --action website|admin|viewer|mail|directory` | Explicitly requested native opener |
| Selected website container terminal | `joomla shell`, `exec` | `--container`; shell needs TTY, exec takes literal argv after `--` | Native terminal/child output and status |
| Selected website permission repair | `joomla permissions` | `--container`; optional numeric `--uid` and `--gid` together | Actual root; original file/directory permission helpers |
| Selected website → Change data persistence | `joomla persistence` | `--container`; `--action status|set`, independent `--persistence true|false` and `--db-persistence true|false` | Inspect storage or copy between project folders and Docker named volumes; preserve data and prior running state |
| Clone container / project folder | `joomla clone`, `clonefiles` | Clone source container and destination identity; folder clone source `--project` and destination `--target-project` | Existing clone path and collision checks |
| Delete container definition | `joomla delete`, `openssh delete` | `--container` | Original definition removal; headless never implicitly deletes project data |
| Reset project storage | `joomla reset` | `--project`, explicit `--volume web|database|both` | Existing stopped-project safety checks |
| Complete project migration | `joomla migrate` | `--container --direction push|pull --remote`, destination `--key --target-host`; optional `--enable`, `--secure` | Existing archive/checksum/destination flow |
| Complete package export/import | `joomla export`, `import` | `--archive` and source container or destination identity | Existing package worker and import helpers |
| Existing folder transfers | `joomla migratefiles`, `openssh migrate`, `directory migrate` | Explicit remote/direction/source selection | Existing scoped folder-transfer behavior |
| Existing configuration alignment | `joomla align` | `--container` or `--all`; `--action inspect|apply` | Per-site outcomes; no conversion gate |
| PHP image/settings | `joomla php` | `--container --action list|switch|settings`; candidate tag/image or setting flags | Runtime results; cached public tags only during Tab |
| Apache or Nginx/FPM | `joomla webserver` | `--container --action show|set`, `--webserver apache|nginx` | Existing installation retained; published image options |
| Document root | `joomla docroot` | `--container --action show|set`, `--docroot`; moving requires `--move-files` | Same selected-root resolver used by commands |
| Selected website → Change database | `joomla database` | `--container --action change --engine --database-image --data-mode preserve|clone|fresh --confirm yes`; clone also needs destination identity | Shared engine-change handler; explicit data intent and compatibility checks |
| Selected website → Database export / selected tables | `joomla database` | `--action export --container`; optional repeated `--table`, `--file` or `--destination`, compression/timestamp/overwrite choices | Engine-native export; literal table names and published archive result |
| Back up databases in selected/all sites | `joomla database` | `--action export`, repeated `--container` or `--all`; destination/preferences once | Same exporter; per-site outcomes and nonzero overall status on partial failure |
| Selected website → Database import | `joomla database` | `--action import --container --file --import-mode fresh|replace|merge`; optional `--delete-source yes|no` | Explicit import semantics; source deletion only after successful import |
| Selected website → Tables / SQL console / SQL file | `joomla database` | `--action tables|console|execute --container`; execute needs `--file`, console needs TTY | Native client data/status; no table discovery while completing |
| Selected website → Backups and restore points | `joomla backup` | `--action create|list|verify|restore|delete|cleanup`; scope/format/destination/label and explicit restore/deletion choices | Same backup/restore handlers; archive, digest, scope and destination outcomes |
| Back up selected/all websites | `joomla backup` | `--action create`, repeated `--container` or `--all`; shared destination/preferences | Same single-site operation; per-site results and nonzero status on partial failure |
| OpenSSH → Setup | `openssh setup` | domain, username, key, port, `--ssh-keys`, `--mount-base`, `--mount-dirs`; UID/GID default to current numeric IDs | Same setup function; scoped saved key/mount directories |
| Traefik / Portainer → Setup | `traefik setup`, `portainer setup` | domain; HTTPS requires secure email for Traefik, optional Cloudflare token | Existing templates; explicit `--enable` |
| Traefik → Prepare local HTTPS | `traefik update` | none | Preserves existing proxy settings, prepares missing local HTTPS support; a stopped proxy stays stopped |
| Traefik / Portainer lifecycle | respective `enable`, `disable`, `delete` | Type/task | Original singleton service behavior |
| Expert Compose/ENV edit | existing `edit` task (TTY); automation uses `config` | `--action path|read|replace`, `--config-kind compose|env`, replacement `--file` | Selected effective path; validation and unchanged Compose project name before replacement; original running state preserved; recoverable previous file |
| Settings → Edit Config | `settings config` | same config actions; global `.env` | Literal ENV validation; no shell execution |
| Settings → Basic/expert mode | `settings mode` | `--mode basic|expert` | Same `setMode` persistence |
| Settings → Paths/help/about/report issue | `settings paths`, `help`, `about`, `issues` | None | Read-only text/link output; no implicit browser launch |
| Settings → Remote OctoJoom | `settings remote` | `--remote`; interactive TTY or literal OctoJoom arguments after `--` | SSH quoted argv; child result preserved |
| Manage Domains → Add/delete/list | `domains add`, `delete`, `list` | Add/delete: `--domain` | Existing domain storage and exact matching |
| Manage Domains → Hosts edit | `domains hosts` | `--action path|read|replace`, replacement `--file` | Explicit hosts-file replacement retains backup |
| Update | `--update` or `settings update` | Optional `--channel master|staging` | Validated staged executable replacement and shell integration |
| Uninstall | `--uninstall` or `settings uninstall` | `--action script|complete|selected`; separate `--remove-deployments`, `--remove-config`, `--remove-data` booleans | Existing path protections; data removal requires its own explicit true choice |

Setup credentials/settings include `--db-name`, `--db-user`, `--db-password`,
`--db-root-password`, `--db-prefix`, `--site-name`, `--admin-user`, `--admin-username`,
`--admin-email`, `--admin-password`, `--extensions`, `--commands`, `--mailcatcher`,
`--phpmyadmin`, `--persistence`, `--db-persistence`, and `--save-defaults`.
Single and bulk setup default both persistence flags to `true`, keeping website
and database files under the site's project folder. An explicit `false` selects
a local-test Docker named volume for that storage; such a site cannot use
complete-project migration or cold cloning.

For existing sites, `--task persistence` shows current storage when no storage
flags are supplied. Either flag implies `--action set`; omitted flags leave
that store unchanged. `true` selects the site's canonical project folder and
`false` selects a Docker named volume. The menu's **Change data persistence**
action uses the same stopped-copy and verification operation. See
[setup and persistence](SETUP-DEFAULTS.md#change-an-existing-sites-persistence).

Database setup accepts `--engine` (alias `--db-engine`) with `mariadb`, `mysql`,
or `postgres` (`postgresql` is an accepted spelling), and `--database-image`
(alias `--db-image`) with an explicit published image reference. Engine choices
remain subject to the selected Joomla/PHP driver's capabilities.
PHP setting flags are `--memory-limit`, `--max-execution-time`,
`--max-input-time`, `--max-input-vars`, `--upload-max-filesize`,
`--post-max-size`, and `--error-reporting`. `--free-ports true` explicitly permits the existing Traefik flow to stop known
conflicting host web services; its default leaves them alone. `--update-hosts`
controls the existing host-entry preference. Server choices additionally accept
`--nginx-image` and an explicit `--nginx-config` for custom routing equivalents.

Existing operation-specific restrictions still apply: for example, the original
cold clone/migration paths reject named-volume local-test sites and unsupported custom
storage layouts. A visible site is not a promise that every operation can safely
rewrite its configuration. Each operation reports its own limitation.

## Database and backup requests

Database changes require explicit `--engine`, `--database-image`,
`--data-mode preserve|clone|fresh`, and `--confirm yes`. These choices are not
inherited from saved setup defaults. A clone additionally needs its destination
identity; a fresh target starts empty.

A single database export can name its output exactly, including spaces:

```bash
octojoom --type joomla --task database --action export \
  --container demo.example.test --file '/private backups/demo.sql.gz' \
  --compression gzip --timestamp no --overwrite no --non-interactive
```

Use `--compression none|gzip|custom`; `custom` is PostgreSQL's native archive
format and requires its matching restore client. Import requires an explicit
`--import-mode fresh|replace|merge`; the shared handler checks that mode against
the actual database before applying input. `--delete-source no` retains the
input file and is the default. `--pre-backup yes` requests a backup before the
import and stops the import if that backup fails. Database credentials come from the selected
site's protected configuration; routine results never include SQL contents or
passwords. Supply setup/replacement credentials through saved ENV or protected
JSON input instead of process-visible command arguments.

Backups accept `--scope full|website|database|files` and `--format tar.gz|zip`.
Website scope includes both website files and SQL; files scope explicitly omits
the database. `--label`, `--destination`, `--timestamp yes|no`, and
`--overwrite yes|no` select the saved/default naming and publication choices.
`--timestamp-pattern` overrides the saved UTC `date` pattern, whose default is
`%Y%m%dT%H%M%SZ`. Its output must contain only letters, digits, dots, underscores,
or hyphens, so the timestamp cannot create directories or change archive paths.
`--retention COUNT` keeps the newest COUNT selected-site backups; zero disables
retention deletion. Cleanup and delete require `--confirm yes`.

```bash
octojoom --type joomla --task backup --action create \
  --container first.example.test --container second.example.test \
  --scope full --format tar.gz --destination '/private backups' \
  --timestamp yes --overwrite no --non-interactive --output json

octojoom --type joomla --task backup --action restore \
  --file '/private backups/before-change.tar.gz' --target new \
  --key review --domain example.test --sub-domain review --non-interactive
```

Verification and restore to a new independent site can use an archive even
when its source site no longer exists. Restoring into an existing site requires
`--target current`, that site's `--container`, `--pre-backup yes`, and
`--confirm yes`. Listing, deletion, and retention cleanup remain scoped to the
selected site. A checksum confirms archive integrity; successful restoration
also depends on the supported payload, engine, and storage checks in the shared
restore handler. Batch JSON includes each site's outcome inside the normal
result envelope, with a failing overall exit status if any selected site fails.

## Automatically installed Bash discovery

Ordinary initialization/setup and successful update install the embedded
completion script in `~/.local/share/bash-completion/completions/octojoom`.
Owned loader lines are added idempotently to `.bashrc` and the first existing
Bash login startup file (`.bash_profile`, `.bash_login`, `.profile`), preserving
login-file precedence. A `.profile` loader is guarded so non-Bash shells do not
execute Bash completion. Symlinked startup files remain symlinks. Uninstall
removes only the owned loader lines and completion file.

A **new Bash shell** automatically provides Tab candidates and `octojoom_cd
HOSTNAME`, whose `cd` affects that calling shell. An already-running shell
cannot be changed by a child executable. Completion is local/read-only: no
Docker calls, network requests, dependency installation or credential values.
It discovers public task names from the installed script, task-specific actions,
local site names, local archive paths, and cached public image tags. Database
engine, compression, scope, format, and intent choices are available without
connecting to a database; table names are supplied explicitly. Bash 4+ is required, including Homebrew Bash on macOS
and Git Bash on Windows. Native PowerShell, zsh and fish integration is not
provided.

Portable tests exercise real Bash startup loading, literal requests, isolation,
noninteractive setup/lifecycle, JSON transport, domain/configuration operations
and failure-before-mutation. The same suite runs in the existing Linux/macOS/
Windows CI matrix. Container runtime behavior belongs to the separate real
Docker acceptance jobs; mocked command tests do not establish that acceptance.
