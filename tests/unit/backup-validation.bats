#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  PACKAGE="$SANDBOX/package with spaces"
  mkdir -p "$PACKAGE/compose" "$PACKAGE/project/joomla/images" "$PACKAGE/project/extra"
  printf 'manifest\n' > "$PACKAGE/manifest.env"
  printf 'private\n' > "$PACKAGE/compose/.env"
  printf 'application\n' > "$PACKAGE/project/joomla/index.php"
  printf 'binary\0payload\377\n' > "$PACKAGE/project/joomla/images/upload one.bin"
}

@test "backup checksums verify literal paths and binary bytes and reject changed or extra payload" {
  joomlaBackupFileMetadata "$PACKAGE"
  joomlaBackupChecksums "$PACKAGE"
  run joomlaBackupVerifyChecksums "$PACKAGE"
  assert_success
  cp "$PACKAGE/project/joomla/index.php" "$SANDBOX/original"
  printf 'changed\n' > "$PACKAGE/project/joomla/index.php"
  run joomlaBackupVerifyChecksums "$PACKAGE"
  assert_failure
  cp "$SANDBOX/original" "$PACKAGE/project/joomla/index.php"
  touch "$PACKAGE/project/unrecorded"
  run joomlaBackupVerifyChecksums "$PACKAGE"
  assert_failure
}

@test "backup checksum and metadata inventories propagate filesystem traversal failure" {
  printf 'previous checksums\n' > "$PACKAGE/project/checksums"
  printf 'previous metadata\n' > "$PACKAGE/project/files.meta"
  runPrivileged() { if [ "$1" = find ]; then command find "${@:2}"; return 31; else "$@"; fi; }
  run joomlaBackupChecksums "$PACKAGE"
  assert_failure
  assert_equal "$(cat "$PACKAGE/project/checksums")" 'previous checksums'
  run joomlaBackupFileMetadata "$PACKAGE"
  assert_failure
  assert_equal "$(cat "$PACKAGE/project/files.meta")" 'previous metadata'
}

@test "backup checksum generation preserves the previous index when hashing fails" {
  printf 'previous checksums\n' > "$PACKAGE/project/checksums"
  runPrivileged() { case "$1" in sha256sum|shasum) return 32;; *) "$@";; esac; }
  run joomlaBackupChecksums "$PACKAGE"
  assert_failure
  assert_equal "$(cat "$PACKAGE/project/checksums")" 'previous checksums'
}

@test "backup metadata restores file modes and rejects incomplete ownership records before changes" {
  skip_on_windows 'Unix mode restoration requires Unix file permissions'
  chmod 640 "$PACKAGE/project/joomla/images/upload one.bin"
  joomlaBackupFileMetadata "$PACKAGE"
  chmod 600 "$PACKAGE/project/joomla/images/upload one.bin"
  joomlaBackupApplyMetadata "$PACKAGE"
  assert_equal "$(file_mode "$PACKAGE/project/joomla/images/upload one.bin")" 640
  sed '/images\/upload one.bin$/d' "$PACKAGE/project/files.meta" > "$SANDBOX/incomplete"
  cp "$SANDBOX/incomplete" "$PACKAGE/project/files.meta"
  : > "$STUB_DIR/commands.log"
  run joomlaBackupApplyMetadata "$PACKAGE"
  assert_failure
  refute_command '^sudo chown '
  refute_command '^sudo chmod '
}

@test "backup metadata refuses external paths and privileged mode bits before ownership changes" {
  local mode uid gid
  uid=$(id -u); gid=$(id -g)
  for mode in 4755 2755 7777; do
    printf '%s\t%s\t%s\tproject/joomla/index.php\n' "$mode" "$uid" "$gid" > "$PACKAGE/project/files.meta"
    run joomlaBackupApplyMetadata "$PACKAGE"
    assert_failure
  done
  printf '644\t%s\t%s\tproject/../../outside\n' "$uid" "$gid" > "$PACKAGE/project/files.meta"
  run joomlaBackupApplyMetadata "$PACKAGE"
  assert_failure
  refute_command '^sudo chown '
}

@test "backup verification rejects duplicate and missing digest records" {
  joomlaBackupFileMetadata "$PACKAGE"
  joomlaBackupChecksums "$PACKAGE"
  cp "$PACKAGE/project/checksums" "$SANDBOX/checksums"
  head -n 1 "$SANDBOX/checksums" >> "$PACKAGE/project/checksums"
  run joomlaBackupVerifyChecksums "$PACKAGE"
  assert_failure
  tail -n +2 "$SANDBOX/checksums" > "$PACKAGE/project/checksums"
  run joomlaBackupVerifyChecksums "$PACKAGE"
  assert_failure
}

@test "backup metadata refuses path aliases that would apply multiple owners or modes" {
  joomlaBackupFileMetadata "$PACKAGE"
  local mode uid gid
  mode=$(file_mode "$PACKAGE/project/joomla"); uid=$(id -u); gid=$(id -g)
  printf '%s\t%s\t%s\tproject/joomla/\n' "$mode" "$uid" "$gid" >> "$PACKAGE/project/files.meta"
  : > "$STUB_DIR/commands.log"
  run joomlaBackupApplyMetadata "$PACKAGE"
  assert_failure
  refute_command '^sudo chown '
}

@test "backup extraction ignores inherited tar transforms and refuses linked staging ancestors" {
  command tar --version 2>/dev/null | grep -q 'GNU tar' || skip 'TAR_OPTIONS belongs to GNU tar'
  mkdir "$SANDBOX/stage" "$SANDBOX/outside"
  TAR_OPTIONS='' command tar -czf "$SANDBOX/input.tar.gz" -C "$PACKAGE" manifest.env compose project
  export TAR_OPTIONS="--absolute-names --transform=s|^|$SANDBOX/outside/|"
  # This deliberately minimal manifest fails later validation. Extraction itself
  # must still stay within the private staging directory.
  run joomlaBackupExtract "$SANDBOX/input.tar.gz" "$SANDBOX/stage"
  assert_failure
  assert_file_exists "$SANDBOX/stage/manifest.env"
  refute_file_exists "$SANDBOX/outside/manifest.env"
  unset TAR_OPTIONS
  skip_on_windows 'Native symlinks unavailable'
  mkdir "$SANDBOX/real-parent" "$SANDBOX/real-parent/stage"
  ln -s "$SANDBOX/real-parent" "$SANDBOX/linked-parent"
  run joomlaBackupExtract "$SANDBOX/input.tar.gz" "$SANDBOX/linked-parent/stage"
  assert_failure
  refute_file_exists "$SANDBOX/real-parent/stage/manifest.env"
}
