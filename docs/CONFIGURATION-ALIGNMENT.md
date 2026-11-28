# Existing configuration alignment

## Repair the Apache health check for one website

In **Joomla Containers → Website Information**, select the affected hostname
and choose **Update this website configuration**. This repairs the old Octojoom
Apache health check for that website. The same operation is available from
the command line.

```bash
read -r -p 'Joomla website hostname: ' site
octojoom --type joomla --task align --container "$site" --action inspect --non-interactive
octojoom --type joomla --task align --container "$site" --action apply --non-interactive
```

`inspect` previews the change. `apply` is the default action. It replaces the
generated `curl -f http://localhost/` probe when its interval, timeout and
retry count still match Octojoom's original defaults. The replacement sends
`OPTIONS *` to Apache every 30 seconds. Joomla can then serve its native
offline login page with HTTP 503 while the administrator remains reachable.

The updater edits only the matching Compose health check. It uses the site's
existing image and active environment, including a shared `joomla/.env`. An
already-correct or custom probe, including one with custom timings, needs no
update. Switching from Nginx/PHP-FPM back to Apache also upgrades a saved
legacy default when restoring the Apache configuration.

| Selected Apache service | Effect of applying a matching update |
| --- | --- |
| Running | Compose recreates the web container. Docker resumes its scheduled probe. |
| Stopped | Compose recreates the stopped container with the corrected probe and leaves it stopped. |
| Never created | The next start uses the corrected Compose definition. |

The database and other services keep their current state. Use `--container`
for one site. An explicit `--all` requests a batch operation. Each site's
result is `pending`, `updated`, `unchanged`, or `action-needed`.

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
