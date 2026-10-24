# Local trusted HTTPS

Use **Joomla Containers → Enable local HTTPS for websites** to select one or more
sites that do not already use local HTTPS. The checklist includes their current
connection mode. Sites already using local HTTPS are omitted.

For one site, use **Website Information → select website → Connection / SSL**.
This shows the current URL and offers local HTTPS, HTTP, public Let's Encrypt,
Cloudflare, and certificate renewal. Choosing local HTTPS immediately prepares
the proxy and site; the completion dialog shows the working URL. Other connection
changes show their proposed URL for confirmation.
After a change, return to that website's details. Menu width remains 112 columns;
height and visible rows adjust automatically.

## First use

Local HTTPS uses Traefik and
[mkcert](https://github.com/FiloSottile/mkcert#installation). Interactive setup
installs missing mkcert/OpenSSL tools through apt-get or dnf on Linux, Homebrew
on macOS, or Chocolatey on Windows. Linux/macOS installation includes NSS tools
for browser trust. Run Octojoom in Git Bash on Windows. Package installation can
request operating-system authorization. If no supported package manager is
available, the error gives installation commands and tells you to retry.

The same action prepares Traefik automatically: it adds a missing HTTPS entrypoint,
published port and watched certificate-directory mount, creates the host directory,
and starts the proxy if needed. Existing ports, image, public certificate resolvers,
credentials, networks and unrelated settings are preserved. A running proxy is
recreated only when its configuration needs to change, which can briefly interrupt
traffic. Subsequent certificates and renewals use the watcher without restarting
the proxy. A new proxy is created when no configuration exists.

To prepare an existing proxy independently, use **Traefik → Prepare local HTTPS**,
or run:

```bash
octojoom --type traefik --task update --non-interactive
```

This separate action leaves a stopped proxy stopped. Enabling local HTTPS for a
website starts it automatically. Existing HTTP settings are left as configured;
an HTTPS-only proxy does not acquire an HTTP listener.

Older installations without `Docker/traefik/.env` reuse the global Octojoom ENV,
just like the existing Traefik enable action. Literal configurations also work
without either file. The previous `… is a directory` error came from passing an
empty ENV filename to Docker Compose; it did not mean the home directory was wrong.

On first interactive use, Octojoom offers to run `mkcert -install`. This installs
this computer's local CA in the supported trust stores and may require operating
system authorization. Subsequent websites reuse that CA. Restart an already open
browser if it has not picked up the trust change. Browser profiles and managed
browser policies can require separate trust configuration; an OS trust check is
not proof that every browser profile trusts the CA.

For automation, install mkcert/OpenSSL and host trust first:

```bash
mkcert -install

octojoom --type joomla --task ssl --container demo.example.test \
  --action set --mode local --update-hosts true --non-interactive

octojoom --type joomla --task ssl --container demo.example.test \
  --action status --output json --non-interactive

octojoom --type joomla --task ssl --container demo.example.test \
  --action renew --non-interactive
```

Headless operations never install packages or invoke an interactive trust installer. Missing trust
produces a prerequisite error with the command to run. Hosts-file changes use the
existing `--update-hosts` policy and noninteractive sudo behavior. If a hostname
already resolves through your local DNS, hosts-file changes are unnecessary.
Use the displayed URL, which includes a nondefault Traefik published port.

The equivalent JSON transport is:

```json
{
  "type": "joomla",
  "task": "ssl",
  "container": "demo.example.test",
  "action": "set",
  "options": {
    "mode": "local",
    "update-hosts": true
  }
}
```

Pass this file through `--input-json FILE --non-interactive`. Task, action, mode
and site completion use the existing CLI discovery. Status reports effective
mode, URL, certificate expiry, host trust and endpoint verification. Browser
trust remains `unchecked`; no private key appears in output. Endpoint verification
uses normal DNS and client trust, without disabling certificate verification.
An unreachable endpoint does not mean certificate generation failed: check that
the site and Traefik are running and the hostname resolves locally.

## New sites and defaults

The original setup questionnaire remains the only creation path. At the existing
optional customization fork, choose **Connection / SSL → Local trusted HTTPS**.
Saving setup defaults also saves this choice for future sites. Automation can
supply `--tls-mode local` with its usual `--task setup` inputs. `default` retains
the existing host connection behavior. Other choices are `http`, `acme` and
`cloudflare`. An explicit site choice does not change the global `VDM_SECURE`
preference.

The new site is enabled only after its connection settings succeed. If connection
setup fails after its initial configuration is saved, the diagnostic identifies
the stopped site; retry its Connection / SSL action rather than creating it again.

## What changes

- Only the selected site's generated Joomla, database-viewer and mail-viewer
  routers change. Custom service configuration, credentials, data, mounts, images
  and unrelated labels remain intact. Nginx receives the same route policy as
  Apache. Unknown YAML label structures are refused with an actionable message.
- Local routers use `websecure`, enable TLS, and have no ACME resolver. Existing
  public sites retain their routers and resolver configuration. Public mode
  changes require the corresponding resolver to exist on Traefik already.
- The effective environment is scoped to the site using the existing ENV helper.
  Compose-required values and recognized settings for that site are retained;
  other sites' secrets are not copied. `VDM_<ENV>_TLS_MODE` records the selected
  mode, while discovery reads actual labels rather than trusting stale metadata.
- Certificates and leaf keys live in the existing `/conf` bind directory's
  `octojoom` child directory. Dynamic YAML files live directly in `/conf`, where
  Traefik watches changes. Publication requests OS authorization when this
  directory is root-owned, without changing its ownership. New
  Traefik setups mount `/conf` read-only; existing mounts are reused as configured.
  Only this child directory is made writable for the invoking user when needed.
  Rootless/custom-user Traefik configurations require explicit file access setup
  and are rejected by this automatic path.
- `mkcert -CAROOT` remains host-owned and outside all generated site mounts. The
  CA private key is never copied into a site, proxy directory, backup or migration
  archive. Keep it private: it can issue certificates trusted by this computer.
- Candidate Compose/ENV files are validated before publication. Only affected
  services that are already running are recreated; stopped sites remain stopped.
  Proxy preparation is a separate recoverable step: the previous Compose file is
  retained, and a failed proxy restart restores its configuration and running state.
  Successfully prepared proxy capabilities remain available if a later site change
  fails, so the Traefik action and other sites can reuse them.
  When Traefik is running, the operation verifies each running selected router's
  hostname and certificate through the published port. This uses the trusted
  local CA explicitly, so it also works with clients that have a separate CA
  bundle; it does not disable TLS validation. Failed verification triggers recovery.
  Renewal is picked up by the file provider without recreating application or
  proxy containers. Repeating an unchanged selection is a no-op for containers.
- A failed publication restores the prior routing, environment, local certificate
  configuration and any changed Joomla URL. Existing transaction recovery files
  are retained when necessary and their location is reported.

## HTTP, public HTTPS and compatibility

To return to HTTP:

```bash
octojoom --type joomla --task ssl --container demo.example.test \
  --action set --mode http --non-interactive
```

Use `--mode acme` or `--mode cloudflare` for the existing public certificate
policies. Switching away from local mode removes its dynamic certificate entry so
it cannot shadow the public certificate. Leaf files are host-only and can be
removed when no longer referenced by the site's dynamic YAML.

HTTP mode removes Octojoom's TLS/HSTS/Cloudflare middleware selection and adds a
host-router priority above the original catch-all redirect. A global Traefik
entrypoint redirect is incompatible and must be removed explicitly first.
Unrelated custom middleware remains yours to manage; custom redirects or HSTS
can still affect traffic. Browser HSTS cached from earlier public HTTPS also
persists independently of configuration changes.

A nonempty Joomla `live_site` keeps its path while adopting the selected scheme
and published port. Existing `cookie_domain` remains unchanged because the
hostname does not change. `force_ssl` is never enabled automatically; switching
to HTTP clears it. Custom PHP expressions or a `live_site` naming another host
require explicit alignment before the operation proceeds.

Automatic routing changes currently support the ordinary list-style labels and
single-host `Host()` rules generated by Octojoom, a local Docker context, the
standard `web`/`websecure` entrypoints and the watched `/conf` bind directory.
Missing standard HTTPS capabilities are added automatically. Conflicting custom
entrypoints or an existing single-file provider need an explicit decision to retain
their routing; the dialog identifies the setting and configuration file to change.
Custom entrypoints, remote daemons, map/anchor labels and rootless Traefik need
explicit configuration rather than a guessed rewrite. Local trust applies only
to this computer; it is not a public certificate or a sharing mechanism.

## Verification

The unit suite covers label preservation, environment isolation, mode round trips,
unknown-label rejection, URL changes, CLI discovery and failed transactions.
Native trust jobs exercise mkcert on Linux, macOS and Windows. The Docker
acceptance job starts with a legacy proxy lacking its own ENV and local HTTPS
configuration, installs Joomla and its companion viewers, and verifies trusted HTTPS with a
nondefault port, renewal, repeat application, Apache/Nginx, HTTP return and
stopped-site behavior. It also verifies that database and proxy containers are
not unnecessarily recreated. Browser trust must still be checked in the actual
browser profile used for development.

Traefik reference: [user-provided TLS certificates](https://doc.traefik.io/traefik/reference/routing-configuration/http/tls/tls-certificates/).
