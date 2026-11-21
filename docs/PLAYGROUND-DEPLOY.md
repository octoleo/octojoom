# Deploy a JoomEngine Playground package

Open **Joomla → Deploy Joomengine Playground packages** and enter the full path
to a complete Playground ZIP on the computer running Octojoom. The entry is
available on an empty installation. Review the package summary, then choose
**Launch a fresh Joomla site** to open setup, or **Back** to finish inspection.
A fresh deployment requires a new project key and hostname.

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

Octojoom checks the selected image against the installed Joomla version,
webserver, PHP requirements and database driver. By default it uses the
package's preferred PHP series and imports the supported PHP settings. The
site's SQL is imported into a fresh MariaDB or MySQL database with the
original table prefix. MariaDB accepts the exported SQL directly. On MySQL,
Octojoom adapts the exporter's hexadecimal representation of numeric values
to preserve IDs, flags and quantities. Joomla keeps its exported secret. Its database
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
