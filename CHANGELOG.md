# Changelog

## 4.0.0

### Joomla site management

- Add a per-site dashboard and batch menu that invoke the same handlers as terminal commands.
- Add a versioned noninteractive request/result contract with typed flags, JSON files/stdin, literal tool arguments, action-specific validation, discoverable forms and stable application error codes.
- Report actual runtime versions, service state, paths and URLs; add logs, diagnostics, opening site services and project directories.
- Create Apache or Nginx/FPM projects with configurable document roots, PHP settings and local/server profiles. Switch PHP without upgrading installed Joomla; retain prior configuration if recreation fails.
- Add verified standalone Joomla source downloads and managed file-permission repair.

### Data and recovery

- Add logical database export/import, selected-table exports, SQL commands, batch results and database restore points.
- Add checksummed full/site/database archives, restoration, retention cleanup, independent clones, external Joomla imports and single-archive SSH migration.
- Support MariaDB, MySQL and PostgreSQL project configurations, source-preserving engine changes and explicit fresh-target workflows. Unsupported cross-family SQL conversion fails before mutation.
- Keep recovery data for replacement operations and propagate failed recovery clearly. Imported hooks remain inactive unless explicitly trusted.

### Local development

- Add mkcert local HTTPS using a dedicated loopback Traefik proxy, owned hostname entries and host-private certificate authorities.
- Add temporary sharing of one Joomla application through a Cloudflare tunnel, with explicit status and stop operations.
- Add Mailpit capture and Joomla mail tests while preserving original mail settings.
- Add project-scoped Node and Redis services, Joomla CLI/Composer/npm commands, explicit lifecycle hooks and offline preparation.
- Add noninteractive update checks and staged OctoJoom updates with recovery copies.

### Compatibility

- Bash 4+, jq and Docker Compose v2 are required for the new interface. Commands do not install host dependencies or prompt for elevation.
- Keep the standalone Bash distribution, existing menu paths and legacy command compatibility. Version 4 metadata and generated Compose files use private project-scoped environment files; custom additions belong in a Compose override.
- Xdebug and automatic Joomla core upgrades by replacing images are deferred to the official-container track.
