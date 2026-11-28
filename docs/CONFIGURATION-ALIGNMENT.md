# Existing configuration alignment

Use **Joomla Containers → Update existing configurations** for all discovered
websites. That batch menu displays its plan before you apply it. The alignment
action in **Website Information** applies updates to the selected website.
Use the CLI's `--action inspect` to preview a single website's changes.

```bash
octojoom --type joomla --task align --all --action inspect --non-interactive
octojoom --type joomla --task align --all --non-interactive
octojoom --type joomla --task align --container demo.example.test --non-interactive
```

Image alignment saves the **existing** web image as
`VDM_<ENVKEY>_IMAGE`, replaces only that service's image scalar with the setting,
and creates a complete private site `.env` when needed. It copies every Compose
reference and recognized settings for that site's environment key. It excludes
unrelated sites and unreferenced host credentials. The shared ENV remains intact.
Existing image source/tag, PHP settings, webserver/root choices, original Joomla
settings, and recognized SMTP, hook and backup preferences are retained.

Octojoom checks that the image and environment edits resolve to the same Compose
configuration before applying any health check change. Image-only alignment
keeps existing containers running.

## Repair the Apache health check for one website

After installing the updated Octojoom script, select **Website Information →
Update this website configuration** for the affected hostname. From the CLI you
can inspect and apply that same operation to a single website.

```bash
read -r -p 'Joomla website hostname: ' site
octojoom --type joomla --task align --container "$site" --action inspect --non-interactive
octojoom --type joomla --task align --container "$site" --action apply --non-interactive
```

Octojoom replaces its original Apache homepage probe when both the command and
the configured interval, timeout and failure threshold match the generated
defaults. The new probe works while Joomla displays its native offline login
page. A running Apache container is recreated and checked for readiness. An
existing stopped Apache container is recreated without starting it. If the
container has never been created, the next start uses the updated definition.
The database and other services keep their current state. Custom probes and
custom timings are preserved. Running the same command again reports
`unchanged` once the website is aligned.

If the site currently runs Nginx/PHP-FPM, switching back to Apache also checks
the saved Apache probe. Octojoom upgrades the old generated default during
restoration and restores a custom probe as saved.

Reports distinguish `pending`, `unchanged`, `updated`, and `action-needed`.
Batch application continues after an unsupported site and exits unsuccessfully
if any site could not be handled. A partial result is not reported as complete.

If a required environment setting cannot be read, `action-needed` identifies
the variable and the effective `.env` file. A malformed assignment or quoted
value also includes its line number. Values are never included in the report.
Correct the reported line, or restore a missing setting using its existing site
value, then run **Update existing configurations** again. A per-site `.env`
takes precedence over the shared `joomla/.env`, so edit the file named in the
report. This check leaves the site's files and services unchanged.

The targeted image edit supports the original two-space service/four-space
property block layout, including custom unrelated services, mounts, labels and
comments. An ambiguous/duplicate property, advanced interpolation, linked config
path, or unrecognized identity is left unchanged with an explanation. Those
sites remain available for information, normal lifecycle actions and expert
editing. Alignment is not an enrollment requirement.

## Shared configuration writes

Runtime actions stage changed Compose, complete scoped ENV and companion files.
They validate using the original project directory, so temporary filenames do
not change project identity or relative mounts. Publication uses adjacent file
renames and tracks each successful write. These separate writes are recoverable,
not a multi-file atomic transaction.

A private `.octojoom-recovery.*` directory inside the selected site retains the
previous files and a `paths` mapping after each update. A failed publication or
runtime check restores those files and attempts to restore previously running
affected services. The error explicitly reports incomplete recovery. Only
previously running affected services are recreated; database volumes are never
removed. Callers declare any added/retired HTTP service and their post-start
validation. Stopped websites remain stopped.

The scoped migration exporter and validator use the same recognized-field list,
so an original SMTP setting or a saved per-site runtime choice does not disappear
simply because Compose does not currently interpolate it. This does not add the
future hook, mail, backup or developer-tool functionality; it preserves those
recognized preferences when supplied.

Portable tests cover scoped credentials and literal values, targeted edits,
custom-field preservation, idempotence, rejected configuration, semantic drift,
batch failures, stopped state and failed-runtime recovery. Real image/routing
acceptance remains a separate check; mocked validation is not evidence of live
Joomla, database or HTTP behavior.
