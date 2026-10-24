# Website Information

Open **Joomla Containers → Website Information**, select a website, and select an
action. The details refresh after each action. Back returns to the website list,
then the original Joomla menu. Existing Compose directories appear immediately;
no registration, conversion or additional project record is needed.

## Information and actions

The selected website opens with focus in its information area. This area shows
up to ten lines at a time; on shorter terminals it uses less space so the actions
remain visible underneath. The complete report is available by scrolling.

- **Up/Down** or **Page Up/Page Down** scroll the information.
- **Tab** moves from the information to the actions. Use **Up/Down** to choose an
  action, then **Enter** to select it.
- **Shift+Tab** returns from the actions to the information. Further Tab presses
  cycle through the **Select** and **Back** buttons using normal whiptail behavior.
- **Back** or **Escape** leaves the selected website without running an action.

The dialog uses the usual 112-column width when space permits and fits inside
narrower terminals. Long paths, URLs and image identifiers wrap within the
information area; the report is neither shortened nor horizontally scrolled.
Its length does not reduce the action-list height. A 24-row terminal provides
eight action rows; taller terminals show more. The remaining actions are reached
by scrolling the list.

The layout is recalculated whenever the website dialog opens or refreshes after
an action. Whiptail does not rearrange an already-open dialog when the terminal
is resized; close and reopen the website details after resizing.

This uses the existing whiptail controls. Some whiptail/newt versions draw an
incomplete right border around a menu with scrollable text, and Debian/Ubuntu
builds can also hide the information scrollbar
([newt issue 945320](https://bugs.debian.org/945320)). The text still wraps and
scrolls with the keys above, and the action-list scrollbar remains available.

## Website state and details

The list includes enabled and disabled websites. Enabled normally means the
enabled symlink points at that site's available directory. Git Bash can copy a
directory instead of creating a native symlink; that entry is recognized only
while its Compose file and any private `.env` match the available site. Stale
copies and incorrect links are reported as invalid. Running service state and
health are inspected separately. An unavailable Docker daemon is reported as
unavailable, not stopped. Viewing information never starts or redeploys a site.

The details show the configured and actual running image, measured PHP version,
installed Joomla version, services, document root, storage, Compose and effective
ENV paths. An image tag does not establish the installed Joomla version: the
reader checks the installed manifest. Unknown versions remain in unfiltered
inventory and are excluded from release-prefix filters.

Website, administrator and companion-tool links come from the site's router
labels and the proxy's published port, or a directly published HTTP port. A route with an unsupported expression or
an unresolved proxy port is unavailable. The information screen does not claim
that configured routes are reachable: `routable` remains `unchecked` until an
action actually checks them. General information and JSON omit credentials.
Experts can explicitly open the effective ENV file to recover saved credentials;
the menu warns when it is a shared file used by other websites.

The selected site's **Database tools**, **Change database**, and **Backups and
restore points** actions use that same site selection and return to refreshed
details. Their options and data behavior are documented in [database tools](DATABASE-TOOLS.md),
[database engines](DATABASE-ENGINES.md), and [backups](BACKUPS.md). The Joomla
menu also offers **Back up websites** for a selected group or all discovered
websites, using the same backup operation as the individual-site action.

## Commands

The original `--type` and `--task` grammar is retained:

```bash
octojoom --type joomla --task list --short --non-interactive
octojoom --type joomla --task list --version-prefix 6.2 --output json --non-interactive
octojoom --type joomla --task info --container demo.example.test --output json --non-interactive
octojoom --type joomla --task path --container demo.example.test --non-interactive
octojoom --type joomla --task stop --container demo.example.test --non-interactive
octojoom --type joomla --task start --container demo.example.test --non-interactive
octojoom --type joomla --task restart --container demo.example.test --non-interactive
octojoom --type joomla --task redeploy --container demo.example.test --non-interactive
octojoom --type joomla --task logs --container demo.example.test --service joomlademo --tail 100 --non-interactive
```

`start` runs Compose `up -d`; `stop` stops this site's services; `restart` restarts
its current containers; `redeploy` recreates them from current configuration.
These commands preserve enabled/disabled state and do not remove volumes or
implicitly pull newer images. Existing `up` and `down` tasks still operate on all
enabled sites. Enable/disable retain their original platform behavior; a failed
enable may leave the site enabled even though services could not start.

Logs default to the latest 100 lines of all services. `--service` selects a
configured service; `--tail` adjusts the line count and `--follow` follows live
logs. The menu uses a bounded viewer that closes back to the selected site.
Native Compose failures propagate their status.

`--task open --action website|admin|viewer|mail|directory` explicitly launches
the matching platform application. `--task shell` requires an interactive
terminal. `--task exec -- COMMAND ARGS...` passes a literal native argument array
to the selected service at its document root, without shell reconstruction.
`--task permissions` repairs modes using the original Joomla helpers at the
selected bind-mounted root; optional `--uid` and `--gid` together request an
ownership change. Headless permission repair uses noninteractive sudo.

The original whole-project repair is also available as `--task fix --project
PROJECT --uid UID --gid GID --non-interactive`. It preserves the original Joomla
and MariaDB directory repair behavior, including MariaDB's original UID/GID 999.
It requires a direct existing project and both numeric IDs before making changes.
This command does not implement a new database-engine ownership detector.

The `path` command returns a real bind-mounted host document root. A named
volume has no fabricated host path: use the selected site's container shell.
Scoped document-root settings are resolved under the actual mounted root.

## Read and isolation rules

- Inventory is `joomla/available/*/docker-compose.yml`.
- A site `.env` replaces the shared Joomla `.env`, matching Compose selection.
- Inspection never sources ENV or prints resolved Compose containing secrets.
- Each selected-site Compose invocation removes inherited exports for referenced
  variables, including custom default expressions, before reading the effective
  ENV. Shell expressions are never evaluated by Octojoom.
- Compose JSON with optional `jq` supplies structured inspection of custom YAML.
  Without it, bounded readers recognize original Octojoom block formatting;
  unsupported facts remain unknown while the site and lifecycle stay available.
- Named-volume facts keep the logical Compose source separate from the actual
  daemon volume name. Runtime probes must use the latter and check its existence.
- PHP/webserver/alignment actions share the same selected identity and facts.
  Original clone/migration restrictions still apply to their specific operations.

## Evidence and limits

`tests/unit/site-information.bats` covers original inventory, shared and per-site
ENV isolation, nonstandard project keys and proxy ports, missing Docker, partial
and unhealthy state, named volumes, installed-version filtering, nested roots,
selected lifecycle behavior, native failures, exported-variable isolation,
menu return navigation, JSON redaction and structured custom layouts.

Portable tests use sandboxed Docker stand-ins. They do not establish real route
reachability, administrator login, browser launch support or platform-specific
file-manager behavior. Real Docker lifecycle acceptance belongs to the integration
suite and its CI result, separately from portable test results.
