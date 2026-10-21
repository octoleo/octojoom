#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  make_joomla_container alpha ALPHA alpha
  compose="${VDM_REPO_PATH}/joomla/available/alpha.vdm.dev/docker-compose.yml"
  work="$SANDBOX/web-change"
  mkdir -p "$work"
}

@test "root validation accepts nested directories and refuses traversal or syntax" {
  joomlaValidateDocumentRoot .
  joomlaValidateDocumentRoot site/public_html
  for path in /tmp '../site' 'site/../other' 'site//other' 'site/./other' 'site/' 'site;rm' 'site$HOME'; do
    run joomlaValidateDocumentRoot "$path"
    assert_failure
  done
}

@test "Apache to Nginx keeps data and unrelated service configuration" {
  printf '    entrypoint: ["/custom-entrypoint", "literal"]\n' > "$work/command"
  joomlaSetServiceProperty "$compose" "$work/custom.yml" joomlaalpha entrypoint "$work/command"
  printf '    ports:\n      - "127.0.0.1:9123:80"\n' > "$work/ports"
  joomlaSetServiceProperty "$work/custom.yml" "$work/ports.yml" joomlaalpha ports "$work/ports"
  run joomlaRewriteWebserverCompose "$work/ports.yml" "$work/result.yml" joomlaalpha nginxalpha nginx example/joomla:verified-fpm nginx:stable-alpine "$work"
  assert_success
  joomlaServiceBlock "$work/result.yml" joomlaalpha > "$work/php.yml"
  joomlaServiceBlock "$work/result.yml" nginxalpha > "$work/http.yml"
  assert_file_contains "$work/php.yml" 'entrypoint: ["/custom-entrypoint", "literal"]'
  assert_file_contains "$work/php.yml" 'JOOMLA_DB_HOST=mariadbalpha:3306'
  assert_file_contains "$work/php.yml" '/var/www/html'
  refute_file_contains "$work/php.yml" '127.0.0.1:9123:80'
  refute_file_contains "$work/php.yml" 'traefik.http.routers.'
  assert_file_contains "$work/http.yml" '127.0.0.1:9123:80'
  assert_file_contains "$work/http.yml" '/var/www/html:ro'
  assert_file_contains "$work/http.yml" 'traefik.http.routers.joomlaalpha.rule='
  assert_equal "$(joomlaServiceBlock "$compose" mariadbalpha)" "$(joomlaServiceBlock "$work/result.yml" mariadbalpha)"
  assert_equal "$(joomlaServiceBlock "$compose" phpmyadminalpha)" "$(joomlaServiceBlock "$work/result.yml" phpmyadminalpha)"
}

@test "Nginx to Apache returns HTTP routing while retaining application mounts" {
  joomlaRewriteWebserverCompose "$compose" "$work/fpm.yml" joomlaalpha nginxalpha nginx joomla:verified-fpm nginx:stable-alpine "$work"
  joomlaRewriteWebserverCompose "$work/fpm.yml" "$work/apache.yml" joomlaalpha nginxalpha apache joomla:verified-apache nginx:stable-alpine "$work"
  run joomlaServiceBlock "$work/apache.yml" nginxalpha
  assert_failure
  joomlaServiceBlock "$work/apache.yml" joomlaalpha > "$work/php.yml"
  assert_file_contains "$work/php.yml" 'joomla:verified-apache'
  assert_file_contains "$work/php.yml" 'traefik.http.routers.joomlaalpha.rule='
  assert_file_contains "$work/php.yml" '"curl", "-f", "http://localhost/"'
  assert_file_contains "$work/php.yml" '/var/www/html'
}

@test "web switching keeps non-routing labels on the original PHP service" {
  joomlaServiceProperty "$compose" joomlaalpha labels > "$work/labels"
  printf '      - "backup.owner=alpha"\n' >> "$work/labels"
  joomlaSetServiceProperty "$compose" "$work/custom.yml" joomlaalpha labels "$work/labels"
  joomlaRewriteWebserverCompose "$work/custom.yml" "$work/fpm.yml" joomlaalpha nginxalpha nginx joomla:fpm nginx:stable-alpine "$work"
  run joomlaServiceProperty "$work/fpm.yml" joomlaalpha labels
  assert_success
  assert_output_contains 'backup.owner=alpha'
  refute_output_contains 'traefik.http.'
  run joomlaServiceProperty "$work/fpm.yml" nginxalpha labels
  assert_success
  refute_output_contains 'backup.owner=alpha'
}

@test "custom companion service and YAML aliases are refused without changing source" {
  cp "$compose" "$work/before.yml"
  printf '  nginxalpha:\n    image: custom/nginx:local\n' > "$work/service"
  joomlaSetServiceBlock "$compose" "$work/custom.yml" nginxalpha "$work/service"
  run joomlaRewriteWebserverCompose "$work/custom.yml" "$work/result.yml" joomlaalpha nginxalpha nginx joomla:fpm nginx:stable-alpine "$work"
  assert_failure
  assert_output_contains 'already exists'
  cmp "$compose" "$work/before.yml"
  printf '    environment: *shared\n' > "$work/alias"
  joomlaSetServiceProperty "$compose" "$work/alias.yml" joomlaalpha environment "$work/alias"
  run joomlaRewriteWebserverCompose "$work/alias.yml" "$work/result.yml" joomlaalpha nginxalpha nginx joomla:fpm nginx:stable-alpine "$work"
  assert_failure
}

@test "Nginx configuration routes API and refuses missing scripts and secrets" {
  run joomlaNginxConfiguration joomlaalpha /var/www/html/site
  assert_success
  assert_output_contains 'root /var/www/html/site;'
  assert_output_contains 'location /api/ { try_files $uri $uri/ /api/index.php?$query_string; }'
  assert_output_contains 'try_files $fastcgi_script_name =404;'
  assert_output_contains 'fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;'
  assert_output_contains 'configuration\.php'
  assert_output_contains 'fastcgi_pass joomlaalpha:9000;'
}

@test "Apache root is an effective vhost setting" {
  run joomlaApacheConfiguration /var/www/html/site
  assert_success
  assert_output_contains 'DocumentRoot "/var/www/html/site"'
  assert_output_contains '<Directory "/var/www/html/site">'
  assert_output_contains 'AllowOverride All'
}

@test "companion mount preserves unrelated mounts and refuses user config replacement" {
  joomlaWebCompanionMount "$compose" "$work/patched.yml" joomlaalpha apache.conf /etc/apache2/sites-enabled/000-default.conf "$work"
  assert_file_contains "$work/patched.yml" './apache.conf:/etc/apache2/sites-enabled/000-default.conf:ro'
  assert_file_contains "$work/patched.yml" '/alpha/joomla:/var/www/html'
  joomlaServiceProperty "$compose" joomlaalpha volumes > "$work/custom-mount"
  printf '      - "./user.conf:/etc/apache2/sites-enabled/000-default.conf:ro"\n' >> "$work/custom-mount"
  joomlaSetServiceProperty "$compose" "$work/custom.yml" joomlaalpha volumes "$work/custom-mount"
  run joomlaWebCompanionMount "$work/custom.yml" "$work/rejected.yml" joomlaalpha apache.conf /etc/apache2/sites-enabled/000-default.conf "$work"
  assert_failure
  assert_output_contains 'custom mount'
}

@test "new Nginx setup uses same generator with nested working root and no PHP host port" {
  VDM_CONTAINER_TYPE=joomla VDM_KEY=alpha VDM_ENV_KEY=ALPHA VDM_SUBDOMAIN=alpha VDM_DOMAIN=vdm.dev
  VDM_J_REPO=joomla VDM_JV=verified-apache VDM_WEBSERVER=nginx VDM_DOCROOT=site
  VDM_JOOMLA_VOLUMES_MOUNT=$(getYMLine3 '- "${VDM_PROJECT_PATH}/alpha/joomla:/var/www/html"')
  VDM_JOOMLA_SECURE_LABELS='' VDM_PHPMYADMIN_SECURE_LABELS='' VDM_EXTRA_CONTAINER_STUFF='' VDM_EXTRA_JOOMLA_ENV=''
  VDM_DB_VOLUMES_MOUNT=$(getYMLine3 '- "${VDM_PROJECT_PATH}/alpha/db:/var/lib/mysql"')
  VDM_PUID='' VDM_PGID='' VDM_VOLUMES=''
  # shellcheck disable=SC2317 # Selected setup hook invokes this test double.
  joomlaRuntimeSelectImageForFlavor() { printf 'joomla:verified-fpm\n'; }
  joomlaSetupWebPrepare
  joomlaContainer > "$work/generated.yml"
  docker compose --env-file "$VDM_REPO_PATH/joomla/.env" --file "$work/generated.yml" config --quiet
  joomlaServiceBlock "$work/generated.yml" joomlaalpha > "$work/php.yml"
  joomlaServiceBlock "$work/generated.yml" nginxalpha > "$work/http.yml"
  assert_file_contains "$work/php.yml" 'working_dir: "/var/www/html/site"'
  assert_file_contains "$work/php.yml" 'image: joomla:verified-fpm'
  assert_file_contains "$work/http.yml" './nginx.conf:/etc/nginx/conf.d/default.conf:ro'
  assert_file_contains "$work/http.yml" '/var/www/html:ro'
  refute_file_contains "$work/php.yml" 'ports:'
  assert_file_contains "${VDM_REPO_PATH}/joomla/available/alpha.vdm.dev/nginx.conf" 'root /var/www/html/site;'
}

@test "explicit root move includes dotfiles and can be reversed without overwrite" {
  VDM_SITE_COMPOSE="$compose"
  # shellcheck disable=SC2317 # Called indirectly while checking other sites.
  readJoomlaSiteFacts() { return 1; }
  base="${VDM_PROJECT_PATH}/alpha/joomla"
  printf '<?php\n' > "$base/index.php"
  printf '<?php class JConfig {}\n' > "$base/configuration.php"
  printf 'custom\n' > "$base/.htaccess"
  joomlaMoveDocumentRoot "$base" "$base/site" "$base"
  assert_file_exists "$base/site/configuration.php"
  assert_file_exists "$base/site/.htaccess"
  refute_file_exists "$base/index.php"
  joomlaRestoreMovedRoot "$base" "$base/site"
  assert_file_exists "$base/index.php"
  assert_file_exists "$base/.htaccess"
  refute_file_exists "$base/site"
}

@test "web switching maps only the image default command and rejects custom commands" {
  printf '    command: ["apache2-foreground"]\n' > "$work/command"
  joomlaSetServiceProperty "$compose" "$work/command.yml" joomlaalpha command "$work/command"
  joomlaRewriteWebserverCompose "$work/command.yml" "$work/fpm.yml" joomlaalpha nginxalpha nginx joomla:fpm nginx:stable-alpine "$work"
  assert_file_contains "$work/fpm.yml" 'command: ["php-fpm"]'
  printf '    command: ["custom-daemon", "--settings"]\n' > "$work/command"
  joomlaSetServiceProperty "$compose" "$work/command.yml" joomlaalpha command "$work/command"
  run joomlaRewriteWebserverCompose "$work/command.yml" "$work/fpm.yml" joomlaalpha nginxalpha nginx joomla:fpm nginx:stable-alpine "$work"
  assert_failure
  assert_output_contains 'custom command'
}

@test "explicit root move realigns only log and temporary paths below old root" {
  cat > "$work/configuration.php" <<'PHP'
<?php
class JConfig {
  public $log_path = '/var/www/html/administrator/logs';
  public $tmp_path = '/external/private/tmp';
  public $password = 'unchanged-secret';
}
PHP
  joomlaPatchMovedRootConfiguration "$work/configuration.php" "$work/changed.php" /var/www/html /var/www/html/site
  assert_file_contains "$work/changed.php" "public \$log_path = '/var/www/html/site/administrator/logs';"
  assert_file_contains "$work/changed.php" "public \$tmp_path = '/external/private/tmp';"
  assert_file_contains "$work/changed.php" "public \$password = 'unchanged-secret';"
}

@test "canceling a setup web question exits before choosing a tag or writing files" {
  VDM_J_REPO=joomla VDM_JV=current
  joomlaRuntimeProbeImage() { printf '{"flavor":"apache","php":"8.3.1"}\n'; }
  getInputYesNo() { return 255; }
  # shellcheck disable=SC2317 # Cancellation must avoid this indirect setup helper.
  joomlaRuntimeSelectImageForFlavor() { echo 'unexpected flavor selection' >&2; return 1; }
  run joomlaSetupWebChoices
  assert_status 255
  refute_output_contains 'unexpected flavor selection'
  refute_file_exists "${VDM_REPO_PATH}/joomla/available/alpha.vdm.dev/nginx.conf"
}

@test "explicit root move refuses symlink ancestors before creating outside directories" {
  skip_on_windows 'symlink creation requires privileges on Windows'
  VDM_SITE_COMPOSE="$compose"
  # shellcheck disable=SC2317 # Called indirectly while checking other sites.
  readJoomlaSiteFacts() { return 1; }
  base="${VDM_PROJECT_PATH}/alpha/joomla"
  mkdir -p "$base/source" "$work/outside"
  printf '<?php\n' > "$base/source/index.php"
  printf '<?php class JConfig {}\n' > "$base/source/configuration.php"
  ln -s "$work/outside" "$base/link"
  run joomlaMoveDocumentRoot "$base/source" "$base/link/new/deeper" "$base"
  assert_failure
  assert_output_contains 'symlinked paths'
  refute_file_exists "$work/outside/new"
  assert_file_exists "$base/source/index.php"
  assert_file_exists "$base/source/configuration.php"
}

@test "Apache root changes preserve custom directives and unrelated directory sections" {
  joomlaApacheConfiguration /var/www/html > "$work/apache.conf"
  cat >> "$work/apache.conf" <<'APACHE'
# Locally maintained hardening.
Header always set X-Content-Type-Options nosniff
<Directory "/private/assets">
    Require all denied
</Directory>
APACHE
  cp "$work/apache.conf" "$work/original.conf"
  joomlaStageApacheConfiguration "$work/apache.conf" "$work/changed.conf" /var/www/html/site
  assert_file_contains "$work/changed.conf" 'DocumentRoot "/var/www/html/site"'
  assert_file_contains "$work/changed.conf" '<Directory "/var/www/html/site">'
  assert_file_contains "$work/changed.conf" 'Header always set X-Content-Type-Options nosniff'
  assert_file_contains "$work/changed.conf" '<Directory "/private/assets">'
  joomlaStageApacheConfiguration "$work/changed.conf" "$work/restored.conf" /var/www/html
  cmp "$work/original.conf" "$work/restored.conf"
}

@test "Apache root changes refuse ambiguous vhosts and unrecognized companions" {
  joomlaApacheConfiguration /var/www/html > "$work/apache.conf"
  printf 'DocumentRoot "/another/site"\n' >> "$work/apache.conf"
  run joomlaStageApacheConfiguration "$work/apache.conf" "$work/changed.conf" /var/www/html/site
  assert_failure
  assert_output_contains 'ambiguous'
  printf 'DocumentRoot "/custom/site"\n' > "$work/custom.conf"
  run joomlaStageApacheConfiguration "$work/custom.conf" "$work/changed.conf" /var/www/html/site
  assert_failure
  assert_output_contains 'edited explicitly'
}

@test "root moves refuse nested and parent bind mounts used by another site" {
  VDM_SITE_COMPOSE="$compose"
  base="${VDM_PROJECT_PATH}/alpha/joomla"
  mkdir -p "$base/source/images" "$VDM_REPO_PATH/joomla/available/other.vdm.dev"
  printf '<?php\n' > "$base/source/index.php"
  printf '<?php class JConfig {}\n' > "$base/source/configuration.php"
  printf 'other site upload\n' > "$base/source/images/other-site.txt"
  touch "$VDM_REPO_PATH/joomla/available/other.vdm.dev/docker-compose.yml"
  # shellcheck disable=SC2317 # Called indirectly while checking other sites.
  readJoomlaSiteFacts() { VDM_SITE_MOUNT_TYPE=bind; VDM_SITE_MOUNT_SOURCE="$shared_root"; }
  for shared_root in "$base/source/images" "${VDM_PROJECT_PATH}/alpha"; do
    run joomlaMoveDocumentRoot "$base/source" "$base/new/target" "$base"
    assert_failure
    assert_output_contains 'shares or overlaps'
    refute_file_exists "$base/new"
    assert_file_contains "$base/source/images/other-site.txt" 'other site upload'
    assert_file_exists "$base/source/index.php"
    assert_file_exists "$base/source/configuration.php"
  done
}

@test "root moves recognize shared bind storage through another site host alias" {
  skip_on_windows 'symlink creation requires privileges on Windows'
  VDM_SITE_COMPOSE="$compose"
  base="${VDM_PROJECT_PATH}/alpha/joomla"
  mkdir -p "$base/source" "$VDM_REPO_PATH/joomla/available/other.vdm.dev"
  printf '<?php\n' > "$base/source/index.php"
  printf '<?php class JConfig {}\n' > "$base/source/configuration.php"
  ln -s "$base" "$work/host-alias"
  touch "$VDM_REPO_PATH/joomla/available/other.vdm.dev/docker-compose.yml"
  # shellcheck disable=SC2317 # Called indirectly while checking other sites.
  readJoomlaSiteFacts() { VDM_SITE_MOUNT_TYPE=bind; VDM_SITE_MOUNT_SOURCE="$work/host-alias/source"; }
  run joomlaMoveDocumentRoot "$base/source" "$base/new/target" "$base"
  assert_failure
  assert_output_contains 'shares or overlaps'
  refute_file_exists "$base/new"
  assert_file_exists "$base/source/index.php"
  assert_file_exists "$base/source/configuration.php"
}

@test "stopped web syntax validation uses staged companions and read-only real mounts" {
  command -v jq >/dev/null 2>&1 || skip 'jq required for semantic Compose fixtures'
  VDM_SITE_SERVICE=joomlaalpha
  mkdir -p "$work/website with spaces" "$work/site"
  printf 'server { listen 80; }\n' > "$work/staged-nginx.conf"
  OCTOJOOM_SITE_FILE_TARGETS=("$work/site/nginx.conf")
  OCTOJOOM_SITE_FILE_SOURCES=("$work/staged-nginx.conf")
  # Real Compose reports native Windows paths; the staged companion arrays
  # intentionally retain their Git Bash spelling to exercise normalization.
  model_root="$work/website with spaces" model_conf="$work/site/nginx.conf" expected_staged="$work/staged-nginx.conf"
  if is_windows; then
    model_root=$(cygpath -am -- "$model_root")
    model_conf=$(cygpath -am -- "$model_conf")
    expected_staged=$(cygpath -am -- "$expected_staged")
  fi
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' jq -n --arg root "$model_root" --arg conf "$model_conf" \
    '{services:{nginxalpha:{image:"nginx:stable-alpine",environment:{CUSTOM_VALUE:"kept literal"},volumes:[{type:"bind",source:$root,target:"/var/www/html"},{type:"bind",source:$conf,target:"/etc/nginx/conf.d/default.conf"}]}}}' > "$work/model.json"
  # shellcheck disable=SC2317 # Semantic model supplied to the isolated validator.
  migrationRunCompose() { cat "$work/model.json"; }
  run joomlaValidateStagedWebConfiguration "$compose" "$work/.env" "$work/site" nginxalpha nginx
  assert_success
  assert_file_contains "$STUB_DIR/commands.log" 'docker run --rm --network none --read-only'
  assert_file_contains "$STUB_DIR/commands.log" "source=$expected_staged,target=/etc/nginx/conf.d/default.conf,readonly"
  assert_file_contains "$STUB_DIR/commands.log" "source=$model_root,target=/var/www/html,readonly"
  assert_file_contains "$STUB_DIR/commands.log" '--env CUSTOM_VALUE=kept literal'
  refute_file_contains "$STUB_DIR/commands.log" ' compose up '
  fail_command docker-run 1
  run joomlaValidateStagedWebConfiguration "$compose" "$work/.env" "$work/site" nginxalpha nginx
  assert_failure
  assert_output_contains 'failed native syntax validation'
}

@test "stopped web syntax validation refuses missing mounted configuration" {
  command -v jq >/dev/null 2>&1 || skip 'jq required for semantic Compose fixtures'
  VDM_SITE_SERVICE=joomlaalpha
  OCTOJOOM_SITE_FILE_TARGETS=() OCTOJOOM_SITE_FILE_SOURCES=()
  jq -n --arg conf "$work/missing.conf" \
    '{services:{nginxalpha:{image:"nginx:stable-alpine",volumes:[{type:"bind",source:$conf,target:"/etc/nginx/conf.d/default.conf"}]}}}' > "$work/model.json"
  # shellcheck disable=SC2317 # Semantic model supplied to the isolated validator.
  migrationRunCompose() { cat "$work/model.json"; }
  run joomlaValidateStagedWebConfiguration "$compose" "$work/.env" "$work" nginxalpha nginx
  assert_failure
  assert_output_contains 'required webserver mount does not exist'
  refute_file_contains "$STUB_DIR/commands.log" 'docker run '
}

@test "new FPM custom ownership is checked before setup companion writes" {
  VDM_CONTAINER_TYPE=joomla VDM_KEY=alpha VDM_ENV_KEY=ALPHA VDM_SUBDOMAIN=alpha VDM_DOMAIN=vdm.dev
  VDM_J_REPO=joomla VDM_JV=verified-fpm VDM_WEBSERVER=nginx VDM_DOCROOT=.
  VDM_PUID=1001 VDM_PGID=1001
  # shellcheck disable=SC2317 # New setup resolves the image before ownership.
  joomlaRuntimeSelectImageForFlavor() { printf 'joomla:verified-fpm\n'; }
  # shellcheck disable=SC2317 # Image probe observes its actual initialization IDs.
  docker() { printf '33:33\n'; }
  run joomlaSetupWebPrepare
  assert_status 2
  assert_output_contains 'requested 1001:1001 would not own the initialized files'
  refute_file_exists "${VDM_REPO_PATH}/joomla/available/alpha.vdm.dev/nginx.conf"
  refute_file_exists "${VDM_REPO_PATH}/joomla/available/alpha.vdm.dev/php-fpm-user.conf"
  run joomlaValidateNewFpmOwnership joomla:verified-fpm 33 33
  assert_success
}

@test "Windows web companion paths normalize native and Git Bash aliases only" {
  OS_NUMBER=3
  # shellcheck disable=SC2317 # Simulate the native-path converter on every OS.
  cygpath() {
    [ "$1" = -am ] && [ "$2" = -- ] || return 1
    case "$3" in
      /c/*) printf 'C:/%s\n' "${3#/c/}" ;;
      *) printf '%s\n' "$3" ;;
    esac
  }
  assert_equal "$(joomlaWebHostPath '/c/site with spaces/nginx.conf')" "$(joomlaWebHostPath 'C:/site with spaces/nginx.conf')"
  assert_equal "$(joomlaWebHostPath '/c/another/nginx.conf')" 'C:/another/nginx.conf'
  OS_NUMBER=1
  assert_equal "$(joomlaWebHostPath '/c/site with spaces/nginx.conf')" '/c/site with spaces/nginx.conf'
}
