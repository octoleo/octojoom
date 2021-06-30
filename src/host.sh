#!/bin/bash

# check if we should add to host file
if $VDM_UPDATE_HOST; then
  # check if already in host file
  if grep -q "${1:-$VDM_SUBDOMAIN}.${2:-$VDM_DOMAIN}" /etc/hosts; then
    echo "[notice] ${USER^}, ${1:-$VDM_SUBDOMAIN}.${2:-$VDM_DOMAIN} is already in the /etc/hosts file."
  else
    # just a notice for now
    echo "[notice] ${USER^}, you should add ${1:-$VDM_SUBDOMAIN}.${2:-$VDM_DOMAIN} to the /etc/hosts file."
    # sudo echo "127.0.0.1       ${VDM_SUBDOMAIN}.${VDM_DOMAIN}" >> /etc/hosts
  fi
fi
