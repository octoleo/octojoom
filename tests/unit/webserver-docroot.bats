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
