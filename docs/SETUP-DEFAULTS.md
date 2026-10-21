# Joomla setup and saved defaults

The Joomla menu still uses **Setup new container** and the original sequence of
image, identity, database, installation and enable questions. After image and
identity selection, one default-No question opens the optional PHP and webserver
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
added. The existing bulk default uses Docker named volumes; single-site setup
uses bind directories. Explicit `--persistence true|false` and
`--db-persistence true|false` select bind directories or named volumes.

`--image-source`, `--image-tag`, `--db-name`, `--db-user`, `--auto-install`,
`--enable`, `--mailcatcher`, `--phpmyadmin`, `--uid`, and `--gid` supply the
corresponding existing questions. Automatic installation needs a valid
administrator email and password; site and administrator names retain the
original defaults. Protected JSON input can supply passwords without putting
them in shell history. Explicit false and empty optional extension/command
values stay explicit. The command transport and result format are documented in
the command guide.

Missing identity, invalid options and conflicting shared database credentials
are rejected before first-run directory creation in noninteractive mode. A
shared environment key can be reused with the same database credentials. Use a
new environment key for independent credentials; setup will not overwrite
another website's shared credentials.

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

The shared Joomla environment retains database settings and scoped selected
values named `VDM_<ENVKEY>_IMAGE_SOURCE`, `IMAGE_TAG`, `AUTO_INSTALL`, `WEBSERVER`,
`DOCROOT`, and `PHPMYADMIN`. The Compose file remains authoritative for the
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
