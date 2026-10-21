# Webserver and document root

The original **Joomla → Setup new container** questionnaire keeps Apache and
`/var/www/html` as its defaults. Its optional customization questions select
Apache or a published Joomla PHP-FPM image with Nginx, and an optional
project-relative document root. Bulk creation uses the same Compose generator.
A nested root also sets the Joomla service's working directory so the official
entrypoint installs the application in that directory.

Existing sites are managed under **Joomla → Website Information → website**.
The webserver and document-root actions return to that site's refreshed details.
The available Compose file, its effective ENV, and the actual data mount remain
the source of truth; there is no enrollment or additional project registry.

## Commands

```bash
# Read the current flavor and the absolute container document root.
octojoom --type joomla --task webserver --container example.test --action show
octojoom --type joomla --task docroot --container example.test --action show --output json

# Discover and verify a matching published FPM variant, then use Nginx.
octojoom --type joomla --task webserver --container example.test \
  --action set --webserver nginx --non-interactive

# Return to a verified Apache variant of the same installed Joomla/PHP release.
octojoom --type joomla --task webserver --container example.test \
  --action set --webserver apache --non-interactive

# Select an existing installed Joomla directory. This does not move files.
octojoom --type joomla --task docroot --container example.test \
  --action set --docroot site --non-interactive

# An explicit move requires a stopped site and an independent bind mount.
octojoom --type joomla --task docroot --container example.test \
  --action set --docroot site --move-files --non-interactive
```

The shared command help, JSON transport, and automatic Bash completion also
cover these tasks. `--docroot .` selects the root of the website data mount.
Relative directory components cannot escape that mount. Named-volume sites
retain their container paths; Octojoom does not invent a corresponding host
path.

## What a webserver change does

The selected repository is retained. The candidate image is pulled and probed
for its Joomla release, PHP release, architecture, and required extensions.
Replacing a webserver image does not upgrade the installed Joomla files. A
manual `--image-tag` can choose a published candidate when automatic discovery
cannot find one; it must pass the same compatibility checks.

For Nginx, the original Joomla service becomes FPM. Its application environment,
entrypoint, data/PHP mounts, resource settings, and non-routing labels stay on
that service. HTTP ports and Traefik routing labels move to the Nginx companion.
FPM does not publish a host port. Both services share the website data; Nginx
mounts it read-only. Applicable UID/GID settings are retained in an FPM pool
companion. The database service and storage are not recreated.

`nginx.conf` beside Compose is editable. It includes Joomla frontend,
administrator, SEF, and API routing; FastCGI only executes existing PHP scripts.
It rejects sensitive configuration files and dotfiles. Apache root changes use
an actual mounted virtual-host configuration, rather than relying on an
unsupported environment variable.

The operation stages changes, validates Compose, and publishes them using the
common configuration recovery helper. Only affected services that were running
are recreated; prepared/stopped sites stay stopped. Syntax, application files,
PHP/database access, and the selected HTTP route are checked for running sites.
Nginx API verification requires Joomla JSON, so a generic Nginx 404 cannot pass.
Previous configuration is retained at the reported `.octojoom-recovery.*` path.
Failure restores the previous files/runtime where possible and reports any
remaining recovery work.

Site choices are persisted as `VDM_<ENVKEY>_WEBSERVER`,
`VDM_<ENVKEY>_DOCROOT`, and the canonical `VDM_<ENVKEY>_IMAGE` where changed.
Creating a site ENV copies its Compose references and recognized site settings;
it does not omit shared credentials or copy unrelated sites' secrets.

## Existing customization and moves

Targeted editing supports Octojoom's normal block-style service definitions.
Unrelated properties and services are retained. Aliases, flow-style service
objects, non-list label mappings, and custom service commands that cannot be
translated safely receive an operation-specific explanation. The ordinary
Apache/FPM default commands can be translated. Original custom entrypoints are
preserved, and failed startup triggers recovery.

Apache `.htaccess` rules do not run in Nginx. A distributed Joomla `.htaccess`
is recognized; custom rules require an explicit equivalent file supplied with
`--nginx-config FILE`. A custom Apache virtual-host mount is not overwritten by
a document-root change. A custom Nginx configuration without the managed root
marker is edited explicitly instead of guessed at.

An explicit file move requires all site services to be stopped. Its destination
must not exist, and another known website must not share the bind mount.
Dotfiles, ownership, and modes move with the website. Literal Joomla log/tmp
paths beneath the old root are updated; external log/tmp paths are retained.
A failed configuration publication restores the files where possible. Recovery
files are retained and reported if restoration is incomplete. Automatic moves
inside named volumes are not provided: move the files deliberately with the
appropriate container tools, then select the resulting directory.

The original clone and cold-archive migration operations explicitly refuse
nested roots and Nginx layouts that their existing package readers cannot yet
handle. Other site operations remain available. These restrictions avoid
silently cloning or migrating the wrong directory; the later portability
features extend those operations.

## Verification

`tests/unit/webserver-docroot.bats` checks root boundaries, data/routing
preservation, Apache/FPM command handling, companion mount collisions, generated
Nginx/Apache settings, explicit move/recovery, and question cancellation. Linux
runs also validate generated Compose with the real Compose parser when present.

`tests/integration/web-runtime.sh` runs the actual headless setup and Joomla
installer. It checks frontend, administrator login, SEF, API authentication JSON,
assets, uploads, and missing-script/configuration handling across Apache →
Nginx/FPM → a nested root → Apache. It verifies the installed release, PHP,
website files, and database container/data remain intact. It uses a uniquely
named project, network, and temporary directory and removes only those resources.

The real integration test requires Linux, Docker Compose v2, registry/network
access, jq/curl, and root or passwordless sudo. It covers bind storage and local
HTTP; it is not proof of custom image entrypoint compatibility, named-volume
moves, public proxy/TLS configuration, or browser trust.

Stopped-site changes also run the candidate webserver's native syntax check in
an isolated one-shot container. It uses the candidate image, environment and
actual mounted files with all site storage read-only, substitutes staged
companions, and does not start the Compose project. The known FPM service name
is resolved only for parsing; connectivity and application checks run when the
site is active. Missing includes fail the check. Compose configs/secrets mounts,
anonymous volumes and volume subpaths require explicit configuration instead
of this automatic stopped-site check.
