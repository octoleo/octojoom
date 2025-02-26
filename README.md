<h2><img align="middle" src="https://raw.githubusercontent.com/odb/official-bash-logo/master/assets/Logos/Icons/PNG/64x64.png" >
Octojoom - Easy Joomla! Docker Deployment
</h2>

Written by Llewellyn van der Merwe (@llewellynvdm)

With this script we can easily deploy docker containers of Joomla and Openssh. This combination of these tools give rise to a powerful and very secure shared development environment.

This program has **command input** options as seen in the menus below, but these command are _not the only way_ to set these values.
When the values are **omitted** you will be _asked in the terminal_ to manually enter the required values as needed.
Furthermore, the use of **env variables** are also heavily used across the script.
There are more than one .env file and the script will set those up for you whenever you run a task that make use of env variables
the script will check if those values exist, and if they don't it will ask for them, and store them automatically for future use.
That same time the output message to the terminal will show you where the specific .env file can be found.

Linted by [#ShellCheck](https://github.com/koalaman/shellcheck)

> program only for ubuntu/debian systems at this time (should you like to use it on other OS's please open and issue...)

---
# Install
```shell
$ sudo curl -L "https://raw.githubusercontent.com/octoleo/octojoom/refs/heads/master/src/octojoom" -o /usr/local/bin/octojoom
$ sudo chmod +x /usr/local/bin/octojoom
```

---
# Usage

> To see the usage help menu
```shell
$ octojoom -h
```
### Help Menu (octojoom)
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
   --access-token <token>
	to update the program you will need an access token
	from https://git.vdm.dev/user/settings/applications
	example: octojoom --access-token xxxxxxxxxxx
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
---
# Uninstall

```shell
$ octojoom --uninstall
```
---
# Free Software License
```txt
@copyright  Copyright (C) 2021 Llewellyn van der Merwe. All rights reserved.
@license    GNU General Public License version 2; see LICENSE
```

