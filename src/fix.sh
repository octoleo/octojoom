#!/bin/bash

# check that our project path is correct
[ -e "${VDM_PROJECT_PATH}" ] || {
  echo "[error] Project path (${VDM_PROJECT_PATH}) does not exist."
  exit 1
}

# make sites available selection
function getProjectsAvailable() {
  # some house cleaning
  PS3_old=$PS3
  # some defaults
  export PS3="Please select project to fix: "
  # Start our little Menu
  select menu in $(ls "${VDM_PROJECT_PATH}"); do
    case $REPLY in
    *)
      SELECTED="$menu"
      ;;
    esac
    break
  done
  # restore the default
  export PS3=$PS3_old
  # return selection
  echo "$SELECTED"
}

# set the local values
VDM_PROJECT="${1:-$VDM_PROJECT}"
# check that we have what we need
# shellcheck disable=SC2015
[ ${#VDM_PROJECT} -ge 1 ] && [ -d "${VDM_PROJECT_PATH}/${VDM_PROJECT}" ] || {
  VDM_PROJECT=$(getProjectsAvailable)
  # make sure value was entered
  [ ${#VDM_PROJECT} -ge 1 ] && [ -d "${VDM_PROJECT_PATH}/${VDM_PROJECT}" ] || exit
}

### Fix the folder ownership of Joomla folders
#
echo "[notice] Fix the folder ownership of ${VDM_PROJECT} Joomla folders"
#
sudo chown -R www-data:www-data "${VDM_PROJECT_PATH}/${VDM_PROJECT}/joomla"

### Fix the folder permissions for the Joomla websites
#
echo "[notice] Fix the file and folder permissions for the ${VDM_PROJECT} Joomla website"
#
# Change the file permissions
sudo find "${VDM_PROJECT_PATH}/${VDM_PROJECT}/joomla" -type f -exec chmod 644 {} \;
sudo find "${VDM_PROJECT_PATH}/${VDM_PROJECT}/joomla/configuration.php" -type f -exec chmod 444 {} \;
[ -f "${VDM_PROJECT_PATH}/${VDM_PROJECT}/joomla/.htaccess" ] &&
  sudo find "${VDM_PROJECT_PATH}/${VDM_PROJECT}/joomla/.htaccess" -type f -exec chmod 400 {} \;
[ -f "${VDM_PROJECT_PATH}/${VDM_PROJECT}/joomla/php.ini" ] &&
  sudo find "${VDM_PROJECT_PATH}/${VDM_PROJECT}/joomla/php.ini" -type f -exec chmod 400 {} \;
# Change the folder permissions
sudo find /"home/${USER}/Projects/${VDM_PROJECT}/joomla" -type d -exec chmod 755 {} \;
# Change the image folder permissions
# chmod 707 "${VDM_PROJECT_PATH}/${VDM_PROJECT}/joomla/images"
# chmod 707 "${VDM_PROJECT_PATH}/${VDM_PROJECT}/joomla/images/stories"

### Fix the folder permissions so the active user (1000) can access the files
#
echo "[notice] Fix the folder permissions of ${VDM_PROJECT} joomla so user:1000 can access them"
#
sudo setfacl -R -m u:1000:rwx "${VDM_PROJECT_PATH}/${VDM_PROJECT}/joomla"

### Fix the folder ownership of database folders
#
echo "[notice] Fix the folder ownership of ${VDM_PROJECT} database folders"
#
sudo chown -R systemd-coredump:systemd-coredump "${VDM_PROJECT_PATH}/${VDM_PROJECT}/db"

### Fix the folder permissions for the database files
#
echo "[notice] Fix the file and folder permissions for the ${VDM_PROJECT} database files"
#
# Change the file permissions
sudo find "${VDM_PROJECT_PATH}/${VDM_PROJECT}/db" -type f -exec chmod 660 {} \;
sudo find "${VDM_PROJECT_PATH}/${VDM_PROJECT}/db" -type d -exec chmod 700 {} \;
