# Deploy a JoomEngine Playground package

Open **Joomla → Deploy Joomengine Playground packages** and enter the full path
to a complete Playground ZIP on the computer running Octojoom. The entry is
available on an empty installation. Review the package summary to launch a new
site, replace a managed site, or return to the Joomla menu. A fresh deployment
requires a new project key and hostname.

## Inspect a package

```bash
octojoom --type joomla --task playground --action inspect \
  --file '/home/user/Downloads/Clothing Store.zip' --non-interactive
```

Add `--output json` for the usual Octojoom result envelope. The package summary
is in `data`. Python 3 is required for the ZIP reader. Package-only inspection
works offline and requires no Docker daemon or configured destination.

The reader accepts complete schema-1 `joomengine-playground-export` bundles.
It reads the installed Joomla files under `site/` and checks the version in
the Joomla manifest against `export.json`. The bundle also includes
`database.sql`, `database.ndjson`, and `DEPLOYMENT.md`. Inspection streams the
members, checks their ZIP integrity, and verifies the Playground payload
checksum when provided. Older schema-1 exports can omit this checksum. The
output identifies that case explicitly. The separate archive SHA-256 identifies
the exact ZIP that was inspected.

The summary includes the site name, installed Joomla version, exported and
preferred PHP versions, database prefix, table count and website file count.
The administrator username and minimum PHP version appear when supplied.
Administrator passwords, Joomla secrets, and database contents stay private.
Files-only exports, SQL-only exports and Octojoom backup archives use other
formats. Select the complete site export from Playground for this command.

The reader accepts archives up to 2 GiB, with up to 100,000 entries and 4 GiB
of expanded data. The JSON metadata and Joomla manifest can each be up to
1 MiB. Reading and hashing happen in place, without extracting the website.

## Launch a fresh site

Choose a project key, domain, TLS settings, image source, webserver, database
and storage as in **Setup new container**. The package supplies the initial
site name and administrator details. Confirm or edit the site name, display
name, login username and email. Leave the password prompt blank to retain the
exported password. Before creating the site, review the destination and the
selected runtime and confirm the deployment. Octojoom writes the confirmed values to the new site's
private `.env` and applies them to the installed site and its imported account.

For example, this deploys a package to `shop.example.test` on the local Docker
host using the official Joomla image and MariaDB. The archive path, project key
and domain identify the deployment.

```bash
octojoom --type joomla --task playground --action deploy --target new \
  --file '/home/user/Downloads/Clothing Store.zip' \
  --key shop --domain example.test --sub-domain shop \
  --image-source joomla --engine mariadb --enable true --non-interactive
```

To supply account changes in automation, pass a private request file with
`--input-json` or read it from standard input with `--input-json -`. Supported
options include `site-name`, `admin-user` (display name), `admin-username`,
`admin-email` and `admin-password`. Restrict access to any file containing a
password. An unattended deployment enables the new site by default.
Add `--output json` to receive the site name, URL, image and
enablement state in `data`. See [the request format](COMMANDS.md).

If someone renamed the administrator inside Joomla before export, enter the
current Joomla login at the administrator username prompt or supply it with
`--admin-username`. When the saved login is missing, Octojoom checks that the
specified account matches the export's administrator email. If that email also
changed, select the existing account explicitly with `--source-admin-username`
and confirm its current details. To rename the selected account on deployment,
use both names, for example `--source-admin-username owner --admin-username shopmanager`.
The same options apply when replacing an existing site. The account retains
its Joomla user ID and group memberships.

Octojoom checks the selected image against the installed Joomla version,
webserver, PHP requirements and database driver. By default it uses the
package's preferred PHP series and imports the supported PHP settings. The
site's SQL is imported into a fresh MariaDB or MySQL database with the
original table prefix. Octojoom uses the exporter's statement index to identify
row values that need conversion for the selected database. This preserves
numeric IDs and flags on MySQL and accented text in older character sets on
both engines. Joomla keeps its exported secret. Its database
connection, log and temporary paths, mail and site settings are adapted to
the destination. The complete website already contains Joomla and its
extensions, so deployment skips installation.

The import is a step in the normal Joomla setup. It seeds the website storage,
starts only the database needed for the import, imports the SQL and adapts
`configuration.php`, PHP settings and the administrator account. It then uses
the ordinary enable/start path. The Joomla installer is not run, and the
website is not started in a separate temporary project first.

Choosing **Yes** to enable starts the configured site. Choosing **No**, or
passing `--enable false`, registers it as available and leaves its containers
stopped. Both project-directory storage and Docker named volumes retain the
imported data between starts. Setup refuses an occupied destination.

## Replace an existing site

Choose **Replace an existing Joomla site**, select its hostname, choose whether
to take a backup, and keep the Playground settings or choose **Edit**. Replacement writes the
exported website files and SQL to the selected site's existing storage. Files
and tables that belonged only to the previous site are removed.

The backup question defaults to **Yes**. With that choice, Octojoom creates
and verifies its normal full-site backup before the first destructive write.
The archive includes the old website files, logical SQL, Compose definition,
selected site's effective environment settings and referenced configuration.
A shared environment is scoped to the selected site in the archive. If the
backup cannot be created or verified, the overwrite does not begin and the
previous service state is restored.

Choosing **No** at the backup question opens a second warning that the old
website files and database data will be lost. **Yes** at the warning authorizes
replacement without a backup. **No** returns to the backup question, with
**Yes** selected again. Skipping the backup does not create an old-data copy
elsewhere and does not promise recovery of data overwritten by a failed import.

For an unattended replacement with the default full backup, specify one
managed hostname and explicitly confirm the replacement:

```bash
octojoom --type joomla --task playground --action deploy --target current \
  --container shop.example.test --file '/home/user/Downloads/Clothing Store.zip' \
  --confirm yes --non-interactive --output json
```

To deliberately skip the backup, add both `--pre-backup no` and
`--confirm-no-backup yes` to the same command. The general `--yes` switch
cannot approve skipping the backup.

### Import into the existing site

The selected Compose project supplies the Joomla service, its document root,
and its MariaDB or MySQL database connection. Octojoom uses the site's current
image, routing, Compose file, environment and PHP configuration. The app can be
stopped and the previous Joomla installation can be broken.

The Playground export supplies the website files, SQL, table prefix and Joomla
secret. Octojoom adapts the imported configuration to the destination database.
When the old `configuration.php` can be reused, its hosting and mail settings
carry over. When it is missing or unusable, Octojoom uses the exported
configuration as the starting point. Administrator edits apply to the imported
Joomla account.

### Running and stopped sites

For a running site, Octojoom pauses its writers, imports the package and resumes
the services that were running. For a stopped site, it starts the database for
the import and stops it afterward. Keeping the imported account preserves its
SQL password hash. If you edit the administrator, a one-off PHP process applies
the change with Joomla’s user API.

A requested full backup must succeed before the import writes data. If an error
occurs before the first write, Octojoom restores the previous service state.
After a partial write it leaves the writers stopped and reports the failed step
and verified backup path, when available. A backup of an already broken site
contains the files and SQL as they were at the time.

### Read the replacement result

With `--output json`, inspect the normal result envelope and `data.status`.
The command returns a nonzero exit status for a failed import.

| Field | Meaning |
| --- | --- |
| `target`, `site` | `current` and the selected managed hostname |
| `status` | `deployed` on success or `failed` when the operation did not complete |
| `stage`, `reason` | The completed or failed step and its explanation |
| `destructive_started` | Whether writes that can replace existing data began; `null` means the operation result could not be read and the site must be inspected |
| `enabled` | The site's enabled registration |
| `running` | The observed running state, or `null` if it could not be established |
| `backup` | The verified normal backup archive path, or `null` when none was created |

A backup path is reported only after verification. Keep that archive for as
long as the previous site is needed. A successful backup opt-out leaves no
archive, old storage copy, private stack or recovery directory behind.
See [Verifying and restoring backups](BACKUPS.md) for the existing recovery
commands.

## Inspect an existing host

To check an Octojoom-managed destination, add its hostname explicitly.

```bash
octojoom --type joomla --task playground --action inspect \
  --file '/home/user/Downloads/Clothing Store.zip' \
  --container shop.example.test --output json --non-interactive
```

This optional check reads the site's effective Docker Compose settings and the
local Docker daemon's metadata. It identifies the configured application image,
the connected MySQL or MariaDB service, and their storage. A stopped site can
be inspected. Inspection does not start services or contact an image registry.

In JSON output, `data.targetPreflight.runtimeCandidate` contains the existing
Compose image reference, including any digest. `runtimeCheck` identifies it as
the configured application image. The package's preferred PHP version appears
separately in the archive metadata.

The result also reports available bytes on filesystems the
host can measure. A Docker Desktop volume can have an inaccessible mountpoint,
so its capacity may be unknown. The website file size gives a lower bound.
An SQL dump gives the size of the import file; the initialized database and a
backup require their own capacity estimate when the deployment options are known.
