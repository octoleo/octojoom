# Easy Docker Deployment (UBUNTU ONLY)
With this script we can easily deploy docker containers of Joomla and Openssh. This combination of these tools give rise to a powerful and very secure shared development environment.

Both the installation and deployment script has **command input** options as seen in the menus below, but these command ar _not the only way_ to set these values. When the values are **omitted** you will be _asked in the terminal_ to manually enter the required values as needed. Furthermore, the use of **env variables** are also heavily used across the script. There are more than one .env file and the script will set those up for you whenever you run a task that make use of env variables the script will check if those values exist, and if they don't it will ask for them, and store them automatically for future use. That same time the output message to the terminal will show you where the specific .env file can be found.

---
# Install
```shell
$ git clone https://git.vdm.dev/octoleo/docker-deploy.git
$ cd docker-deploy/src
$ sudo chmod +x install.sh
$ sudo ./install.sh
```
> To see the installation help menu:
```shell
$ ./install.sh -h
```

### Help Menu (install)
```txt
Usage: ./install.sh [OPTION...]
	Options
	======================================================
   --src-path=<path>|--src=<path>
	set path to the script source folder
	example: ./install.sh --src=/home/username/Docker/src
	example: ./install.sh --src-path=/home/username/Docker/src
	======================================================
   --repo-path=<path>|--repo=<path>
	set path to the repository folder
	example: ./install.sh --repo=/home/username/Docker
	example: ./install.sh --repo-path=/home/username/Docker
	======================================================
   --project-path=<path>|--project=<path>
	set path to the projects folder
	example: ./install.sh --project=/home/username/Projects
	example: ./install.sh --project-path=/home/username/Projects
	======================================================
   -f|--force
	force installation
	example: ./install.sh -f
	example: ./install.sh --force
	======================================================
   --host
	always update your host file
	example: ./install.sh --host
	======================================================
   -h|--help
	display this help menu
	example: ./install.sh -h
	example: ./install.sh --help
	======================================================
			docker-deploy v1.0
	======================================================
```
---
# Usage

> To see the usage help menu
```shell
$ docker-deploy -h
```
### Help Menu (docker-deploy)
```txt
Usage: docker-deploy [OPTION...]
	Options
	======================================================
   --type <type>
	set type you would like to work with
	example: docker-deploy --type joomla
	======================================================
   --task <task>
	set type of task you would like to perform
	example: docker-deploy --task setup
	======================================================
   --update
	to update your install
	example: docker-deploy --update
	======================================================
   --uninstall
	to uninstall this script
	example: docker-deploy --uninstall
	======================================================
	AVAILABLE FOR TO ANY CONTAINER
	======================================================
   -k|--key <key>
	set key for the docker compose container naming
	!! no spaces allowed in the key !!
	example: docker-deploy -k="vdm"
	example: docker-deploy --key="vdm"
	======================================================
   -e|--env-key <key>
	set key for the environment variable naming
	!! no spaces allowed in the key & must be UPPERCASE !!
	example: docker-deploy -e="VDM"
	example: docker-deploy --env-key="VDM"
	======================================================
   -d|--domain <domain.com>
	set key website domain
	!! must be domain.tld !!
	example: docker-deploy -d="vdm.dev"
	example: docker-deploy --domain="vdm.dev"
	======================================================
	AVAILABLE FOR JOOMLA CONTAINER
	======================================================
   -j|--joomla-version <version>
	set Joomla version number
	!! only number allowed !!
	example: docker-deploy -j=3.10
	example: docker-deploy --joomla-version=3.10
	======================================================
   -s|--sub-domain <domain.com>
	set key website sub domain
	!! no spaces allowed in the sub domain !!
	example: docker-deploy -s="jcb"
	example: docker-deploy --sub-domain="jcb"
	======================================================
	AVAILABLE FOR OPENSSH CONTAINER
	======================================================
   -u|--username <username>
	set username of the container
	example: docker-deploy -u="ubuntu"
	example: docker-deploy --username="ubuntu"
	======================================================
   --uid <id>
	set container user id
	example: docker-deploy --uid=1000
	======================================================
   --gid <id>
	set container user group id
	example: docker-deploy --gid=1000
	======================================================
   -p|--port <port>
	set ssh port to use
	!! do not use 22 !!
	example: docker-deploy -p=2239
	example: docker-deploy --port=2239
	======================================================
   --ssh-dir <dir>
	set ssh directory name found in the .ssh dir
	of this repo for the container keys
		This directory has separate files for
		each public key allowed to access
		the container
	example: docker-deploy --ssh-dir="teamname"
	======================================================
   --sudo
	switch to add the container user to the
	sudo group of the container
	example: docker-deploy --sudo
	======================================================
   -t|--time-zone <time/zone>
	set time zone of the container
	!! must valid time zone !!
	example: docker-deploy -t="Africa/Windhoek"
	example: docker-deploy --time-zone="Africa/Windhoek"
	======================================================
	HELP ʕ•ᴥ•ʔ
	======================================================
   -h|--help
	display this help menu
	example: docker-deploy -h
	example: docker-deploy --help
	======================================================
			docker-deploy v1.0
	======================================================
```
---
# Uninstall

```shell
$ docker-deploy --uninstall
```
---
# Free Software License
```txt
@copyright  Copyright (C) 2021 Llewellyn van der Merwe. All rights reserved.
@license    GNU General Public License version 2; see LICENSE
```

