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

Octojoom starts the imported site privately to confirm Joomla can connect to
the database and serve its home page. Choosing **Yes** to enable starts the
published site. Choosing **No**, or passing `--enable false`, registers it as
available and leaves its containers stopped. Both project-directory storage
and Docker named volumes retain the imported data between starts. Setup
refuses an occupied destination. If provisioning fails, it cleans up the
new site's resources and reports when any private recovery files remain.

## Replace an existing site

Choose the existing-site option, select the website by its hostname, and
confirm that its Joomla files and database tables should be replaced with the
package contents. The backup question defaults to **Yes**. With that choice,
Octojoom creates and verifies a full backup of the old website before switching
over. If the backup fails, the replacement stops.

Choosing **No** at the backup question opens a second warning that the old
website files and database data will be lost. **Yes** at the warning authorizes
replacement without a backup. **No** at the warning returns to the backup
question, with **Yes** selected again.

For an unattended replacement with the default full backup, specify one
managed hostname and explicitly confirm the replacement.

```bash
octojoom --type joomla --task playground --action deploy --target current \
  --container shop.example.test --file '/home/user/Downloads/Clothing Store.zip' \
  --confirm yes --non-interactive --output json
```

To deliberately skip the backup, add both `--pre-backup no` and
`--confirm-no-backup yes` to the same command. The general `--yes` switch
cannot approve skipping the backup.

Existing-site replacement runs on the local Docker host. It requires an installed
Joomla site using MariaDB or MySQL, with dedicated project-directory storage
or ordinary local Docker volumes for its website and database. The web root
can be a subdirectory of `/var/www/html`.

The Docker Engine must support an internal bridge with IPv4 gateway mode
`isolated`, introduced in Docker Engine 28.0. Octojoom uses it during staging,
while the original site is still in its previous state. See the
[Docker Engine 28.0 release notes](https://docs.docker.com/engine/release-notes/28/#2800).

Private verification runs Joomla, its database and,
for PHP-FPM, its Nginx service. Custom service commands, extra mounts or a
required dependency outside those services can prevent Octojoom from isolating
the site. Octojoom rejects such configurations before cutover.

The database prompts default to the destination's current database name, user
and password. Leave the password prompt blank to keep the current one. To
change these values in automation, use `db-name`, `db-user` and `db-password`
in a private `--input-json` request. The imported database keeps the package's
table prefix.

The replacement keeps the target hostname, routing and storage arrangement.
The target's Joomla configuration supplies its hosting and mail settings.
The imported application supplies its secret and database table prefix. The
confirmed site and administrator details are written to the site's private
`.env` and applied to Joomla. Octojoom imports the files and database into
separate storage, so tables and files that existed only on the old site are
removed from the active installation.

Fresh deployment and replacement preserve Joomla’s **Site Offline** setting.
An intentionally offline site can pass verification and serve its offline page
to visitors while its containers are running.

During staging, the original website keeps its current service state. Plan for
a service interruption at cutover. Octojoom pauses writers for the backup and
switch, then verifies the replacement on its final storage in a private Docker
network. Joomla must connect to its database and serve its home page. During
this check, neither the site's Traefik route nor a directly published host port
serves the replacement. Visitors may receive a proxy error or a refused
connection while the route is unavailable.

Octojoom records the commit before restoring the site's public Compose
definition, routing and published ports. It starts the services that were
running before replacement and preserves the site's enabled or disabled
registration and its custom health checks. A fully stopped site stays
unavailable to visitors throughout verification and after commit. If
verification fails before commit, Octojoom removes the private verifier and
attempts to restore the original storage and services.

### Read the replacement result

With `--output json`, read `data.outcome` and `data.committed` in the replacement
report before deciding whether to retry. The exit status also covers work that
happens after commit.

| `data.outcome` | `data.committed` | `data.status` | What to do |
| --- | --- | --- | --- |
| `not_committed` | `false` | `failed` | The replacement stopped before commit and the original site was left intact or restored. Review `stage` and `reason` before another attempt. |
| `recovery_incomplete` | `false` | `failed` | Octojoom could not finish recovering the original state. Keep the journal and the storage it names. Resolve recovery before changing the site. |
| `committed` | `true` | `deployed` | The replacement completed. Keep the verified backup and recovery records if you requested a backup. |
| `committed_with_followup` | `true` | `committed_with_followup` | The new installation is committed, and Octojoom returned a nonzero exit status. Use `stage`, `reason` and the recovery path to finish the reported work, such as restoring public service or retiring the old storage. Retrying the import would start another replacement. |

`data.running` can be `null` when Octojoom could not establish the running
state. `data.backup` names the verified archive when one exists. On success
with a backup, `data.recovery` names the private directory recording the
retained original website and database storage. Allow disk space for both
copies. With an explicit backup opt-out, Octojoom retires the original storage
after commit.

If a site operation leaves `.octojoom-change.lock/recovery.path` in the site's
available directory, it points to the private journal and blocks a second
change. The journal can contain copies of the site's original Compose and
environment files, including credentials. Keep it private and preserve the
storage it identifies while investigating. If public startup was interrupted,
the journal's `committed` file records the commit, `candidate.yml` holds the
intended public definition, and `running-services` lists the services that
should be running. The `stage` file names the last step entered and can read
`commit` before the decision is recorded.

To check a retained backup, use the backup command's **verify** action. Use
**restore** to restore it to a new or existing site. See
[Verifying and restoring backups](BACKUPS.md).

## Inspect an existing host

To check an Octojoom-managed destination, add its hostname explicitly.

```bash
octojoom --type joomla --task playground --action inspect \
  --file '/home/user/Downloads/Clothing Store.zip' \
  --container shop.example.test --output json --non-interactive
```

This optional check reads the site's effective Docker Compose settings and the
local Docker daemon's metadata. It identifies the connected MySQL or MariaDB
service, its storage and the website storage, and looks for a runtime candidate
for the **incoming** Joomla and PHP versions. Runtime discovery can contact
the image registry. The command leaves the site's services and storage alone.

The result in `data.targetPreflight` distinguishes a runtime candidate from
an unconfirmed match. `runtimeCheck` explains an empty `runtimeCandidate`.
Inspection success means that Octojoom completed the inspection. A candidate
tag still requires verification against the actual image before deployment.

The result also reports available bytes on filesystems the
host can measure. A Docker Desktop volume can have an inaccessible mountpoint,
so its capacity may be unknown. The website file size gives a lower bound.
An SQL dump gives the size of the import file; the initialized database and a
backup require their own capacity estimate when the deployment options are known.
