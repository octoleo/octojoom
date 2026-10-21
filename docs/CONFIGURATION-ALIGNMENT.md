# Existing configuration alignment

Use **Joomla Containers → Update existing configurations** for all discovered
websites, or the alignment action in **Website Information** for the selected
website. The normal main menu offers the same action with a pending-site count.
Detection is local and read-only; it never starts Docker or changes a site.

```bash
octojoom --type joomla --task align --all --action inspect --non-interactive
octojoom --type joomla --task align --all --non-interactive
octojoom --type joomla --task align --container demo.example.test --non-interactive
```

The current transformation saves the **existing** web image as
`VDM_<ENVKEY>_IMAGE`, replaces only that service's image scalar with the setting,
and creates a complete private site `.env` when needed. It copies every Compose
reference and recognized settings for that site's environment key. It excludes
unrelated sites and unreferenced host credentials. The shared ENV remains intact.
Existing image source/tag, PHP settings, webserver/root choices, original Joomla
settings, and recognized SMTP, hook and backup preferences are retained.

No image is upgraded, no optional service is enabled, and no Traefik change is
currently needed for features 1–6. Before publication, the effective Compose
configuration must match the previous configuration exactly. This transformation
therefore never restarts services or changes enabled state. Applying it again is
a no-op. Later features can add their own specific transformations when required.

Reports distinguish `pending`, `unchanged`, `updated`, and `action-needed`.
Batch application continues after an unsupported site and exits unsuccessfully
if any site could not be handled. A partial result is not reported as complete.

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
