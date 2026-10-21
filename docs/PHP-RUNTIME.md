# PHP runtime and settings

Use **Joomla Containers → Website Information → website → Change PHP version**
or **Change PHP settings**. The action returns to the selected website's refreshed
information. New-site customization uses the existing setup questionnaire.

```bash
octojoom --type joomla --task php --container example.test --action list
octojoom --type joomla --task php --container example.test --action switch \
  --image-tag EXISTING_PUBLISHED_TAG --non-interactive
octojoom --type joomla --task php --container example.test --action settings \
  --memory-limit 512M --max-execution-time 180 --non-interactive
```

`list` discovers published candidates for the installed Joomla release and the
current webserver. Select an actual tag returned by that command. Discovery uses
Docker Hub; custom registries support an explicitly supplied tag using Docker's
normal authentication. `--image` accepts a full reference from the same repository.
Completion reads the disposable local tag cache without starting Docker or making
network requests. Registry and runtime actions require Docker and `jq`.

A switch reads Joomla's installed manifest, pulls the candidate before changing
configuration, and checks its bundled Joomla release, Apache/FPM flavor, PHP
extensions and architecture. Changing PHP does not change the installed Joomla
release or recreate the database. A webserver flavor change also preserves the
PHP version. Image inspection overrides the installation entrypoint, has no
network and never mounts the live website writable.

The selected site's Compose file remains authoritative. Runtime edits change
only its web service image or PHP override mount. They preserve its custom
entrypoint, labels, networks, database storage and unrelated services. Editing is
supported for the normal block-style service definition. An ambiguous or inline
YAML layout receives an operation-specific explanation; the site and its other
actions remain accessible through the existing expert editors.

Settings accept these flags:

| Option | Original initial value |
| --- | --- |
| `--max-execution-time` | `124` |
| `--max-input-time` | `1500` |
| `--max-input-vars` | `3000` |
| `--error-reporting` | `E_ALL & ~E_DEPRECATED & ~E_STRICT` |
| `--upload-max-filesize` | `256M` |
| `--post-max-size` | `256M` |
| `--memory-limit` | `256M` |

An existing site's questions use its own file/runtime values. Only supplied flags
are changed in noninteractive mode, including explicit zero. Existing custom INI
directives are preserved. A bulk-shared INI is copied into the selected Compose
directory and only that site's mount changes. The new file mounts into the
selected image's measured PHP scan directory as `zz-octojoom.ini`; unsupported
multiple/absent scan directories are reported before publication. The file is
readable by the container user and contains configuration, not credentials.

Choices persist as `VDM_<ENVKEY>_IMAGE` and
`VDM_<ENVKEY>_PHP_<UPPERCASE_SETTING>` in the site's effective ENV. When a site
previously used the shared ENV, its new ENV retains every referenced assignment
and recognized setting in that site's scope. Unrelated sites' secrets are not
copied. Changing an existing site never changes the host's new-site defaults.

Configuration changes are staged and validated before publication. Recoverable
originals are retained by the shared configuration publisher. Only affected
services that were running are recreated. A prepared/stopped site stays stopped,
and enabled symlinks are unchanged. A running site's successful apply checks the
selected PHP version, requested startup configuration, Joomla's database
connection and its actual HTTP route. PHP startup configuration uses
`get_cfg_var`, because the CLI SAPI overrides settings such as execution time.
Failure restores the prior files/runtime through the same publication helper and
reports any recovery problem.

The portable tests cover source retention, invalid candidates, required
extensions, architecture mismatches, targeted edits, custom directives and
shared-INI isolation. `tests/integration/php-runtime.sh` exercises two actually
published PHP variants with Apache/MariaDB, installed-manifest/JConfig/SQL
fixtures, persistent records, configuration hashes and effective PHP settings.
It does not establish compatibility for every Joomla extension or custom image.
The separate web runtime acceptance covers Joomla routing. No Docker daemon is
available in the development workspace; real integration results come from CI
or a supported deployment host.

References: [official Joomla images](https://github.com/joomla-docker/docker-joomla),
[PHP image configuration](https://hub.docker.com/_/php), and
[Compose up](https://docs.docker.com/reference/cli/docker/compose/up/).
