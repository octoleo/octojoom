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
An empty `--extensions=`, `--commands=`, or `--error-reporting=` remains an
explicit empty value. Explicit request presence is kept separately from values.

Direct options override JSON options, which override saved applicable defaults.
Per-site `.env` still **replaces**, rather than merges with, shared type `.env`.
`--repo-path` and `--project-path` select configured absolute paths. Read-only
commands and completion do not create missing configuration directories.

Text data is written to stdout; notices, progress and errors go to stderr in
headless/JSON mode. `--quiet` suppresses notices, never errors. `--no-progress`
suppresses gauges. `--verbose` is accepted as a shared logging preference;
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
Streaming `logs --follow` and interactive `shell` require text output.

| Status | Meaning |
| --- | --- |
| 0 | Operation completed |
| 1 | Operation/dependency/configuration failure (some existing operations retain more specific statuses) |
| 17 | Invalid command, missing required request input or unsupported task |
| Other nonzero | Native command failure or an existing cancellation/operation status |

### Optional JSON request

JSON is transport, never stored site metadata. `jq` is required only for JSON
requests/results; ordinary flags, menus and Bash completion do not require it.
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
without `--`, with string, boolean or number values. `args` is a literal string
array, equivalent to arguments after `--`. Unknown fields/options, NUL bytes and
invalid booleans are rejected. No request is evaluated as shell code. Supply
credentials in a protected JSON file/stdin or saved environment file rather
than putting them into shell history. Protect request files with mode `600` on
Unix, and suitable account ACLs on Windows.

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
| OpenSSH → Setup | `openssh setup` | domain, username, key, port, `--ssh-keys`, `--mount-base`, `--mount-dirs`; UID/GID default to current numeric IDs | Same setup function; scoped saved key/mount directories |
| Traefik / Portainer → Setup | `traefik setup`, `portainer setup` | domain; HTTPS requires secure email for Traefik, optional Cloudflare token | Existing templates; explicit `--enable` |
| Traefik / Portainer lifecycle | respective `enable`, `disable`, `delete` | Type/task | Original singleton service behavior |
| Expert Compose/ENV edit | existing `edit` task (TTY); automation uses `config` | `--action path|read|replace`, `--config-kind compose|env`, replacement `--file` | Selected effective path; validation before replacement; recoverable previous file |
| Settings → Edit Config | `settings config` | same config actions; global `.env` | Literal ENV validation; no shell execution |
| Settings → Basic/expert mode | `settings mode` | `--mode basic|expert` | Same `setMode` persistence |
| Settings → Paths/help/about/report issue | `settings paths`, `help`, `about`, `issues` | None | Read-only text/link output; no implicit browser launch |
| Settings → Remote OctoJoom | `settings remote` | `--remote`; interactive TTY or literal OctoJoom arguments after `--` | SSH quoted argv; child result preserved |
| Manage Domains → Add/delete/list | `domains add`, `delete`, `list` | Add/delete: `--domain` | Existing domain storage and exact matching |
| Manage Domains → Hosts edit | `domains hosts` | `--action path|read|replace`, replacement `--file` | Explicit hosts-file replacement retains backup |
| Update | `--update` or `settings update` | Optional `--channel master|staging` | Validated staged executable replacement and shell integration |
| Uninstall | `--uninstall` or `settings uninstall` | `--action script|complete|selected`; separate `--remove-deployments`, `--remove-config`, `--remove-data` booleans | Existing path protections; data removal requires its own explicit true choice |

Setup credentials/settings include `--db-name`, `--db-user`, `--db-password`,
`--db-root-password`, `--site-name`, `--admin-user`, `--admin-username`,
`--admin-email`, `--admin-password`, `--extensions`, `--commands`, `--mailcatcher`,
`--phpmyadmin`, `--persistence`, `--db-persistence`, and `--save-defaults`.
PHP setting flags are `--memory-limit`, `--max-execution-time`,
`--max-input-time`, `--max-input-vars`, `--upload-max-filesize`,
`--post-max-size`, and `--error-reporting`. Server choices additionally accept
`--nginx-image` and an explicit `--nginx-config` for custom routing equivalents.

Existing operation-specific restrictions still apply: for example, the original
cold clone/migration paths can reject unsupported named volumes or custom
storage layouts. A visible site is not a promise that every operation can safely
rewrite its configuration. Each operation reports its own limitation.

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
It discovers public task names from the installed script, local site names and
cached public image tags. Bash 4+ is required, including Homebrew Bash on macOS
and Git Bash on Windows. Native PowerShell, zsh and fish integration is not
provided.

Portable tests exercise real Bash startup loading, literal requests, isolation,
noninteractive setup/lifecycle, JSON transport, domain/configuration operations
and failure-before-mutation. The same suite runs in the existing Linux/macOS/
Windows CI matrix. Container runtime behavior belongs to the separate real
Docker acceptance jobs; mocked command tests do not establish that acceptance.
