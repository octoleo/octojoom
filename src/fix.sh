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
vdm_project="${1:-$VDM_PROJECT}"
# check that we have what we need
[ ${#vdm_project} -ge 1 ] && [ -d "${VDM_PROJECT_PATH}/${vdm_project}" ] || {
  vdm_project=$(getProjectsAvailable)
  # make sure value was entered
  [ ${#vdm_project} -ge 1 ] && [ -d "${VDM_PROJECT_PATH}/${vdm_project}" ] || exit
}

### Fix the folder ownership of Joomla folders
#
echo "[notice] Fix the folder ownership of ${vdm_project} Joomla folders"
#
sudo chown -R www-data:www-data "${VDM_PROJECT_PATH}/${vdm_project}/joomla"
sudo setfacl -R -m u:llewellyn:rwx "${VDM_PROJECT_PATH}/${vdm_project}/joomla"

### Fix the folder permissions for the Joomla websites
#
echo "[notice] Fix the file and folder permissions for the ${vdm_project} Joomla website"
#
# Change the file permissions
sudo find "${VDM_PROJECT_PATH}/${vdm_project}/joomla" -type f -exec chmod 644 {} \;
sudo find "${VDM_PROJECT_PATH}/${vdm_project}/joomla/configuration.php" -type f -exec chmod 444 {} \;
[ -f "${VDM_PROJECT_PATH}/${vdm_project}/joomla/.htaccess" ] &&
  sudo find "${VDM_PROJECT_PATH}/${vdm_project}/joomla/.htaccess" -type f -exec chmod 400 {} \;
[ -f "${VDM_PROJECT_PATH}/${vdm_project}/joomla/php.ini" ] &&
  sudo find "${VDM_PROJECT_PATH}/${vdm_project}/joomla/php.ini" -type f -exec chmod 400 {} \;
# Change the folder permissions
sudo find /"home/${USER}/Projects/${vdm_project}/joomla" -type d -exec chmod 755 {} \;
# Change the image folder permissions
# chmod 707 "${VDM_PROJECT_PATH}/${vdm_project}/joomla/images"
# chmod 707 "${VDM_PROJECT_PATH}/${vdm_project}/joomla/images/stories"

### Fix the folder ownership of database folders
#
echo "[notice] Fix the folder ownership of ${vdm_project} database folders"
#
sudo chown -R systemd-coredump:systemd-coredump "${VDM_PROJECT_PATH}/${vdm_project}/db"

### Fix the folder permissions for the database files
#
echo "[notice] Fix the file and folder permissions for the ${vdm_project} database files"
#
# Change the file permissions
sudo find "${VDM_PROJECT_PATH}/${vdm_project}/db" -type f -exec chmod 660 {} \;
sudo find "${VDM_PROJECT_PATH}/${vdm_project}/db" -type d -exec chmod 700 {} \;
