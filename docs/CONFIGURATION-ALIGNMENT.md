# Existing configuration alignment

## Repair the Apache health check for one website

In **Joomla Containers → Website Information**, select the affected hostname
and choose **Update this website configuration**. This retires Octojoom's
generated Apache probe for that website. The same update is available from the
command line.

```bash
read -r -p 'Joomla website hostname: ' site
octojoom --type joomla --task align --container "$site" --action inspect --non-interactive
octojoom --type joomla --task align --container "$site" --action apply --non-interactive
```

`inspect` previews the update. `apply` is the default action. Octojoom
recognizes both of its former curl commands, the homepage request and the
Apache `OPTIONS *` request. Probe timing and YAML field order can vary.
The update removes the generated health check from Compose. An operator's
own check, including a different check inherited from a custom image, is
preserved. If the image itself supplies an old Octojoom check, the update
explicitly disables it for this web service.

The update uses the selected site's Compose project, web service and active
environment, including a shared `joomla/.env`. The environment file stays in
place. If the saved configuration already omits the probe but the existing
web container still runs an old generated probe, the update applies the
saved configuration to that container.

| Selected Apache service | Effect of applying a required update |
| --- | --- |
| Running | Compose recreates just the web container to retire the old probe. |
| Stopped | Compose recreates the web container in its stopped state. |
| Never created | Octojoom updates the saved definition for the next start. |

The site keeps its enabled or disabled setting. Its database and other
services keep running or stay stopped as before. Reapplying the update to an
already aligned site leaves the web container in place. Use `--container`
for one site or `--all` to explicitly request a batch.

## Save the current image as a site setting

Operators who want to manage an existing literal web image through
`VDM_<ENVKEY>_IMAGE` can request that change explicitly.

```bash
read -r -p 'Joomla website hostname: ' site
octojoom --type joomla --task align --container "$site" --action inspect-image --non-interactive
octojoom --type joomla --task align --container "$site" --action save-image --non-interactive
```

`save-image` stores the current image reference in the private site `.env` and
points the Compose image setting to it. An existing private file keeps its
other records and comments. For a site using the shared environment, Octojoom
copies the settings required by that site into the private file. It compares
the rendered Compose configurations before publishing. If the change would
alter the project name or another effective setting, it reports
`action-needed`. Saving the image setting keeps the running services in place.

## Recovery

Octojoom validates staged changes using the original Compose project directory.
If publication or recreation fails, it restores the previous files and
attempts to return the selected service to its previous state. If recovery
is incomplete, the error identifies the private recovery directory containing
the original files.
