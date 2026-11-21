# Inspect a JoomEngine Playground package

Open **Joomla → Deploy Joomengine Playground packages** and enter the full path
to a complete Playground ZIP on the computer running Octojoom. The entry is
available on an empty installation. This phase provides read-only inspection.
Creating a site and replacing an existing site are planned for later phases.

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
