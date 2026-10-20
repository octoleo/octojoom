# Joomla addon capability mapping

This maps the reviewed DDEV Joomla addon utilities to OctoJoom's Joomla-only interface. The site dashboard exposes the same operations. OctoJoom keeps its own Compose layout, scoped environment, single-script Bash distribution and existing server deployment paths.

| Reviewed utility | OctoJoom equivalent |
| --- | --- |
| `jaddsite` | `site create`, including PHP, Apache/Nginx, database, optional document root and manual installation. |
| `jdelsite` | `site delete --delete-data --yes`; omission of delete-data retains recovery data. |
| `jclone` | `site clone` with independent files/database and explicit target identity. |
| `jphpswitch` | `site php`, preserving the installed Joomla release. |
| `jlatest` | `site download` for latest, exact or checksummed custom Joomla sources into a new directory. |
| `jdbdump` | `database export`. |
| `jdbdumpall` | `database export --all` or explicit JSON sites array. |
| `jdbdumptable` | `database export --tables '["table_name"]'`. |
| `jdbimp` | `database import` with recovery dump and failed-import recovery. |
| `jbackup` | `backup create --scope full|site --format tar.gz|zip`. |
| `jbackupall` | `backup create --all`, with per-site results. |
| `joomlainfo` | `site info`, runtime health and versions. |
| `jsetconfig` | `site realign`; `--development-label` sets the development label. |
| `gosite` | `site path`, `site open --target directory` and the optional shell wrapper below. |
| `jlistjoomlas` | `site list`, including state and Joomla-version filters. |
| `setrights` | `site permissions --yes`. |
| `jddev` | `site help`, `site schema` and the per-site dashboard. |
| `jddev-status` | `site diagnose` for the host or a selected site. |
| `jddev-update` | `update apply`, with staged validation and recovery copy. |
| `jddev-checkupdate` | `update check`; it reports availability without installing an update. |
| `jxdb`, `jddev-vsc-xdb` | Deferred with Xdebug to the official-container development track. |

A child process cannot change its parent shell's working directory. Add this optional function to your Bash shell configuration for the `gosite` behavior:

```bash
octocd() {
  local response destination
  response=$(octojoom site path --site "$1" --json) || return
  destination=$(jq -er '.data.path' <<< "$response") || return
  cd -- "$destination"
}
```

OctoJoom additionally includes local mkcert HTTPS, per-site temporary external sharing, Mailpit integration, optional Node/Redis services, developer commands, lifecycle hooks, restore points, database engine choices, offline image preparation and one-archive remote migration. Automatic Joomla core upgrades by replacing a container remain deferred.
