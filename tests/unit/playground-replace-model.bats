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
      joomla:{image:"joomla",command:null,entrypoint:null,environment:{JOOMLA_DB_HOST:"old-db:3306"},depends_on:{mysql:{condition:"service_healthy"}},
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
    .name==$name and .networks=={default:{driver:"bridge",internal:true,enable_ipv6:false,
      driver_opts:{"com.docker.network.bridge.gateway_mode_ipv4":"isolated"}}} and (.services|keys)==["joomla","mysql","nginx"] and
    .services.joomla.volumes[0].source==$web and .services.nginx.volumes[0].source==$web and
    .services.joomla.volumes[1].source==$ini and .services.nginx.volumes[1].read_only==true and
    .volumes=={data:{name:"replacement_db",external:true}} and
    .services.mysql.networks.default.aliases==["old-db"] and
    (.services.joomla | (has("command") or has("entrypoint")) | not) and
    .services.joomla.ports==null and .services.joomla.container_name==null and .services.joomla.labels=={"traefik.enable":"false"}
  ' < "$work/candidate.json"
}

@test "the activation check runs final mounts and healthchecks without exposing host or sidecar routes" {
  local final_web final_ini
  final_web=$(joomlaWebHostPath "$SANDBOX/web") && final_ini=$(joomlaWebHostPath "$VDM_SITE_DIR/php.ini")
  joomlaSiteJSON '.services.nginx.labels={"traefik.http.routers.shop.rule":"Host(shop.example.test)","caddy":"shop.example.test"} |
    .services.nginx.ports=[{target:80,published:"443",host_ip:"127.0.0.1"}] |
    .services.nginx.deploy={labels:{"traefik.enable":"true"},resources:{limits:{memory:"134217728"}}} |
    .services.nginx.healthcheck={test:["CMD","custom-check","$$literal"],interval:"12s",retries:3} |
    .services.mysql.ports=[{target:3306,published:"3307"}] | .services.mail.ports=[{target:80,published:"8080"}]' \
    < "$work/proposed.json" > "$work/revised.json"
  mv "$work/revised.json" "$work/proposed.json"
  joomlaPlaygroundReplacementModel "$work" "$token" joomla mysql nginx "$info"
  printf '%s\n' "$info" > "$work/services.json"
  joomlaSiteJSON '.volumes.data.name="replacement_db"' < "$work/proposed.json" > "$work/published-model.json"
  # Prior to quiescing, the proposed private project must be unused.
  # shellcheck disable=SC2317
  docker() {
    case "$1 $2" in
      'compose --file')
        [ "$3 $4 $5" = "verify.json config --quiet" ] && [ "$COMPOSE_PROJECT_NAME" = "octojoom-verify-$token" ] || return 1
        if [ -n "$REAL_DOCKER" ] && "$REAL_DOCKER" compose version >/dev/null 2>&1; then "$REAL_DOCKER" "$@"; fi;;
      'ps -aq'|'network ls') return 0;;
      *) return 1;;
    esac
  }
  joomlaPlaygroundPrepareVerifyModel "$work" "$token"
  (
    cd "$work"
    joomlaSiteJSON -e --arg name "octojoom-verify-$token" --arg web "$final_web" --arg ini "$final_ini" \
      --slurpfile published published-model.json --slurpfile staged candidate.json '
      .name==$name and (.services|keys)==["joomla","mysql","nginx"] and .networks==$staged[0].networks and
      all(.services[]; .ports==null and .container_name==null and .labels=={"traefik.enable":"false"} and
        (.networks|keys)==["default"] and .deploy.labels==null) and
      .services.nginx.healthcheck==$published[0].services.nginx.healthcheck and
      .services.nginx.deploy.resources==$published[0].services.nginx.deploy.resources and
      .services.mysql.networks.default.aliases==["old-db"] and
      .services.joomla.volumes[0].source==$web and .services.nginx.volumes[0].source==$web and
      .services.joomla.volumes[1].source==$ini and .volumes=={data:{external:true,name:"replacement_db"}}
    ' < verify.json
  )
  joomlaSiteJSON '.services.nginx.volumes[0].source="/changed/after-staging"' < "$work/published-model.json" > "$work/revised.json"
  mv "$work/revised.json" "$work/published-model.json"
  run joomlaPlaygroundPrepareVerifyModel "$work" "$token"
  assert_failure
}

@test "replacement rejects explicit service commands and entrypoints including empty overrides" {
  cp "$work/proposed.json" "$work/baseline.json"
  local override
  for override in '.services.joomla.command=["php","-v"]' '.services.joomla.command=[]' \
    '.services.mysql.entrypoint=["sh"]' '.services.mysql.entrypoint=""'; do
    joomlaSiteJSON "$override" < "$work/baseline.json" > "$work/proposed.json"
    run joomlaPlaygroundReplacementModel "$work" "$token" joomla mysql nginx "$info"
    assert_failure
    assert_output_contains 'unsupported service command or entrypoint'
  done
}

@test "replacement rejects extra host access and old storage mismatches" {
  cp "$work/proposed.json" "$work/baseline.json"
  local filter
  for filter in '.services.joomla.volumes += [{type:"bind",source:"/some/original",target:"/var/www/html/custom"}]' \
    '.services.joomla.volumes[0].source="/other-site"' '.services.mysql.volumes[0].volume.subpath="other-site"' \
    '.services.joomla.privileged=true' '.services.nginx.volumes[1].read_only=false' \
    '.services.joomla.network_mode="host"' '.services.nginx.depends_on.mail={condition:"service_started"}' \
    '.services.joomla.deploy.replicas=2' '.services.joomla.logging.driver="fluentd"'; do
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

@test "a new Apache Playground site keeps the stock healthcheck with a nested working root" {
  local VDM_CONTAINER_TYPE=joomla VDM_SUBDOMAIN=shop VDM_DOMAIN=example.test VDM_WEBSERVER=apache
  local VDM_DOCROOT=store/public VDM_J_REPO=joomla VDM_JV=latest
  joomlaSetupWebPrepare "$work"
  [[ "$VDM_WEB_WORKING_DIR" == *'/var/www/html/store/public'* ]]
  gen_joomla_compose shop SHOP shop example.test > "$work/generated.yml"
  local expected
  expected=$(cat <<'YAML'
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 5s
      retries: 5
YAML
  )
  assert_equal "$(joomlaServiceProperty "$work/generated.yml" joomlashop healthcheck)" "$expected"
}

@test "replacement preserves stock and custom Apache healthcheck definitions" {
  info=$(joomlaSiteJSON '.web="127.0.0.1"' <<< "$info")
  local healthcheck
  for healthcheck in \
    '{"test":["CMD","curl","-f","http://localhost/"],"interval":"30s","timeout":"5s","retries":5}' \
    '{"test":["CMD","custom-check"],"interval":"40s","timeout":"8s","start_period":"25s","retries":7}'; do
    joomlaSiteJSON --argjson check "$healthcheck" '.services.joomla.healthcheck=$check' \
      < "$work/proposed.json" > "$work/revised.json"
    mv "$work/revised.json" "$work/proposed.json"
    joomlaPlaygroundReplacementModel "$work" "$token" joomla mysql 127.0.0.1 "$info"
    joomlaSiteJSON -e --argjson check "$healthcheck" '.services.joomla.healthcheck==$check' < "$work/candidate.json"
  done
}

@test "replacement verifies the Compose file behind occupied project identities" {
  local VDM_SITE_COMPOSE="$VDM_SITE_DIR/docker-compose.yml"
  touch "$VDM_SITE_COMPOSE"
  # Bats runs each test in its own shell. The product calls this test's docker stub.
  # shellcheck disable=SC2317
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

@test "website seeding accepts stored Apache IDs, fresh numeric IDs and image defaults" {
  mkdir "$work/website"
  # The seeding helper invokes this test-local Docker stub indirectly.
  # shellcheck disable=SC2317
  docker() {
    cat >/dev/null
    # The guest shell receives root, UID, GID, file bytes and database bytes.
    printf '%s:%s\n' "${@: -4:1}" "${@: -3:1}"
  }
  local -a seed=(joomlaPlaygroundSeedWebsite "$work/website" web db image . 0 0 "$token")
  VDM_PUID='#1234' VDM_PGID='#5678' run "${seed[@]}"
  assert_success
  assert_equal "$output" '1234:5678'
  VDM_PUID=1234 VDM_PGID=5678 run "${seed[@]}"
  assert_success
  assert_equal "$output" '1234:5678'
  VDM_PUID='' VDM_PGID='' run "${seed[@]}"
  assert_success
  assert_equal "$output" ':'
}

@test "private MySQL startup provisions literal credentials without changing the final Compose model" {
  cat > "$work/candidate.json" <<'JSON'
{"services":{"mysql":{"environment":{"MYSQL_DATABASE":"shop_data","MYSQL_USER":"shop","MYSQL_PASSWORD":"a'\\$$b","MYSQL_ROOT_PASSWORD":"root'credential","MYSQL_ROOT_HOST":"localhost"}}}}
JSON
  cp "$work/candidate.json" "$work/final.before"
  run joomlaPlaygroundDatabaseBootstrap "$work" mysql mysql
  assert_success
  [ -z "$output" ]
  cmp "$work/final.before" "$work/candidate.json"
  joomlaSiteJSON -e '.services.mysql | (.environment | keys)==["MYSQL_ROOT_HOST","MYSQL_ROOT_PASSWORD"] and
    (.environment.MYSQL_ROOT_PASSWORD | test("^[a-f0-9]{64}$")) and
    (.volumes | length==1) and .volumes[0].read_only' < "$work/bootstrap.json" >/dev/null
  local bootstrap_password
  IFS= read -r bootstrap_password < "$work/bootstrap-root"
  [[ "$bootstrap_password" =~ ^[a-f0-9]{64}$ ]]
  [ "$(joomlaSiteJSON -r .services.mysql.environment.MYSQL_ROOT_PASSWORD < "$work/bootstrap.json")" = "$bootstrap_password" ]
  assert_file_contains "$work/bootstrap-account.sql" "IDENTIFIED BY 'a''\\\$b'"
  assert_file_contains "$work/bootstrap-root.sql" "ALTER USER 'root'@'localhost'"
  refute_file_contains "$work/bootstrap-root.sql" "'root'@'%'"
}

@test "native database entrypoints retain their ordinary credential path" {
  printf '%s\n' '{"services":{"db":{"environment":{"MYSQL_DATABASE":"shop","MYSQL_USER":"shop","MYSQL_PASSWORD":"simple"}}}}' > "$work/candidate.json"
  joomlaPlaygroundDatabaseBootstrap "$work" db mysql
  refute_file_exists "$work/bootstrap.json"
  joomlaSiteJSON '.services.db.environment.MYSQL_PASSWORD="a\u0027quote"' < "$work/candidate.json" > "$work/maria.json"
  mv "$work/maria.json" "$work/candidate.json"
  joomlaPlaygroundDatabaseBootstrap "$work" db mariadb
  refute_file_exists "$work/bootstrap.json"
}

# Docker protects named-volume references itself. These fixtures also expose
# its backing directory through an ordinary bind in a second site's model or
# in the live container inventory.
original_volume_fixture() {
  local site_dir="$VDM_REPO_PATH/joomla/available"
  mkdir -p "$work/web" "$work/backing" "$site_dir/shop.example.test" "$site_dir/other.example.test"
  touch "$site_dir/shop.example.test/docker-compose.yml" "$site_dir/other.example.test/docker-compose.yml"
  joomlaSiteJSON -n --arg path "$work/backing" '[{Name:"old_web",CreatedAt:"t1",Driver:"local",Scope:"local",Options:null,Labels:{},Mountpoint:$path}]' > "$work/web/original-volume.json"
  cp "$work/web/original-volume.json" "$work/volume.json"
  echo replacement_web > "$work/web/new-volume"
  echo '{"original":"old_web"}' > "$work/web/mount.json"
  echo '{"volumes":{"web":{"name":"old_web"}},"services":{"app":{"volumes":[{"type":"volume","source":"web","target":"/var/www/html"}]}}}' > "$work/selected.json"
  echo '{"services":{}}' > "$work/neighbor.json"
  joomlaStorageComposeModel() {
    case "$1" in
      shop.example.test) cat "$work/selected.json";;
      other.example.test) cat "$work/neighbor.json";;
      *) return 1;;
    esac
  }
  joomlaSiteCompose() {
    case "$*" in
      'shop.example.test ps -aq') return 0;;
      *) return 1;;
    esac
  }
  docker() {
    case "$*" in
      'volume inspect old_web') cat "$work/volume.json";;
      'ps -aq') if [ -f "$work/live.json" ]; then echo neighbor; fi;;
      'inspect neighbor') cat "$work/live.json";;
      'volume rm old_web') touch "$work/removed";;
      *) return 1;;
    esac
  }
}

@test "cutover refuses a changed volume identity or a late configured bind of its backing directory" {
  original_volume_fixture
  run joomlaPlaygroundCheckOriginalVolume shop.example.test old_web "$work/web" /var/www/html
  assert_success

  joomlaSiteJSON '.[0].CreatedAt="t2"' < "$work/web/original-volume.json" > "$work/volume.json"
  run joomlaPlaygroundCheckOriginalVolume shop.example.test old_web "$work/web" /var/www/html
  assert_failure
  cp "$work/web/original-volume.json" "$work/volume.json"

  joomlaSiteJSON -n --arg path "$work/backing" '{services:{worker:{volumes:[{type:"bind",source:$path,target:"/var/www/html"}]}}}' > "$work/neighbor.json"
  run joomlaPlaygroundCheckOriginalVolume shop.example.test old_web "$work/web" /var/www/html
  assert_failure
  assert_output_contains 'other.example.test'
}

@test "retirement preserves an original volume while a live container binds its backing tree" {
  original_volume_fixture
  echo '{"services":{}}' > "$work/selected.json"
  joomlaSiteJSON -n --arg path "$work/backing/content" '[{Id:"neighbor",Mounts:[{Type:"bind",Source:$path,Destination:"/work"}]}]' > "$work/live.json"
  run joomlaPlaygroundDiscardReplacementStorage "$work" "$token" original shop.example.test
  assert_failure
  refute_file_exists "$work/removed"

  rm "$work/live.json"
  run joomlaPlaygroundDiscardReplacementStorage "$work" "$token" original shop.example.test
  assert_success
  assert_file_exists "$work/removed"
}
