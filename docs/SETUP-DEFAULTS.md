# Joomla setup and saved defaults

The Joomla menu still uses **Setup new container** and the original sequence of
image, identity, database, installation and enable questions. After image and
identity selection, one default-No question opens the optional PHP, webserver and database
choices. Declining it keeps the ordinary flow. Expert PHP, persistence and
entrypoint questions remain available. Bulk setup uses the same generator and
asks runtime choices once for the batch.

A manual installation is a completed setup: use Joomla's browser installer when
the container is enabled. Creating a configuration does not enable it by default.
The original image source `joomla`, tag `latest`, database name `vdm_io` and user
`vdm_user` remain the first-use defaults. Database passwords are generated when
omitted in automation and saved privately. The existing interactive administrator
password default has not been described or changed into a generated password.

## Terminal setup

```bash
octojoom --type joomla --task setup --key example --domain example.test \
  --auto-install false --enable false --non-interactive

octojoom --type joomla --task bulk --sub-domain site --domain example.test \
  --number 3 --auto-install false --enable false --non-interactive
```

For a single website, the environment key defaults to the uppercase project key;
the subdomain defaults to its lowercase form. A key and domain are required (the
domain may come from the host's saved configuration). For bulk setup, the provided
subdomain is a prefix; site numbers and independently generated project keys are
added. Single and bulk setup both keep website files in
`${VDM_PROJECT_PATH}/<key>/joomla` and database files in
`${VDM_PROJECT_PATH}/<key>/db` by default. The existing expert yes/no persistence
questions keep this project-folder layout when accepted. Automation uses
`--persistence true` and `--db-persistence true` by default as well.

Explicitly answering No, or supplying the corresponding flag as `false`, keeps
the Docker named-volume option for local testing. A site using a named volume
for either website or database storage is not eligible for complete-project
migration or cold cloning. This choice is never silently changed by a database
change or backup restore. SQL exports and backups remain available within their
documented supported layouts.

`--image-source`, `--image-tag`, `--db-name`, `--db-user`, `--auto-install`,
`--enable`, `--mailcatcher`, `--phpmyadmin`, `--uid`, and `--gid` supply the
corresponding existing questions. Automatic installation needs a valid
administrator email and password; site and administrator names retain the
original defaults. Protected JSON input can supply passwords without putting
them in shell history. Explicit false and empty optional extension/command
values stay explicit. The command transport and result format are documented in
the command guide.

Automatic installation derives its database table prefix from the first 14
characters of the project key plus an underscore. `--db-prefix` supplies an
exact prefix; an existing scoped prefix is otherwise preserved. Prefixes must
start with a letter and contain at most 15 letters, digits or underscores.
Invalid explicit prefixes fail before setup creates files. In bulk setup an
explicit prefix applies to every site's separate database.

Missing identity, invalid options and conflicting shared database credentials
are rejected before first-run directory creation in noninteractive mode. A
shared environment key can be reused with the same database credentials. Use a
new environment key for independent credentials; setup will not overwrite
another website's shared credentials.

## Change an existing site's persistence

Use **Website Information → select a website → Change data persistence** to
change website files and database storage independently. The same yes/no choices
select project-folder persistence or Docker named volumes for local testing.

```bash
# Inspect both current storage choices.
octojoom --type joomla --task persistence --container demo.example.test \
  --action status --non-interactive

# Move both data stores into the site's canonical project folders.
octojoom --type joomla --task persistence --container demo.example.test \
  --persistence true --db-persistence true --non-interactive

# Move only the database into a Docker named volume for local testing.
octojoom --type joomla --task persistence --container demo.example.test \
  --db-persistence false --non-interactive
```

Supplying either storage flag implies `--action set`; no flags defaults to
status. An omitted flag leaves that data store unchanged. The operation stops
writers before copying, preserves numeric ownership and file modes, updates the
selected Compose mounts, verifies the result, and resumes only services that
were previously running. Prior data is retained for recovery. It does not change
the database engine, import SQL or activate a deliberately stopped site.

An existing canonical directory displaced when switching back to project folders
is retained under `${VDM_PROJECT_PATH}/.octojoom-persistence.*/original`, outside
the active project. Original Compose configuration and recovery details remain
in the selected site's `.persistence.*` directory. Shared or ambiguous custom
mounts are rejected before copying.

Returning both stores to project folders restores the storage requirement for
complete-project migration and cold cloning. Their other requirements still
apply, including the supported root layout and raw database compatibility.

## Future defaults and per-site choices

The customization fork includes one **Use these image and runtime choices as
defaults for future websites?** question. Automation uses `--save-defaults true`.
Ordinary per-site changes do not change these defaults.

| Host `.env` setting | Meaning |
| --- | --- |
| `VDM_DEFAULT_JOOMLA_IMAGE_SOURCE` | Selected published image repository |
| `VDM_DEFAULT_JOOMLA_IMAGE_TAG` | Initial tag for the original tag question |
| `VDM_DEFAULT_JOOMLA_WEBSERVER` | `apache` or `nginx` |
| `VDM_DEFAULT_JOOMLA_DOCROOT` | `.` or the selected relative directory |
| `VDM_DEFAULT_JOOMLA_PHPMYADMIN` | `true` or `false` |
| `VDM_DEFAULT_JOOMLA_AUTO_INSTALL` | Default manual/automatic installation choice |
| `VDM_DEFAULT_JOOMLA_DB_ENGINE` | `mariadb`, `mysql`, or `postgres` |
| `VDM_DEFAULT_JOOMLA_DB_IMAGE` | Published database image and tag/digest |

The shared Joomla environment retains database settings and scoped selected
values named `VDM_<ENVKEY>_IMAGE_SOURCE`, `IMAGE_TAG`, `AUTO_INSTALL`, `WEBSERVER`,
`DOCROOT`, `PHPMYADMIN`, `DB_ENGINE`, and `DB_IMAGE`. The Compose file remains authoritative for the
actual deployment. If a new site needs a different project path or scoped runtime
choice from an existing shared assignment, setup saves a complete per-site `.env`
and leaves the shared file unchanged. Unrelated site secrets are excluded. A per-site environment introduced by a later selected-site
action must carry all referenced and supported scoped values; it replaces the
shared file for that site, rather than merging with it.

Setup collects environment assignments without publishing them while questions
are still being answered. It renders the existing `joomlaContainer` generator
and performs quiet Compose validation against staged values. Publication of the
environment and Compose file uses two renames; if the latter fails, the previous
environment is restored or its recovery path is reported. This is not a claim of
an atomic transaction across multiple files. Bulk publishes each validated site
in turn; a failed later site does not remove earlier successful sites.

The portable suite checks cancellation, no-dialog setup, generated and literal
credentials, saved-default reload, site isolation, bulk generation and failed
validation. Live image startup and routing remain separate runtime acceptance.

## Database engines

MariaDB with `mariadb:latest` remains the first-use default. The optional
configuration question offers database engines supported by the selected
Joomla image and asks for a published image reference. Automation supplies
`--db-engine mariadb|mysql|postgres` and `--db-image IMAGE:TAG`. Nondefault
choices inspect the image's server version and the selected Joomla image's
actual PHP extensions, database driver and minimum database requirements.
No image is built or modified. Saved site choices use `VDM_<ENV>_DB_ENGINE`
and `VDM_<ENV>_DB_IMAGE`, alongside the original database credential keys.

The generated database service retains its original `mariadb<key>` identity
for compatibility. MySQL uses its `MYSQL_*` initialization variables; PostgreSQL
uses `POSTGRES_DB`, `POSTGRES_USER` and `POSTGRES_PASSWORD`, port 5432, and the
Joomla `pgsql` driver. PostgreSQL asks no root-password question and does not
create phpMyAdmin. A PostgreSQL data mount follows the selected image's actual
`PGDATA`: older image layouts use `/var/lib/postgresql/data`, while the versioned
layout uses `/var/lib/postgresql`. Raw clone/migration operations retain their
database-image and layout requirements; changing database families is a separate
database-change operation. Supported generated Apache and Nginx/FPM layouts,
including nested document roots, can use these operations when both data stores
use canonical project folders.

Some published Joomla images concatenate PostgreSQL credentials into a libpq
connection string in `/makedb.php`. When this exact initializer is detected,
setup rejects whitespace, single quotes or backslashes in those credentials,
and double quotes in the database name, before writing deployment files.
Values are never rewritten. This is an upstream initialization limitation;
existing-site database tools still pass literal credentials safely.

Published image conventions and Joomla capability checks follow the official
[MySQL image documentation](https://github.com/docker-library/docs/tree/master/mysql),
[PostgreSQL image documentation](https://github.com/docker-library/docs/tree/master/postgres),
[Joomla entrypoint](https://github.com/joomla-docker/docker-joomla/blob/master/docker-entrypoint.sh),
and its [database initializer](https://github.com/joomla-docker/docker-joomla/blob/master/makedb.php).
