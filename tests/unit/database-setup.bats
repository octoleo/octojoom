#!/usr/bin/env bats
# The runtime image probes are isolated from setup/generator behavior here;
# Docker acceptance installs each advertised engine with real published images.
# shellcheck disable=SC2030,SC2031,SC2034,SC2317,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  VDM_CONTAINER_TYPE=joomla
}

database_headless() {
  OCTOJOOM_NON_INTERACTIVE=true
  VDM_KEY=alpha VDM_DOMAIN=example.test
  getInput() { printf 'Unexpected input: %s\n' "$1" >&2; return 17; }
  getPassword() { printf 'Unexpected password: %s\n' "$1" >&2; return 17; }
  getInputYesNo() { [ "$2" = 'Environment Variable File' ] || return 17; }
  showNotice() { :; }
}

database_capabilities() {
  joomlaDatabaseImageFacts() {
    VDM_DATABASE_IMAGE_VERSION=20.1
    VDM_DATABASE_VOLUME_TARGET=/var/lib/mysql
    [ "$2" != postgres ] || VDM_DATABASE_VOLUME_TARGET="${TEST_POSTGRES_TARGET:-/var/lib/postgresql}"
  }
  joomlaDatabaseJoomlaCapability() {
    VDM_DATABASE_JOOMLA_DRIVER=mysqli VDM_DATABASE_INIT_SIMPLE_PG=false
    if [ "$2" = postgres ]; then VDM_DATABASE_JOOMLA_DRIVER=pgsql VDM_DATABASE_INIT_SIMPLE_PG=true; fi
    printf '%s\n' "$VDM_DATABASE_JOOMLA_DRIVER"
  }
}

@test "database setup: default MariaDB retains original credentials, storage and no image probing" {
  database_headless
  joomlaDatabaseImageFacts() { return 90; }
  joomlaDatabaseJoomlaCapability() { return 91; }
  run joomla__TRuST__setup
  assert_success
  local file="$VDM_REPO_PATH/joomla/available/alpha.example.test/docker-compose.yml"
  assert_file_contains "$file" 'MARIADB_ROOT_PASSWORD=${VDM_ALPHA_DB_ROOT}'
  assert_file_contains "$file" '/alpha/db:/var/lib/mysql'
  assert_file_contains "$file" 'JOOMLA_DB_HOST=mariadbalpha:3306'
  assert_file_contains "$VDM_REPO_PATH/joomla/.env" 'VDM_ALPHA_DB_IMAGE="mariadb:latest"'
  assert_file_contains "$VDM_REPO_PATH/joomla/.env" 'VDM_ALPHA_DB_ENGINE="mariadb"'
}

@test "database setup: MySQL image and literal credentials use its native initialization environment" {
  database_capabilities
  database_headless
  parseCLI --db-engine mysql --db-image mysql:selected --non-interactive
  vdm_database_pass='$(touch NEVER) $dollar "quoted" '\''single'
  run joomla__TRuST__setup
  assert_success
  local file="$VDM_REPO_PATH/joomla/available/alpha.example.test/docker-compose.yml" value
  assert_file_contains "$file" 'MYSQL_DATABASE=${VDM_ALPHA_DB}'
  assert_file_contains "$file" 'MYSQL_ROOT_PASSWORD=${VDM_ALPHA_DB_ROOT}'
  assert_file_contains "$file" 'mysql --protocol=tcp'
  migrationReadEnvValue "$VDM_REPO_PATH/joomla/.env" VDM_ALPHA_DB_PASS value
  assert_equal "$value" "$vdm_database_pass"
  migrationReadEnvValue "$VDM_REPO_PATH/joomla/.env" VDM_ALPHA_DB_IMAGE value
  assert_equal "$value" mysql:selected
  refute_file_exists NEVER
}

@test "database setup: PostgreSQL manual install has its driver, measured mount and no root or MySQL viewer" {
  database_capabilities
  database_headless
  parseCLI --db-engine postgres --db-image postgres:selected --non-interactive
  run joomla__TRuST__setup
  assert_success
  local file="$VDM_REPO_PATH/joomla/available/alpha.example.test/docker-compose.yml"
  assert_file_contains "$file" 'POSTGRES_DB=${VDM_ALPHA_DB}'
  assert_file_contains "$file" 'POSTGRES_PASSWORD=${VDM_ALPHA_DB_PASS}'
  assert_file_contains "$file" 'JOOMLA_DB_HOST=mariadbalpha:5432'
  assert_file_contains "$file" 'JOOMLA_DB_TYPE=pgsql'
  assert_file_contains "$file" '/alpha/db:/var/lib/postgresql'
  run grep -E 'DB_ROOT|phpmyadmin|MARIADB_' "$file"
  assert_status 1
  run grep DB_ROOT "$VDM_REPO_PATH/joomla/.env"
  assert_status 1
}

@test "database setup: PostgreSQL bulk auto install uses named storage and each site's credentials" {
  database_capabilities
  database_headless
  TEST_POSTGRES_TARGET=/var/lib/postgresql/data
  parseCLI --db-engine postgres --db-image postgres:older-family --persistence false --db-persistence false --non-interactive
  VDM_TASK=bulk VDM_SUBDOMAIN=website VDM_NUMBER_CONTAINERS=2 VDM_AUTO_INSTALL=true
  VDM_J_EMAIL=admin@example.test VDM_J_PASSWORD=administrator-long-password
  run joomla__TRuST__bulk
  assert_success
  local file="$VDM_REPO_PATH/joomla/available/website2.example.test/docker-compose.yml"
  assert_file_contains "$file" '_db:/var/lib/postgresql/data'
  assert_file_contains "$file" 'JOOMLA_DB_TYPE=pgsql'
  assert_file_contains "$file" 'JOOMLA_ADMIN_PASSWORD='
  assert_file_contains "$VDM_REPO_PATH/joomla/.env" '_DB="vdm_io2"'
  run grep DB_ROOT "$VDM_REPO_PATH/joomla/.env"
  assert_status 1
}

@test "database setup: unsupported runtime fails before new deployment files" {
  database_capabilities
  database_headless
  joomlaDatabaseJoomlaCapability() { return 17; }
  VDM_DB_ENGINE=postgres VDM_DB_IMAGE=postgres:selected
  run joomla__TRuST__setup
  assert_status 17
  refute_file_exists "$VDM_REPO_PATH/joomla/.env"
  refute_file_exists "$VDM_REPO_PATH/joomla/available"
}

@test "database setup: known PostgreSQL initializer limitations reject literal credentials without rewriting" {
  database_capabilities
  database_headless
  VDM_DB_ENGINE=postgres VDM_DB_IMAGE=postgres:selected
  vdm_database_pass="literal password'\\"
  run joomlaSetupPreflight
  assert_status 17
  assert_equal "$vdm_database_pass" "literal password'\\"
  refute_file_exists "$VDM_REPO_PATH/joomla/.env"
}

@test "database setup: a saved future engine does not change when another site chooses its own image" {
  database_capabilities
  database_headless
  VDM_DEFAULT_JOOMLA_DB_ENGINE=mysql VDM_DEFAULT_JOOMLA_DB_IMAGE=mysql:saved
  joomla__TRuST__setup
  assert_file_contains "$VDM_REPO_PATH/joomla/.env" 'VDM_ALPHA_DB_IMAGE="mysql:saved"'
  VDM_KEY=bravo VDM_DB_ENGINE=postgres VDM_DB_IMAGE=postgres:chosen
  joomla__TRuST__setup
  assert_equal "$VDM_DEFAULT_JOOMLA_DB_IMAGE" mysql:saved
  assert_file_contains "$VDM_REPO_PATH/joomla/.env" 'VDM_BRAVO_DB_IMAGE="postgres:chosen"'
  assert_file_contains "$VDM_REPO_PATH/joomla/.env" 'VDM_ALPHA_DB_IMAGE="mysql:saved"'
}

@test "database setup: optional menu offers compatible engines and persists its published choice" {
  database_capabilities
  VDM_DB_ENGINE=mariadb VDM_DB_IMAGE=mariadb:latest VDM_J_REPO=joomla VDM_JV=latest
  answers postgres postgres:selected
  joomlaSetupDatabaseChoices
  assert_answers_used
  assert_equal "$VDM_DB_ENGINE" postgres
  assert_equal "$VDM_DB_IMAGE" postgres:selected
  assert_equal "$VDM_PHPMYADMIN" false
  VDM_ENV_KEY=ALPHA
  mkdir -p "$VDM_REPO_PATH/joomla"
  OCTOJOOM_SETUP_COLLECT_ENV=true OCTOJOOM_SETUP_ENV_APPROVED=true OCTOJOOM_SETUP_ASSIGNMENTS=()
  joomlaSaveSetupChoices
  printf '%s\n' "${OCTOJOOM_SETUP_ASSIGNMENTS[@]}" > "$SANDBOX/choices"
  assert_file_contains "$SANDBOX/choices" 'VDM_ALPHA_DB_ENGINE="postgres"'
  joomlaSaveSetupDefaults
  assert_file_contains "$VDM_SRC_PATH/.env" 'VDM_DEFAULT_JOOMLA_DB_IMAGE="postgres:selected"'
}

@test "database image inspection: actual PGDATA distinguishes old and new published storage conventions" {
  docker() { printf '%s\n' 'postgres (PostgreSQL) 18.2' /var/lib/postgresql/18/docker; }
  joomlaDatabaseImageFacts postgres:alias postgres
  assert_equal "$VDM_DATABASE_VOLUME_TARGET" /var/lib/postgresql
  assert_equal "$VDM_DATABASE_IMAGE_VERSION" 18.2
  docker() { printf '%s\n' 'postgres (PostgreSQL) 17.6' /var/lib/postgresql/data; }
  joomlaDatabaseImageFacts postgres:other postgres
  assert_equal "$VDM_DATABASE_VOLUME_TARGET" /var/lib/postgresql/data
}

@test "database identity: PostgreSQL setup keeps clone identity, scoped choices and storage independent" {
  database_capabilities
  database_headless
  VDM_DB_ENGINE=postgres VDM_DB_IMAGE=postgres:selected
  joomla__TRuST__setup
  local file="$VDM_REPO_PATH/joomla/available/alpha.example.test/docker-compose.yml"
  getJoomlaComposeIdentity "$file"
  assert_equal "$VDM_SRC_KEY" alpha
  assert_equal "$VDM_SRC_ENV_KEY" ALPHA
  assert_equal "$VDM_SRC_PROJECT_FOLDER" alpha
  rewriteJoomlaComposeIdentity "$file" "$SANDBOX/clone.yml" alpha bravo ALPHA BRAVO alpha bravo example.test example.test
  assert_file_contains "$SANDBOX/clone.yml" 'JOOMLA_DB_HOST=mariadbbravo:5432'
  assert_file_contains "$SANDBOX/clone.yml" '/bravo/db:/var/lib/postgresql'
  cloneContainerEnvFile "$VDM_REPO_PATH/joomla/.env" "$SANDBOX/clone.env" ALPHA BRAVO
  assert_file_contains "$SANDBOX/clone.env" 'VDM_BRAVO_DB_ENGINE="postgres"'
  migrationComposeLocalFiles "$SANDBOX/clone.yml" bravo
  printf '%s\n' '<?php' 'class JConfig {' "public \$host = 'mariadbalpha:5432';" "public \$dbtype = 'pgsql';" '}' > "$SANDBOX/configuration.php"
  cloneJoomlaConfiguration "$SANDBOX/configuration.php" alpha bravo
  assert_file_contains "$SANDBOX/configuration.php" "mariadbbravo:5432"
  assert_file_contains "$SANDBOX/configuration.php" "'pgsql'"
}

@test "database archives: scoped dormant choices survive all engine list and map environments" {
  local engine field style
  for engine in mariadb mysql postgres; do
    case "$engine" in mariadb) field=MARIADB_DATABASE ;; mysql) field=MYSQL_DATABASE ;; postgres) field=POSTGRES_DB ;; esac
    for style in list map; do
      printf 'services:\n  mariadbalpha:\n    container_name: mariadbalpha\n    environment:\n' > "$SANDBOX/scoped.yml"
      if [ "$style" = list ]; then
        printf '      - "%s=${VDM_ALPHA_DB}"\n' "$field" >> "$SANDBOX/scoped.yml"
      else
        printf '      %s: "${VDM_ALPHA_DB}"\n' "$field" >> "$SANDBOX/scoped.yml"
      fi
      printf '%s\n' 'VDM_ALPHA_DB="site"' "VDM_ALPHA_DB_ENGINE=\"$engine\"" "VDM_ALPHA_DB_IMAGE=\"$engine:selected\"" \
        'VDM_ALPHA_HOOKS_ENABLED="false"' 'VDM_ALPHA_BACKUP_TIMESTAMP_PATTERN="%Y%m%d"' > "$SANDBOX/scoped.env"
      getJoomlaComposeIdentity "$SANDBOX/scoped.yml"
      assert_equal "$VDM_SRC_ENV_KEY" ALPHA
      migrationValidateScopedEnv "$SANDBOX/scoped.yml" "$SANDBOX/scoped.env"
      printf '%s\n' 'VDM_UNRELATED_DB_PASSWORD="private"' >> "$SANDBOX/scoped.env"
      run migrationValidateScopedEnv "$SANDBOX/scoped.yml" "$SANDBOX/scoped.env"
      assert_failure
    done
  done
  printf '%s\n' '      POSTGRES_DB: "${VDM_BRAVO_DB}"' >> "$SANDBOX/scoped.yml"
  run getJoomlaComposeEnvKey "$SANDBOX/scoped.yml"
  assert_failure
}

@test "database identity: clone renames Nginx companion services and routing with PostgreSQL" {
  cat > "$SANDBOX/nginx.yml" <<'YAML'
services:
  mariadbalpha:
    container_name: mariadbalpha
    environment:
      POSTGRES_DB: "${VDM_ALPHA_DB}"
    volumes:
      - ${VDM_PROJECT_PATH}/alpha/db:/var/lib/postgresql
  joomlaalpha:
    environment:
      JOOMLA_DB_HOST: mariadbalpha:5432
  nginxalpha:
    container_name: nginxalpha
    depends_on:
      - joomlaalpha
    labels:
      - "traefik.http.routers.nginxalpha.rule=Host(`alpha.example.test`)"
      - "traefik.http.services.nginxalpha.loadbalancer.server.port=80"
YAML
  rewriteJoomlaComposeIdentity "$SANDBOX/nginx.yml" "$SANDBOX/nginx-clone.yml" alpha bravo ALPHA BRAVO alpha bravo example.test example.test
  assert_file_contains "$SANDBOX/nginx-clone.yml" 'container_name: nginxbravo'
  assert_file_contains "$SANDBOX/nginx-clone.yml" 'traefik.http.routers.nginxbravo.rule=Host(`bravo.example.test`)'
  assert_file_contains "$SANDBOX/nginx-clone.yml" 'traefik.http.services.nginxbravo.loadbalancer.server.port=80'
  assert_file_contains "$SANDBOX/nginx-clone.yml" 'POSTGRES_DB: "${VDM_BRAVO_DB}"'
  refute_file_contains "$SANDBOX/nginx-clone.yml" nginxalpha
}
