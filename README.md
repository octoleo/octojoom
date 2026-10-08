<h2 align="center">
  <img align="middle" src="https://raw.githubusercontent.com/octoleo/octojoom/master/graphics/OctoJoomAlt.svg">
  <br>
  <img align="middle" src="https://raw.githubusercontent.com/odb/official-bash-logo/master/assets/Logos/Icons/PNG/64x64.png">
  Octojoom — Easy Joomla! Docker Deployment
</h2>

<p align="center">
  <a href="https://github.com/octoleo/octojoom/actions/workflows/tests.yml">
    <img src="https://github.com/octoleo/octojoom/actions/workflows/tests.yml/badge.svg" alt="Octojoom tests">
  </a>
  <img src="https://img.shields.io/badge/Ubuntu-tested-brightgreen?logo=ubuntu&logoColor=white" alt="Ubuntu Tested">
  <img src="https://img.shields.io/badge/macOS-tested-blue?logo=apple&logoColor=white" alt="macOS Tested">
  <img src="https://img.shields.io/badge/Windows-supported-0078D6?logo=windows&logoColor=white" alt="Windows Supported">
  <img src="https://img.shields.io/badge/License-GPLv2-blue.svg" alt="License GPLv2">
  <img src="https://img.shields.io/badge/Version-3.9.1-orange" alt="Version 3.9.1">
</p>

<p align="center">
  <strong>Deploy Joomla and OpenSSH Docker containers effortlessly, across Linux, macOS, and Windows.</strong><br>
  <em>Created by <a href="https://github.com/llewellynvdm">@llewellynvdm</a> — powered by the <a href="https://github.com/octoleo">Octoleo</a> team.</em>
</p>

---

## 📚 Table of Contents

1. [Overview](#-overview)
2. [Supported Operating Systems](#-supported-operating-systems)
3. [Prerequisites](#-prerequisites)
4. [Installation](#-installation)
   - [Ubuntu / Debian / Pop!_OS / Linux Mint](#ubuntu--debian--pop_os--linux-mint)
   - [macOS (Intel & Apple Silicon)](#macos-intel--apple-silicon)
   - [Windows (MSYS2 / Cygwin / Git Bash)](#windows-msys2--cygwin--git-bash)
   - [Other Linux Distributions (Fedora / Arch / Manjaro / openSUSE)](#other-linux-distributions-fedora--arch--manjaro--opensuse)
5. [Usage](#-usage)
   - [Complete Joomla project migration](#complete-joomla-project-migration)
   - [Help Menu (from the script)](#help-menu-from-the-script)
6. [Updating Octojoom](#-updating-octojoom)
7. [Uninstall](#-uninstall)
8. [Contributing](#-contributing)
9. [License](#-license)
10. [Quick Reference](#-quick-reference)

---

## 🧭 Overview

**Octojoom** is a powerful Bash-based utility that simplifies the process of deploying and managing **Dockerized Joomla** environments alongside **OpenSSH** for secure, multi-user development setups.

It provides both:
- **Interactive menu-driven control** via *whiptail* dialogs
- **Direct CLI commands** for automation and scripting

### ✨ Key Features
- 🚀 Quick Joomla + OpenSSH Docker deployment
- ⚙️ Automatic `.env` management for persistent settings
- 🔁 Self-updating and easy uninstall
- 🧰 Works across Linux, macOS, and Windows environments
- 🧩 Uses environment variables to remember your setup
- 📦 Migrate complete Joomla projects in one compressed archive, then configure them on the destination

> 💡 Octojoom detects your OS automatically, installs or guides required tools, and walks you through Docker setup.

Linted by [ShellCheck](https://github.com/koalaman/shellcheck) ✅

---

## 🖥️ Supported Operating Systems

| Platform | Tested Versions | Installer | Notes |
|-----------|----------------|------------|--------|
| **Ubuntu / Debian / Pop!_OS / Linux Mint** | Ubuntu 20.04 → 24.04, Debian 11 → 12 | `apt-get` | ✅ Officially tested and supported |
| **macOS (Intel & Apple Silicon)** | Monterey → Sonoma | `brew` | ✅ Fully supported |
| **Windows (MSYS2 / Cygwin / Git Bash)** | Windows 10 & 11 | `choco` | ⚠️ Works interactively; Docker Desktop required |
| **Other Linux (Fedora / Arch / Manjaro / openSUSE)** | Latest stable | Manual | ⚙️ Works if dependencies are installed manually |

---

## 🚀 Prerequisites

Ensure the following are installed before running Octojoom:

| Dependency | Minimum Version | Purpose |
|-------------|-----------------|----------|
| **Bash** | ≥ 4.0 | Required shell |
| **curl** | any | Downloads resources |
| **awk** | any | Text parsing |
| **whiptail / newt** | any | Interactive menus |
| **Docker Engine & Docker Compose** | latest | Container runtime |

---

## 📦 Installation

Follow the setup guide for your system below.
(Click to expand any section.)

---

<details open>
<summary>🐧 <strong>Ubuntu / Debian / Pop!_OS / Linux Mint</strong></summary>

```bash
# Install dependencies
sudo apt-get update
sudo apt-get install -y bash curl whiptail

# Install Octojoom
sudo curl -L "https://raw.githubusercontent.com/octoleo/octojoom/refs/heads/master/src/octojoom" -o /usr/local/bin/octojoom
sudo chmod +x /usr/local/bin/octojoom

# Verify installation
octojoom -h
````

> ✅ Octojoom is now ready to use! Run it directly to launch the interactive menu.

</details>

---

<details>
<summary>🍎 <strong>macOS (Intel & Apple Silicon)</strong></summary>

```bash
# Install Homebrew if needed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install dependencies
brew install newt
brew install --cask docker

# Launch Docker Desktop once manually
open /Applications/Docker.app

# Install Octojoom
sudo curl -L "https://raw.githubusercontent.com/octoleo/octojoom/refs/heads/master/src/octojoom" -o /usr/local/bin/octojoom
sudo chmod +x /usr/local/bin/octojoom

# Verify
octojoom -h
```

> 🧠 Tip: macOS may prompt you to approve permissions for Docker and terminal utilities on first run.

</details>

---

<details>
<summary>🪟 <strong>Windows (MSYS2 / Cygwin / Git Bash)</strong></summary>

1. Install **[Docker Desktop](https://www.docker.com/products/docker-desktop)**.
2. Install **Chocolatey**:

   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
   ```
3. Install dependencies:

   ```bash
   choco install curl awk newt
   ```
4. Install Octojoom:

   ```bash
   curl -L "https://raw.githubusercontent.com/octoleo/octojoom/refs/heads/master/src/octojoom" -o /usr/local/bin/octojoom
   chmod +x /usr/local/bin/octojoom
   ```
5. Launch Octojoom:

   ```bash
   octojoom -h
   ```

> ⚠️ **Important:** Ensure Docker Desktop is running before launching Octojoom.

</details>

---

<details>
<summary>🐧 <strong>Other Linux Distributions (Fedora / Arch / Manjaro / openSUSE)</strong></summary>

Install dependencies manually for your distribution:

```bash
# Fedora / CentOS / RHEL
sudo dnf install -y bash curl newt

# Arch / Manjaro
sudo pacman -S --needed bash curl newt

# openSUSE
sudo zypper install -y bash curl newt

# Install Octojoom
sudo curl -L "https://raw.githubusercontent.com/octoleo/octojoom/refs/heads/master/src/octojoom" -o /usr/local/bin/octojoom
sudo chmod +x /usr/local/bin/octojoom
```

> 🧩 Works across most Linux distributions — if Bash, Curl, and Docker are installed, Octojoom will run seamlessly.

</details>

---

## ⚙️ Usage

Run without arguments to use the interactive menu, or pass CLI flags for automation.

```bash
octojoom -h
```

### Complete Joomla project migration

From the migration menu, choose **Migrate Complete Joomla Project**, or run:

```bash
octojoom --type joomla --task migrate
```

Choose **Push to Remote System** to send a local project, or **Pull from Remote
System** to select a project on the remote server. Pull can import a project
even when no Joomla projects exist locally. Both directions use the same
source packaging and destination configuration process.

#### Before migrating

- Update Octojoom on both hosts and initialize their repository/project paths.
  The remote account must find `octojoom` on its `PATH` or at `$HOME/octojoom`.
- Configure working SSH access to the other host. Saved hosts from
  `~/.ssh/config` appear in the selector; manual host entry is also available.
  Destination questions are displayed through an interactive SSH terminal when
  pushing, and locally when pulling. SSH keys are not included in the archive.
- Both hosts need Bash 4+, Docker access, Docker Compose, GNU `tar` available as
  `tar`, gzip, rsync with `--protect-args` support, and SHA-256 tooling
  (`sha256sum` or `shasum`). Destination dialogs require whiptail. The migration
  account needs permission to read/copy container-owned files and preserve
  ownership, using sudo where required.
- Allow source downtime while a consistent snapshot is copied. Provide free
  space for that snapshot and its compressed archive on the source, and for
  the received archive and extracted project on the destination.
- For immediate activation, prepare the destination Traefik network and
  configuration. HTTPS also requires the chosen destination ACME resolver and
  a working DNS/challenge setup. HTTP development requires a destination proxy
  that does not redirect all HTTP traffic to HTTPS.

#### What travels together

Octojoom stops the source project's running containers, verifies they have
stopped, copies the project, and restarts the containers that were running.
It then creates one private `package.tar.gz` containing:

- The selected `docker-compose.yml` and supported Compose-relative bind-mount
  companion files, such as an explicitly referenced `./php.ini`.
- A project-specific `.env` containing only the variables referenced by that
  Compose file, read from its effective environment file.
- The project's `joomla/`, `db/`, and other files within its project directory.
- Metadata identifying the source deployment, architecture, and exact database
  image digest.

The existing gzip-compressed tar format preserves Unix ownership and modes.
Only this archive is transferred over SSH/rsync; the two hosts verify its
SHA-256 digest before import. Other projects' shared environment assignments
are excluded. Host-wide Cloudflare credentials and certificate storage remain
part of the destination host's setup.

#### Configure the destination

All configuration changes happen on the destination after transfer. Choose an
unused alphabetical project key, the destination hostname, and HTTP or HTTPS.
The source key may be retained if it is free on the destination. Where the
source image supports explicit Apache user/group IDs, the workflow can also
adjust those IDs and website ownership.

| Setting | Destination behavior |
| --- | --- |
| Database name, database users and passwords, table prefix, application secret | Preserved from the source |
| Container/service names and Joomla database hostname | Updated together for the destination project key |
| Environment variable names | Scoped to the destination key in its own Compose-directory `.env` |
| Project base path and Traefik network | Taken from the destination configuration |
| Hostname and HTTP/HTTPS routing | Set from destination choices |
| Joomla `force_ssl` | Preserve for HTTPS; set to `0` for HTTP |
| Nonempty Joomla `live_site` and `cookie_domain` | Updated for the destination; empty values remain empty |
| Database image | Pinned to the source database container's immutable repository digest |
| Destination shared `.env` and existing sites | Left unchanged |

Compose is validated without displaying resolved credentials before the new
project is published to available containers. Existing project directories,
container names, and hostnames are refused; this workflow creates a new
destination deployment and does not replace an existing one.

You may leave the prepared project disabled. If the destination proxy is
ready, Octojoom offers activation and checks container health, Joomla's actual
database connection, and the destination HTTP/HTTPS route. HTTPS checks verify
the hostname's certificate. Missing proxy prerequisites leave a prepared,
disabled project; a failed activation retains its files and attempts to stop
the imported containers, reporting if that stop also fails.

#### Supported layouts and operational limits

Complete migration supports Octojoom's generated Joomla bind-mount layout
with an installed `configuration.php` and its local MariaDB container. The
source database container must exist, its actual database mount must match
the selected project, and its image must have an immutable repository digest.
The destination architecture must match the source architecture. Moves between
architectures and database upgrades need a separate logical database
migration; this workflow does not upgrade an existing data directory.

Named Docker volumes, external databases, project symlinks or special files,
external filesystem mounts, and unsupported custom Compose dependencies or
configuration expressions are refused instead of being partially imported.
This is not an arbitrary Compose deployment migrator. Validate extension-
specific URLs, mail delivery, scheduled jobs, and external integrations for
the destination environment; they are not automatically converted into a
development or staging policy.

The source is retained and its previously running services are restarted.
**This is a consistent project copy, not an automatic production cutover.**
DNS is not changed, subsequent source writes are not synchronized, and the
source is not deleted. Coordinate the final write freeze and DNS switch when
using the copy to replace production.

#### Archives, cancellation, and recovery

Archives contain database data, `configuration.php`, and working credentials.
Treat them as sensitive backups. Migration uses private directories and
restrictive file permissions; Unix modes do not replace NTFS access controls
on Windows. SSH protects the transfer, but the archive itself is not encrypted.

Successful preparation, including a deliberately disabled destination, removes
the transfer archives. Cancellation during destination choices and transfer
or import failures retain available recovery archives and report their paths.
They are stored under the participating accounts' Octojoom configuration
directory in `migrations/migration.*/package.tar.gz`. If cleanup fails after
preparation, Octojoom reports that separately. Inspect the destination before
retrying, because a prepared project may already exist. Correct and enable
that available project rather than overwriting it, and remove retained
recovery workspaces once they are no longer needed.

Clone and complete migration share `joomla/.clone.lock` on each host. If an
abrupt interruption leaves the lock, verify that no clone or migration is
running before removing the empty lock directory. Check source service state
after a connection loss or forced termination.

The expert **Transfer Joomla Compose Folder Only** action and the separate
**Migrate Project Directory** action remain available for file transfers.
They do not perform complete-project credential scoping, coordinated database
stopping, or destination realignment. Stop relevant database services yourself
before copying raw database storage with these legacy actions.

### Help Menu (from the script)

<details>
<summary><strong>Show full help output</strong></summary>

```txt
Usage: octojoom [OPTION...]
	Options
	======================================================
   --type <type>
	set type you would like to work with
	example: octojoom --type joomla
	======================================================
   --task <task>
	set type of task you would like to perform
	example: octojoom --task setup
	======================================================
   --container <container.domain.name>
	Directly enabling or disabling a container with
	  the type=joomla and task=enable/disable set
	The container must exist, which means it was
	  setup previously
	Used without type and task Joomla-Enable is (default)
	example: octojoom --container "io.vdm.dev"
	======================================================
   --update
	to update your install
	example: octojoom --update
	======================================================
   --uninstall
	to uninstall this script
	example: octojoom --uninstall
	======================================================
	AVAILABLE FOR TO ANY CONTAINER
	======================================================
   -k|--key <key>
	set key for the docker compose container naming
	!! no spaces allowed in the key !!
	example: octojoom -k="vdm"
	example: octojoom --key="vdm"
	======================================================
   -e|--env-key <key>
	set key for the environment variable naming
	!! no spaces allowed in the key & must be UPPERCASE !!
	example: octojoom -e="VDM"
	example: octojoom --env-key="VDM"
	======================================================
   -d|--domain <domain.com>
	set key website domain
	!! must be domain.tld !!
	example: octojoom -d="joomla.org"
	example: octojoom --domain="joomla.org"
	======================================================
   -s|--sub-domain <domain.com>
	set key website sub domain
	!! no spaces allowed in the sub domain !!
	example: octojoom -s="jcb"
	example: octojoom --sub-domain="jcb"
	======================================================
	AVAILABLE FOR JOOMLA CONTAINER
	======================================================
   -j|--joomla-version <version-tag>
	see available tags here https://hub.docker.com/_/joomla
	example: octojoom -j=5.0
	example: octojoom --joomla-version=5.0
	======================================================
	AVAILABLE FOR OPENSSH CONTAINER
	======================================================
   -u|--username <username>
	set username of the container
	example: octojoom -u="ubuntu"
	example: octojoom --username="ubuntu"
	======================================================
   --uid <id>
	set container user id
	example: octojoom --uid=1000
	======================================================
   --gid <id>
	set container user group id
	example: octojoom --gid=1000
	======================================================
   -p|--port <port>
	set ssh port to use
	!! do not use 22 !!
	example: octojoom -p=2239
	example: octojoom --port=2239
	======================================================
   --ssh-dir <dir>
	set ssh directory name found in the .ssh dir
	of this repo for the container keys
		This directory has separate files for
		each public key allowed to access
		the container
	example: octojoom --ssh-dir="teamname"
	======================================================
   --sudo
	switch to add the container user to the
	sudo group of the container
	example: octojoom --sudo
	======================================================
   -t|--time-zone <time/zone>
	set time zone of the container
	!! must valid time zone !!
	example: octojoom -t="Africa/Windhoek"
	example: octojoom --time-zone="Africa/Windhoek"
	======================================================
	HELP ʕ•ᴥ•ʔ
	======================================================
   -h|--help
	display this help menu
	example: octojoom -h
	example: octojoom --help
	======================================================
			Octojoom
	======================================================
```

</details>

---

## 🔁 Updating Octojoom

Update to the latest version anytime:

```bash
octojoom --update
```

---

## 🧹 Uninstall

Remove Octojoom cleanly:

```bash
octojoom --uninstall
```

You'll be asked to choose:

* **Complete Uninstall:** Removes script, containers, and persistent volumes.
* **Script Only:** Keeps containers but removes Octojoom.
* **Selective Mode:** Lets you pick which parts to delete interactively.

---

## 🤝 Contributing

We welcome contributions of all levels — from documentation to new distro support!

### 🪄 How to Contribute

1. **Fork** this repository
2. **Create** a feature branch
3. **Make your changes**
4. **Run lint check and tests:**

   ```bash
   shellcheck src/octojoom
   bash tests/run.sh
   ```

   The tests need Bash 4 or newer (on macOS: `brew install bash`) and git, which
   fetches the pinned bats-core once. They run in a throw-away folder with
   stand-ins for whiptail, docker and sudo, so they never touch your containers
   or your Octojoom config. Every push and pull request to `master` or `staging`
   runs the same checks on Linux, macOS and Windows (`.github/workflows/tests.yml`).
   Ubuntu also runs the real Docker clone and migration regressions. See [the test guide](tests/README.md)
   for coverage, local commands, infrastructure requirements, and validation limits.
5. **Submit** a pull request with a clear explanation

> 💬 Found a bug or want to suggest improvements?
> Open an issue — we'd love your feedback!

---

## 🧾 License

```text
Copyright (C) 2021-2026
Llewellyn van der Merwe

Licensed under the GNU General Public License v2 (GPLv2)
See LICENSE for details.
```

---

## 🧭 Quick Reference

| Command                               | Description               |
| ------------------------------------- | ------------------------- |
| `octojoom -h`                         | Show help menu            |
| `octojoom --type joomla --task setup` | Create a Joomla container |
| `octojoom --type joomla --task clone` | Clone a Joomla container (compose file, env values and project files) |
| `octojoom --type joomla --task clonefiles` | Clone only the project files of a container |
| `octojoom --type joomla --task migrate` | Package and push/pull a complete project, then configure its destination |
| `octojoom --update`                   | Update the script         |
| `octojoom --uninstall`                | Uninstall Octojoom        |
| `octojoom`                            | Launch interactive mode   |

---

<p align="center">
✨ Built with love by the <a href="https://github.com/octoleo">Octoleo</a> Team ✨
</p>
