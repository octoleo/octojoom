<h2 align="center">
  <img align="middle" src="https://raw.githubusercontent.com/octoleo/octojoom/master/graphics/OctoJoomAlt.svg">
  <br>
  <img align="middle" src="https://raw.githubusercontent.com/odb/official-bash-logo/master/assets/Logos/Icons/PNG/64x64.png">
  Octojoom — Easy Joomla! Docker Deployment
</h2>

<p align="center">
  <a href="https://github.com/koalaman/shellcheck">
    <img src="https://img.shields.io/badge/ShellCheck-passing-brightgreen?logo=gnu-bash&logoColor=white" alt="ShellCheck passing">
  </a>
  <img src="https://img.shields.io/badge/Ubuntu-tested-brightgreen?logo=ubuntu&logoColor=white" alt="Ubuntu Tested">
  <img src="https://img.shields.io/badge/macOS-tested-blue?logo=apple&logoColor=white" alt="macOS Tested">
  <img src="https://img.shields.io/badge/Windows-supported-0078D6?logo=windows&logoColor=white" alt="Windows Supported">
  <img src="https://img.shields.io/badge/License-GPLv2-blue.svg" alt="License GPLv2">
  <img src="https://img.shields.io/badge/Version-3.7.1-orange" alt="Version 3.7.1">
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

You’ll be asked to choose:

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
4. **Run lint check:**

   ```bash
   shellcheck src/octojoom
   ```
5. **Submit** a pull request with a clear explanation

> 💬 Found a bug or want to suggest improvements?
> Open an issue — we’d love your feedback!

---

## 🧾 License

```text
Copyright (C) 2021–2025
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
| `octojoom --update`                   | Update the script         |
| `octojoom --uninstall`                | Uninstall Octojoom        |
| `octojoom`                            | Launch interactive mode   |

---

<p align="center">
✨ Built with love by the <a href="https://github.com/octoleo">Octoleo</a> Team ✨
</p>
