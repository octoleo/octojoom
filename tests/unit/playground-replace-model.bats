#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2034
load ../helpers/common

setup() {
  bats_require_minimum_version 1.5.0
  octojoom_setup
  octojoom_config
  work="$SANDBOX/candidate"
  mkdir -p "$work"
  VDM_SITE_DIR="$SANDBOX/available/shop.example.test"
  mkdir -p "$VDM_SITE_DIR"
  touch "$work/candidate.ini" "$VDM_SITE_DIR/nginx.conf"
  VDM_DB_HOST="old-db:3306"
  token=0123456789abcdef0123456789abcdef
  info='{"app":"joomla","db":"mysql","root":"/var/www/html/public","web":"nginx","ini":"/opt/php/conf.d/zz-octojoom.ini"}'
  local old_web old_compose
  old_web=$(joomlaWebHostPath "$SANDBOX/web") && old_compose=$(joomlaWebHostPath "$VDM_SITE_DIR")
  joomlaSiteJSON -n --arg src "$old_web" --arg site "$old_compose" '{
    name:"shop",networks:{traefik:{external:true}},volumes:{data:{name:"original_db"},extra:{name:"extra"}},
    services:{
      joomla:{image:"joomla",environment:{JOOMLA_DB_HOST:"old-db:3306"},depends_on:{mysql:{condition:"service_healthy"}},
        container_name:"production-joomla",labels:{"traefik.enable":"true"},ports:[{target:80,published:"8080"}],
        volumes:[{type:"bind",source:$src,target:"/var/www/html"},
          {type:"bind",source:($site+"/php.ini"),target:"/opt/php/conf.d/zz-octojoom.ini",read_only:true}]},
      mysql:{image:"mysql",volumes:[{type:"volume",source:"data",target:"/var/lib/mysql"}]},
      nginx:{image:"nginx",depends_on:{joomla:{condition:"service_healthy"}},volumes:[
        {type:"bind",source:$src,target:"/var/www/html",read_only:true},
        {type:"bind",source:($site+"/nginx.conf"),target:"/etc/nginx/conf.d/default.conf",read_only:true}]},
      mail:{image:"mail",volumes:[{type:"volume",source:"extra",target:"/data"}]}
    }
  }' > "$work/proposed.json"
  joomlaSiteJSON -n --arg src "$SANDBOX/web" --arg dst "$SANDBOX/new-web" '{
    web:{type:"bind",original:$src,candidate:$dst},db:{type:"volume",original:"original_db",candidate:"replacement_db"}
  }' > "$work/storage.json"
}

@test "replacement model maps both FPM web mounts, scoped PHP and fresh database to a private project" {
  run joomlaPlaygroundReplacementModel "$work" "$token" joomla mysql nginx "$info"
  assert_success
  local web ini
  web=$(joomlaWebHostPath "$SANDBOX/new-web") && ini=$(joomlaWebHostPath "$work/candidate.ini")
  joomlaSiteJSON -e --arg web "$web" --arg ini "$ini" --arg name "octojoom-playground-$token" '
    .name==$name and .networks=={default:{internal:true}} and (.services|keys)==["joomla","mysql","nginx"] and
    .services.joomla.volumes[0].source==$web and .services.nginx.volumes[0].source==$web and
    .services.joomla.volumes[1].source==$ini and .services.nginx.volumes[1].read_only==true and
    .volumes=={data:{name:"replacement_db",external:true}} and
    .services.mysql.networks.default.aliases==["old-db"] and
    .services.joomla.ports==null and .services.joomla.container_name==null and .services.joomla.labels=={"traefik.enable":"false"}
  ' < "$work/candidate.json"
}

@test "replacement rejects extra host access and old storage mismatches" {
  cp "$work/proposed.json" "$work/baseline.json"
  local filter
  for filter in '.services.joomla.volumes += [{type:"bind",source:"/some/original",target:"/var/www/html/custom"}]' \
    '.services.joomla.volumes[0].source="/other-site"' '.services.mysql.volumes[0].volume.subpath="other-site"' \
    '.services.joomla.privileged=true' '.services.nginx.volumes[1].read_only=false'; do
    joomlaSiteJSON "$filter" < "$work/baseline.json" > "$work/proposed.json"
    run joomlaPlaygroundReplacementModel "$work" "$token" joomla mysql nginx "$info"
    assert_failure
    refute_command '^docker '
  done
}

@test "replacement accepts a local directory but refuses a missing directory and filesystem root" {
  local directory="$work/site storage" root=/
  mkdir "$directory"
  if is_windows; then
    root=$(cygpath -am -- "$directory")
    root="${root%%/*}/"
  fi
  run joomlaPlaygroundReplaceableDirectory "$directory"
  assert_success
  run joomlaPlaygroundReplaceableDirectory "$directory/missing"
  assert_failure
  run joomlaPlaygroundReplaceableDirectory "$root"
  assert_failure
}

@test "replacement changes only owned environment entries in a selected service" {
  local file="$work/site.yml" property="$work/environment"
  cat > "$file" <<'COMPOSE'
services:
  app:
    image: joomla
    environment:
      JOOMLA_DB_HOST: "destination"
      JOOMLA_ADMIN_EMAIL: "old-admin@example.test"
      JOOMLA_EXTENSIONS_URLS: "old-extension"
      JOOMLA_CLI_COMMANDS: "old-command"
      JOOMLA_DB_NAME: "old-db"
      CUSTOM: "site-specific"
    restart: always
COMPOSE
  joomlaPlaygroundReplacementEnvironment "$file" app app SHOP mysql "$property"
  assert_file_contains "$property" 'JOOMLA_DB_NAME: "${VDM_SHOP_DB}"'
  assert_file_contains "$property" 'JOOMLA_DB_PREFIX: "${VDM_SHOP_JOOMLA_DB_PREFIX}"'
  assert_file_contains "$property" 'CUSTOM: "site-specific"'
  assert_file_contains "$property" 'JOOMLA_DB_HOST: "destination"'
  refute_file_contains "$property" 'old-'
}

@test "replacement verifies the Compose file behind occupied project identities" {
  local VDM_SITE_COMPOSE="$VDM_SITE_DIR/docker-compose.yml"
  touch "$VDM_SITE_COMPOSE"
  docker() {
    case "$1" in
      ps) printf '%s\n' 'site-container';;
      inspect) printf '%s\n' "$compose_origin";;
      *) return 1;;
    esac
  }
  local compose_origin
  compose_origin=$(joomlaWebHostPath "$VDM_SITE_COMPOSE")
  run joomlaPlaygroundReplacementProject shop.example.test shop
  assert_success
  mkdir -p "$SANDBOX/other"
  touch "$SANDBOX/other/docker-compose.yml"
  compose_origin=$(joomlaWebHostPath "$SANDBOX/other/docker-compose.yml")
  run joomlaPlaygroundReplacementProject shop.example.test shop
  assert_failure
  assert_output_contains 'Another Compose configuration'
}
