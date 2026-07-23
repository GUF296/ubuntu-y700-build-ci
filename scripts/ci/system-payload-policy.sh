#!/usr/bin/env bash

# This file is sourced by CI build scripts after common.sh.

# This virtual capability is deliberately versioned. A future daily overlay
# with the old unversioned Provides declaration must not satisfy the camera
# package's migration boundary.
readonly TB321FU_CAMERA_PAYLOAD_MIGRATION_ABI=1

ci_payload_file_mode() {
  local relative=${1#/}

  case "/$relative" in
    /DEBIAN/preinst|/DEBIAN/postinst|/DEBIAN/prerm|/DEBIAN/postrm|/DEBIAN/config|\
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/libexec/*|\
    /usr/local/bin/*|/usr/local/sbin/*|/usr/local/libexec/*|\
    /usr/lib/systemd/system-sleep/*|\
    /opt/libcamera-y700/bin/*|/opt/libcamera-y700/libexec/*)
      printf '0755\n'
      ;;
    *)
      printf '0644\n'
      ;;
  esac
}

ci_normalize_system_payload_modes() {
  local root=$1 path relative expected

  [ -d "$root" ] || ci_die "system payload tree not found: $root"
  find "$root" -xdev -type d -exec chmod 0755 {} +
  while IFS= read -r -d '' path; do
    relative=${path#"$root"/}
    expected=$(ci_payload_file_mode "$relative")
    chmod "$expected" "$path"
  done < <(find "$root" -xdev -type f -print0)
}

ci_assert_normalized_system_payload_modes() {
  local root=$1 path relative expected actual

  [ -d "$root" ] || ci_die "system payload tree not found: $root"
  while IFS= read -r -d '' path; do
    actual=$(stat -c '%a' "$path")
    [ "$actual" = 755 ] || ci_die "system payload directory has mode $actual, expected 755: $path"
  done < <(find "$root" -xdev -type d -print0)
  while IFS= read -r -d '' path; do
    relative=${path#"$root"/}
    expected=$(ci_payload_file_mode "$relative")
    actual=$(stat -c '%a' "$path")
    [ "$actual" = "${expected#0}" ] || \
      ci_die "system payload file has mode $actual, expected ${expected#0}: $path"
  done < <(find "$root" -xdev -type f -print0)
}

ci_assert_privileged_payload_security() {
  local root=$1 required path writable
  shift

  [ -d "$root" ] || ci_die "rootfs tree not found: $root"
  for path in "$root/etc" "$root/usr" "$root/opt" "$root/bin" "$root/sbin" "$root/lib"; do
    [ -e "$path" ] || continue
    writable=$(find "$path" -xdev \( -type f -o -type d \) -perm /0022 -print -quit)
    [ -z "$writable" ] || ci_die "group/world-writable privileged payload member: $writable"
  done

  for required in "$@"; do
    required=${required#/}
    [ -f "$root/$required" ] || ci_die "required payload executable is missing: /$required"
    [ -x "$root/$required" ] || ci_die "required payload file is not executable: /$required"
  done
}

ci_deb_has_member() {
  local deb=$1 relative=${2#/}

  dpkg-deb --fsys-tarfile "$deb" |
    tar -tf - |
    sed 's#^\./##' |
    grep -Fx "$relative" >/dev/null
}

ci_deb_member_owners() {
  local payload_dir=$1 relative=${2#/} deb package

  while IFS= read -r -d '' deb; do
    if ci_deb_has_member "$deb" "$relative"; then
      package=$(dpkg-deb -f "$deb" Package)
      printf '%s\t%s\n' "$package" "$deb"
    fi
  done < <(find "$payload_dir" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
}

ci_copy_deb_unique() {
  local source=$1 destination_dir=$2 label=${3:-DEB input}
  local basename destination

  [ -f "$source" ] && [ ! -L "$source" ] ||
    ci_die "$label is not a regular file: $source"
  basename=$(basename -- "$source")
  case "$basename" in
    *.deb) ;;
    *) ci_die "$label is not a .deb file: $source" ;;
  esac
  install -d -m 0755 "$destination_dir"
  destination="$destination_dir/$basename"
  [ ! -e "$destination" ] && [ ! -L "$destination" ] ||
    ci_die "DEB basename collision: $basename"
  cp -a -- "$source" "$destination"
}

ci_assert_unique_deb_packages() {
  local payload_dir=$1 invalid nested deb package architecture
  declare -A package_owner=()

  [ -d "$payload_dir" ] || return 0
  invalid=$(find "$payload_dir" -mindepth 1 -name '*.deb' ! -type f -print -quit)
  [ -z "$invalid" ] || ci_die "DEB input path is not a regular file: $invalid"
  nested=$(find "$payload_dir" -mindepth 2 -type f -name '*.deb' -print -quit)
  [ -z "$nested" ] || ci_die "nested DEB is not an install input: $nested"
  while IFS= read -r -d '' deb; do
    [ ! -L "$deb" ] || ci_die "DEB input must not be a symlink: $deb"
    package=$(dpkg-deb -f "$deb" Package) || ci_die "cannot read DEB package identity: $deb"
    case "$package" in
      ''|*[!a-z0-9+.-]*) ci_die "invalid DEB package identity '$package': $deb" ;;
    esac
    architecture=$(dpkg-deb -f "$deb" Architecture) ||
      ci_die "cannot read DEB architecture: $deb"
    case "$architecture" in
      arm64|all) ;;
      *) ci_die "unsupported DEB architecture '$architecture': $deb" ;;
    esac
    [ -z "${package_owner[$package]+x}" ] ||
      ci_die "duplicate DEB Package '$package': ${package_owner[$package]} and $deb"
    package_owner[$package]=$deb
  done < <(find "$payload_dir" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
}

ci_is_forbidden_tb321fu_legacy_path() {
  local relative=${1#/}

  case "/$relative" in
    /etc/dbus-1/system.d/net.hadess.SensorProxy-y700-ssc.conf|\
    /etc/systemd/system/iio-sensor-proxy.service.d/10-y700-ssc.conf|\
    /etc/systemd/system/y700-sns-init.service|\
    /etc/systemd/system/y700-aw86937-haptics.service|\
    /etc/systemd/system/multi-user.target.wants/y700-sns-init.service|\
    /etc/systemd/system/multi-user.target.wants/y700-aw86937-haptics.service|\
    /etc/udev/rules.d/80-y700-iio-sensor-proxy.rules|\
    /etc/udev/rules.d/90-y700-haptics.rules|\
    /usr/lib/systemd/system/y700-sns-init.service|\
    /usr/lib/systemd/system/y700-aw86937-haptics.service|\
    /usr/lib/udev/rules.d/80-y700-iio-sensor-proxy.rules|\
    /usr/lib/udev/rules.d/90-y700-haptics.rules|\
    /usr/local/bin/y700-sns-init.sh|\
    /usr/local/sbin/y700-sns-init.sh|\
    /usr/local/bin/y700-iio-sensor-proxy|\
    /usr/local/bin/y700-monitor-sensor|\
    /usr/local/sbin/y700-iio-sensor-proxy|\
    /usr/local/libexec/y700-iio-sensor-proxy|\
    /usr/local/bin/y700-aw86937-bind|\
    /usr/local/sbin/y700-aw86937-bind|\
    /usr/local/lib/y700-sns|/usr/local/lib/y700-sns/*|\
    /usr/local/share/y700-sns|/usr/local/share/y700-sns/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ci_assert_no_tb321fu_legacy_payload() {
  local root=$1 path relative

  [ -d "$root" ] || ci_die "legacy payload root not found: $root"
  while IFS= read -r -d '' path; do
    relative=${path#"$root"/}
    ci_is_forbidden_tb321fu_legacy_path "$relative" || continue
    ci_die "forbidden legacy Y700 payload remains: /$relative"
  done < <(find "$root" -xdev -mindepth 1 -print0)
}

ci_assert_unique_deb_payload_paths() {
  local payload_dir=$1 scratch=$2 deb package stage path relative kind parent
  local existing_kind existing_owner descendant
  declare -A path_kind=() path_owner=()

  [ -d "$payload_dir" ] || return 0
  install -d -m 0700 "$scratch"
  while IFS= read -r -d '' deb; do
    package=$(dpkg-deb -f "$deb" Package) ||
      ci_die "cannot read DEB package identity for payload ownership: $deb"
    stage="$scratch/$package"
    [ ! -e "$stage" ] || ci_die "duplicate payload ownership stage: $package"
    dpkg-deb -x "$deb" "$stage" ||
      ci_die "cannot extract DEB payload for ownership check: $deb"
    while IFS= read -r -d '' path; do
      relative=${path#"$stage"/}
      ci_validate_payload_relative_path "$relative"
      ci_is_forbidden_tb321fu_legacy_path "$relative" &&
        ci_die "local DEB $package owns forbidden legacy Y700 payload: /$relative"
      if [ -L "$path" ]; then
        kind=symlink
      elif [ -d "$path" ]; then
        kind=directory
      elif [ -f "$path" ]; then
        kind=regular
      else
        ci_die "local DEB $package has unsupported payload member: /$relative"
      fi
      existing_kind=${path_kind[$relative]-}
      existing_owner=${path_owner[$relative]-}
      if [ -n "$existing_kind" ]; then
        if [ "$existing_kind" = directory ] && [ "$kind" = directory ]; then
          continue
        fi
        ci_die "local DEB payload collision at /$relative: $existing_owner ($existing_kind) and $package ($kind)"
      fi
      parent=$(dirname -- "$relative")
      while [ "$parent" != . ]; do
        existing_kind=${path_kind[$parent]-}
        if [ -n "$existing_kind" ] && [ "$existing_kind" != directory ]; then
          ci_die "local DEB payload type collision at /$parent: ${path_owner[$parent]} ($existing_kind) blocks $package /$relative"
        fi
        parent=$(dirname -- "$parent")
      done
      if [ "$kind" != directory ]; then
        for descendant in "${!path_kind[@]}"; do
          case "$descendant" in
            "$relative"/*)
              ci_die "local DEB payload type collision at /$relative: $package ($kind) conflicts with ${path_owner[$descendant]} /$descendant"
              ;;
          esac
        done
      fi
      path_kind[$relative]=$kind
      path_owner[$relative]=$package
    done < <(find "$stage" -xdev -mindepth 1 -print0 | sort -z)
  done < <(find "$payload_dir" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
}

ci_validate_payload_relative_path() {
  local relative=$1 component
  local -a components=()

  [[ $relative != "" && $relative != /* && $relative != *$'\t'* && \
    $relative != *$'\r'* && $relative != *$'\n'* ]] ||
    ci_die "unsafe local DEB payload path: $relative"
  IFS=/ read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [ -n "$component" ] && [ "$component" != . ] && [ "$component" != .. ] ||
      ci_die "unsafe local DEB payload path: $relative"
  done
}

ci_assert_real_rootfs_payload_parent() {
  local root=$1 relative=$2 component current=$root
  local -a components=()
  local index

  ci_validate_payload_relative_path "$relative"
  [ -d "$root" ] && [ ! -L "$root" ] ||
    ci_die "rootfs payload root is unsafe: $root"
  IFS=/ read -r -a components <<< "$relative"
  for ((index = 0; index + 1 < ${#components[@]}; index++)); do
    component=${components[index]}
    current="$current/$component"
    [ -d "$current" ] && [ ! -L "$current" ] ||
      ci_die "rootfs payload parent is unsafe: $current"
  done
}

ci_payload_snapshot_record() {
  local root=$1 relative=$2 output=$3 path kind mode uid gid value

  ci_assert_real_rootfs_payload_parent "$root" "$relative"
  path="$root/$relative"
  if [ -L "$path" ]; then
    kind=symlink
    value=$(readlink -- "$path")
    [[ -n $value && $value != *$'\t'* && $value != *$'\r'* && $value != *$'\n'* ]] ||
      ci_die "unsafe local DEB symlink target: /$relative"
  elif [ -f "$path" ]; then
    kind=regular
    value=$(sha256sum -- "$path" | awk '{print $1}')
    [[ $value =~ ^[0-9a-f]{64}$ ]] ||
      ci_die "invalid local DEB payload digest: /$relative"
  elif [ -d "$path" ]; then
    kind=directory
    value=-
  else
    ci_die "installed local DEB payload is missing or unsupported: /$relative"
  fi
  read -r mode uid gid < <(stat -c '%a %u %g' -- "$path")
  [[ $mode =~ ^[0-7]{3,4}$ && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] ||
    ci_die "invalid local DEB payload metadata: /$relative"
  printf 'entry\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$kind" "$relative" "$mode" "$uid" "$gid" "$value" >> "$output"
}

# Snapshots the installed state of every local DEB payload member before an
# optional final overlay is applied. The later comparison prevents an overlay
# from silently replacing package-owned device files while allowing explicit
# post-install behavior from the package itself.
ci_snapshot_local_deb_payload() {
  local root=$1 payload_dir=$2 scratch=$3 output=$4 deb package stage path relative
  local entries="$output.entries" temporary="$output.tmp"
  local existing_kind
  declare -A seen_kind=()

  [ -d "$root" ] && [ ! -L "$root" ] || ci_die "rootfs payload root is unsafe: $root"
  [ -d "$payload_dir" ] && [ ! -L "$payload_dir" ] ||
    ci_die "local DEB payload directory is unsafe: $payload_dir"
  rm -rf -- "$scratch"
  install -d -m 0700 "$scratch"
  : > "$entries"
  while IFS= read -r -d '' deb; do
    [ ! -L "$deb" ] || ci_die "local DEB payload must not be a symlink: $deb"
    package=$(dpkg-deb -f "$deb" Package) ||
      ci_die "cannot read local DEB package identity: $deb"
    case "$package" in
      ''|*[!a-z0-9+.-]*) ci_die "invalid local DEB package identity: $package" ;;
    esac
    stage="$scratch/$package"
    [ ! -e "$stage" ] && [ ! -L "$stage" ] ||
      ci_die "duplicate local DEB snapshot stage: $package"
    dpkg-deb -x "$deb" "$stage" ||
      ci_die "cannot extract local DEB payload snapshot: $deb"
    while IFS= read -r -d '' path; do
      relative=${path#"$stage"/}
      ci_validate_payload_relative_path "$relative"
      if [ -L "$path" ]; then
        existing_kind=${seen_kind[$relative]-}
        [ -z "$existing_kind" ] ||
          ci_die "local DEB payload collision in snapshot: /$relative"
        seen_kind[$relative]=symlink
      elif [ -f "$path" ]; then
        existing_kind=${seen_kind[$relative]-}
        [ -z "$existing_kind" ] ||
          ci_die "local DEB payload collision in snapshot: /$relative"
        seen_kind[$relative]=regular
      elif [ -d "$path" ]; then
        existing_kind=${seen_kind[$relative]-}
        if [ -n "$existing_kind" ] && [ "$existing_kind" != directory ]; then
          ci_die "local DEB payload type collision in snapshot: /$relative"
        fi
        seen_kind[$relative]=directory
      else
        ci_die "unsupported local DEB payload member in snapshot: /$relative"
      fi
      ci_payload_snapshot_record "$root" "$relative" "$entries"
    done < <(find "$stage" -xdev -mindepth 1 -print0 | sort -z)
  done < <(find "$payload_dir" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)

  if [ ! -s "$entries" ]; then
    rm -f -- "$entries" "$temporary"
    rm -rf -- "$scratch"
    return 0
  fi
  LC_ALL=C sort -u "$entries" > "$temporary"
  {
    printf 'schema\ttb321fu.local-deb-payload/v1\n'
    cat "$temporary"
  } > "$output"
  chmod 0600 "$output"
  rm -f -- "$entries" "$temporary"
  rm -rf -- "$scratch"
}

ci_verify_local_deb_payload_snapshot() {
  local root=$1 snapshot=$2 line tag kind relative mode uid gid expected extra
  local actual_mode actual_uid actual_gid actual_value previous= schema=0 entries=0 path

  [ -f "$snapshot" ] && [ ! -L "$snapshot" ] ||
    ci_die "local DEB payload snapshot is unsafe: $snapshot"
  [ "$(stat -c '%s' -- "$snapshot")" -le 16777216 ] ||
    ci_die 'local DEB payload snapshot is too large'
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line != *$'\r'* && $line != *[!$'\t'[:print:]]* ]] ||
      ci_die 'local DEB payload snapshot contains unsafe characters'
    IFS=$'\t' read -r tag kind relative mode uid gid expected extra <<< "$line"
    if [ "$schema" -eq 0 ]; then
      [ "$line" = $'schema\ttb321fu.local-deb-payload/v1' ] ||
        ci_die 'invalid local DEB payload snapshot schema'
      schema=1
      continue
    fi
    [ "$tag" = entry ] && [ -z "${extra:-}" ] ||
      ci_die 'malformed local DEB payload snapshot entry'
    ci_validate_payload_relative_path "$relative"
    [[ $mode =~ ^[0-7]{3,4}$ && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] ||
      ci_die "invalid local DEB payload snapshot metadata: /$relative"
    [ -z "$previous" ] || [[ $line > $previous ]] ||
      ci_die 'local DEB payload snapshot entries are not ordered'
    previous=$line
    ci_assert_real_rootfs_payload_parent "$root" "$relative"
    path="$root/$relative"
    case "$kind" in
      directory)
        [ "$expected" = - ] && [ -d "$path" ] && [ ! -L "$path" ] ||
          ci_die "local DEB payload changed after overlay: /$relative"
        actual_value=-
        ;;
      regular)
        [[ $expected =~ ^[0-9a-f]{64}$ ]] && [ -f "$path" ] && [ ! -L "$path" ] ||
          ci_die "local DEB payload changed after overlay: /$relative"
        actual_value=$(sha256sum -- "$path" | awk '{print $1}')
        ;;
      symlink)
        [[ -n $expected && $expected != *$'\t'* && $expected != *$'\r'* && $expected != *$'\n'* ]] &&
          [ -L "$path" ] || ci_die "local DEB payload changed after overlay: /$relative"
        actual_value=$(readlink -- "$path")
        ;;
      *) ci_die "invalid local DEB payload snapshot kind: $kind" ;;
    esac
    read -r actual_mode actual_uid actual_gid < <(stat -c '%a %u %g' -- "$path")
    [ "$actual_mode" = "$mode" ] && [ "$actual_uid" = "$uid" ] &&
      [ "$actual_gid" = "$gid" ] && [ "$actual_value" = "$expected" ] ||
      ci_die "local DEB payload changed after overlay: /$relative"
    entries=$((entries + 1))
  done < "$snapshot"
  [ "$schema" -eq 1 ] && [ "$entries" -gt 0 ] ||
    ci_die 'local DEB payload snapshot is incomplete'
}

ci_seed_default_user_keyboard_config() {
  local root=$1 default_user=$2 home config_dir skel_config user_config
  local passwd_file entry uid gid seeded=0 status ownership

  [ -d "$root" ] && [ ! -L "$root" ] || ci_die "rootfs keyboard seed root is unsafe: $root"
  home="$root/home/$default_user"
  if [ ! -e "$home" ] && [ ! -L "$home" ]; then
    return 0
  fi
  [ -d "$home" ] && [ ! -L "$home" ] ||
    ci_die "default user home is unsafe: $home"
  passwd_file="$root/etc/passwd"
  [ -f "$passwd_file" ] && [ ! -L "$passwd_file" ] ||
    ci_die "rootfs passwd database is unsafe: $passwd_file"
  entry=$(awk -F: -v user="$default_user" '
    $1 == user { if (found++) exit 2; print $3 " " $4 }
    END { if (!found) exit 1 }
  ' "$passwd_file") || ci_die "default user is absent or duplicated in rootfs passwd database: $default_user"
  read -r uid gid <<< "$entry"
  [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] ||
    ci_die "default user has invalid rootfs ownership: $default_user"

  skel_config="$root/etc/skel/.config/plasmakeyboardrc"
  config_dir="$home/.config"
  user_config="$config_dir/plasmakeyboardrc"
  ci_assert_real_rootfs_payload_parent "$root" etc/skel/.config/plasmakeyboardrc
  [ -f "$skel_config" ] && [ ! -L "$skel_config" ] ||
    ci_die "missing or unsafe default keyboard configuration: $skel_config"
  if [ -e "$config_dir" ] || [ -L "$config_dir" ]; then
    [ -d "$config_dir" ] && [ ! -L "$config_dir" ] ||
      ci_die "default user config directory is unsafe: $config_dir"
  else
    install -d -m 0755 "$config_dir"
    chown "$uid:$gid" "$config_dir"
  fi
  if [ -e "$user_config" ] || [ -L "$user_config" ]; then
    [ -f "$user_config" ] && [ ! -L "$user_config" ] ||
      ci_die "default user keyboard configuration is unsafe: $user_config"
  else
    cp -a -- "$skel_config" "$user_config"
    chown "$uid:$gid" "$user_config"
    seeded=1
  fi

  status=$(dpkg-query --admindir="$root/var/lib/dpkg" \
    -W -f='${db:Status-Status}' tb321fu-haptics 2>/dev/null || true)
  if [ "$status" = installed ]; then
    ownership=$(dpkg-query --admindir="$root/var/lib/dpkg" \
      -S /etc/skel/.config/plasmakeyboardrc 2>/dev/null || true)
    [[ $ownership =~ ^tb321fu-haptics(:[a-z0-9]+)?:\ /etc/skel/\.config/plasmakeyboardrc$ ]] ||
      ci_die 'tb321fu-haptics does not own its final keyboard configuration'
    if [ "$seeded" -eq 1 ]; then
      cmp -s "$skel_config" "$user_config" ||
        ci_die 'newly seeded keyboard configuration differs from final /etc/skel'
    fi
  fi
}

ci_regenerate_deb_md5sums() {
  local package_root=$1 relative

  : > "$package_root/DEBIAN/md5sums"
  while IFS= read -r -d '' relative; do
    (cd "$package_root" && md5sum -- "$relative") >> "$package_root/DEBIAN/md5sums"
  done < <(cd "$package_root" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | sort -z)
  chmod 0644 "$package_root/DEBIAN/md5sums"
}

# Camera files are split out of the historical daily overlay. Keep this list
# deliberately narrow: a package that adds a new camera-owned location must be
# reviewed here instead of silently becoming a second owner.
ci_is_tb321fu_camera_payload_path() {
  local relative=${1#/}

  case "/$relative" in
    /opt/libcamera-y700|/opt/libcamera-y700/*|\
    /usr/lib/aarch64-linux-gnu/spa-0.2/libcamera|/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/*|\
    /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so|\
    /etc/ld.so.conf.d/y700-libcamera.conf|\
    /etc/udev/rules.d/70-y700-camera-dma-heap.rules|\
    /etc/systemd/user/pipewire.service.d/50-y700-libcamera-ipa.conf|\
    /etc/systemd/user/pipewire.service.d/60-y700-libcamera-paths.conf|\
    /etc/systemd/user/wireplumber.service.d/60-y700-libcamera-paths.conf|\
    /usr/local/bin/y700-camera-env|\
    /usr/local/bin/y700-camera-cam|\
    /usr/local/bin/y700-camera-preview)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ci_assert_tb321fu_camera_stack_tree() {
  local root=$1 path relative
  local -a required=(
    opt/libcamera-y700/bin/cam
    opt/libcamera-y700/bin/libcamera-bug-report
    opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy
    opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1
    opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera-base.so.0.7.1
    opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so
    opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so
    usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so
    usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so
    etc/ld.so.conf.d/y700-libcamera.conf
    etc/udev/rules.d/70-y700-camera-dma-heap.rules
    etc/systemd/user/pipewire.service.d/50-y700-libcamera-ipa.conf
    etc/systemd/user/pipewire.service.d/60-y700-libcamera-paths.conf
    etc/systemd/user/wireplumber.service.d/60-y700-libcamera-paths.conf
    usr/local/bin/y700-camera-env
    usr/local/bin/y700-camera-cam
    usr/local/bin/y700-camera-preview
  )

  [ -d "$root" ] || ci_die "camera package tree not found: $root"
  for relative in "${required[@]}"; do
    [ -e "$root/$relative" ] || [ -L "$root/$relative" ] ||
      ci_die "camera package is missing required payload member: /$relative"
  done
  while IFS= read -r -d '' path; do
    relative=${path#"$root"/}
    ci_is_tb321fu_camera_payload_path "$relative" ||
      ci_die "camera package owns an unreviewed payload path: /$relative"
  done < <(find "$root" -xdev -mindepth 1 \( -type f -o -type l \) -print0 | sort -z)
}

ci_deb_relation_has_package() {
  local deb=$1 field=$2 expected=$3 value

  value=$(dpkg-deb -f "$deb" "$field" 2>/dev/null || true)
  printf '%s\n' "$value" |
    tr ',' '\n' |
    sed -E 's/^[[:space:]]*([^[:space:](]+).*/\1/' |
    grep -Fx "$expected" >/dev/null
}

ci_deb_relation_has_exact_clause() {
  local deb=$1 field=$2 expected=$3 value

  value=$(dpkg-deb -f "$deb" "$field" 2>/dev/null || true)
  printf '%s\n' "$value" |
    tr ',' '\n' |
    sed -E 's/^[[:space:]]+|[[:space:]]+$//g' |
    grep -Fx "$expected" >/dev/null
}

ci_assert_tb321fu_camera_stack_deb() {
  local deb=$1 stage=$2 field

  [ "$(dpkg-deb -f "$deb" Package)" = tb321fu-camera-stack ] ||
    ci_die "camera package has wrong Package identity: $deb"
  ci_deb_relation_has_exact_clause "$deb" Pre-Depends \
    "tb321fu-camera-payload-migrated (>= $TB321FU_CAMERA_PAYLOAD_MIGRATION_ABI)" ||
    ci_die "camera package must Pre-Depends on the versioned tb321fu camera migration capability"
  ci_deb_relation_has_package "$deb" Replaces y700-daily-rootfs-overlay ||
    ci_die "camera package must declare Replaces: y700-daily-rootfs-overlay"
  if ci_deb_relation_has_package "$deb" Breaks y700-daily-rootfs-overlay ||
     ci_deb_relation_has_package "$deb" Conflicts y700-daily-rootfs-overlay; then
    ci_die "camera package must coexist with y700-daily-rootfs-overlay"
  fi
  for field in Replaces Conflicts; do
    ci_deb_relation_has_package "$deb" "$field" libspa-0.2-libcamera ||
      ci_die "camera package must declare $field: libspa-0.2-libcamera"
    ci_deb_relation_has_package "$deb" "$field" gstreamer1.0-libcamera ||
      ci_die "camera package must declare $field: gstreamer1.0-libcamera"
  done

  rm -rf -- "$stage"
  dpkg-deb -x "$deb" "$stage"
  ci_assert_tb321fu_camera_stack_tree "$stage"
}

ci_assert_camera_payloads_have_unique_owners() {
  local payload_dir=$1 camera_stage=$2 path relative owners owner_count

  [ -d "$camera_stage" ] || ci_die "camera package tree not found: $camera_stage"
  while IFS= read -r -d '' path; do
    relative=${path#"$camera_stage"/}
    owners=$(ci_deb_member_owners "$payload_dir" "$relative")
    owner_count=$(printf '%s\n' "$owners" | sed '/^$/d' | wc -l)
    [ "$owner_count" -eq 1 ] ||
      ci_die "expected exactly one DEB owner for camera payload /$relative, found $owner_count"
    printf '%s\n' "$owners" | cut -f1 | grep -Fx tb321fu-camera-stack >/dev/null ||
      ci_die "tb321fu-camera-stack does not uniquely own /$relative"
  done < <(find "$camera_stage" -xdev -mindepth 1 \( -type f -o -type l \) -print0 | sort -z)
}

ci_assert_no_tb321fu_camera_paths_in_tree() {
  local root=$1 path relative

  while IFS= read -r -d '' path; do
    relative=${path#"$root"/}
    ci_is_tb321fu_camera_payload_path "$relative" || continue
    ci_die "daily payload still owns a camera path after migration: /$relative"
  done < <(find "$root" -xdev -mindepth 1 \( -type f -o -type l \) -print0 | sort -z)
}

ci_prune_empty_tb321fu_camera_directories() {
  local root=$1 relative path
  local -a roots=(
    opt/libcamera-y700
    usr/lib/aarch64-linux-gnu/spa-0.2/libcamera
  )

  for relative in "${roots[@]}"; do
    path="$root/$relative"
    [ -d "$path" ] || continue
    find "$path" -depth -type d -empty -delete
  done
}

ci_migrate_tb321fu_camera_payload() {
  local daily_root=$1 camera_root=$2 path relative daily_path camera_path migrated=0

  [ -d "$daily_root" ] || ci_die "daily package tree not found: $daily_root"
  ci_assert_tb321fu_camera_stack_tree "$camera_root"

  while IFS= read -r -d '' path; do
    relative=${path#"$daily_root"/}
    ci_is_tb321fu_camera_payload_path "$relative" || continue
    daily_path="$daily_root/$relative"
    camera_path="$camera_root/$relative"
    [ -e "$camera_path" ] || [ -L "$camera_path" ] ||
      ci_die "daily package owns camera path not supplied by tb321fu-camera-stack: /$relative"

    if [ -L "$daily_path" ]; then
      [ -L "$camera_path" ] && [ "$(readlink -- "$daily_path")" = "$(readlink -- "$camera_path")" ] ||
        ci_die "camera symlink differs between daily and canonical packages: /$relative"
    elif [ -f "$daily_path" ]; then
      [ -f "$camera_path" ] && cmp -s "$daily_path" "$camera_path" ||
        ci_die "camera payload differs between daily and canonical packages: /$relative"
    else
      ci_die "unsupported camera payload member in daily package: /$relative"
    fi

    rm -f -- "$daily_path"
    migrated=$((migrated + 1))
  done < <(find "$daily_root" -xdev -mindepth 1 \( -type f -o -type l \) -print0 | sort -z)

  ci_prune_empty_tb321fu_camera_directories "$daily_root"
  ci_assert_no_tb321fu_camera_paths_in_tree "$daily_root"
  ci_log "migrated $migrated camera payload members from y700-daily-rootfs-overlay"
}

ci_mark_tb321fu_camera_payload_migrated() {
  local package_root=$1 control capability

  control="$package_root/DEBIAN/control"
  capability="tb321fu-camera-payload-migrated (= $TB321FU_CAMERA_PAYLOAD_MIGRATION_ABI)"

  [ -f "$control" ] || ci_die "daily package control file is missing"
  if grep -Eq '(^|[,[:space:]])tb321fu-camera-payload-migrated($|[,[:space:]])' "$control"; then
    grep -Fq "$capability" "$control" ||
      ci_die "daily package has an incompatible tb321fu camera migration capability"
    return 0
  fi
  if grep -q '^Provides:' "$control"; then
    sed -i "/^Provides:/ s/$/, $capability/" "$control"
  else
    printf 'Provides: %s\n' "$capability" >> "$control"
  fi
}

ci_write_tb321fu_camera_preinst() {
  local package_root=$1

  install -d -m 0755 "$package_root/DEBIAN"
  cat > "$package_root/DEBIAN/preinst" <<'EOF_PREINST'
#!/bin/sh
set -eu

legacy_package=y700-daily-rootfs-overlay

camera_dpkg_query() {
  if [ -n "${DPKG_ADMINDIR:-}" ]; then
    dpkg-query --admindir "$DPKG_ADMINDIR" "$@"
  else
    dpkg-query "$@"
  fi
}

legacy_owns_camera_payload() {
  command -v dpkg-query >/dev/null 2>&1 || return 1
  [ "$(camera_dpkg_query -W -f='${db:Status-Status}' "$legacy_package" 2>/dev/null || true)" = installed ] || return 1
  legacy_paths=$(camera_dpkg_query -L "$legacy_package" 2>/dev/null || true)
  while IFS= read -r path; do
    case "$path" in
      /opt/libcamera-y700|/opt/libcamera-y700/*|\
      /usr/lib/aarch64-linux-gnu/spa-0.2/libcamera|/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/*|\
      /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so|\
      /etc/ld.so.conf.d/y700-libcamera.conf|\
      /etc/udev/rules.d/70-y700-camera-dma-heap.rules|\
      /etc/systemd/user/pipewire.service.d/50-y700-libcamera-ipa.conf|\
      /etc/systemd/user/pipewire.service.d/60-y700-libcamera-paths.conf|\
      /etc/systemd/user/wireplumber.service.d/60-y700-libcamera-paths.conf|\
      /usr/local/bin/y700-camera-env|\
      /usr/local/bin/y700-camera-cam|\
      /usr/local/bin/y700-camera-preview)
        return 0
        ;;
    esac
  done <<EOF_LEGACY_PATHS
$legacy_paths
EOF_LEGACY_PATHS
  return 1
}

case "${1:-}" in
  install|upgrade)
    if legacy_owns_camera_payload; then
      echo "tb321fu-camera-stack: y700-daily-rootfs-overlay still owns camera files; install the camera-less daily package first" >&2
      exit 1
    fi
    ;;
esac

exit 0
EOF_PREINST
  chmod 0755 "$package_root/DEBIAN/preinst"
}

ci_migrate_tb321fu_audio_route_policy() {
  local package_root=$1
  local old_conf=etc/wireplumber/wireplumber.conf.d/52-y700-headset-cleanup.conf
  local old_script=usr/share/wireplumber/scripts/y700/headset-cleanup.lua
  local new_conf=etc/wireplumber/wireplumber.conf.d/52-tb321fu-headset-route-reconcile.conf
  local new_script=usr/share/wireplumber/scripts/tb321fu/headset-route-reconcile.lua
  local payload_dir="$SCRIPT_DIR/payloads"
  local actual

  [ -f "$package_root/$old_conf" ] && [ ! -L "$package_root/$old_conf" ] ||
    ci_die "tested WirePlumber headset cleanup config is missing from daily payload"
  [ -f "$package_root/$old_script" ] && [ ! -L "$package_root/$old_script" ] ||
    ci_die "tested WirePlumber headset cleanup script is missing from daily payload"
  [ ! -e "$package_root/$new_conf" ] && [ ! -L "$package_root/$new_conf" ] ||
    ci_die "daily payload already owns the TB321FU route reconcile config"
  [ ! -e "$package_root/$new_script" ] && [ ! -L "$package_root/$new_script" ] ||
    ci_die "daily payload already owns the TB321FU route reconcile script"

  actual=$(sha256sum "$package_root/$old_conf" | awk '{print $1}')
  [ "$actual" = 5ea413266962a5bec45b6e287dc7e5bd6ab45112f4c2fd23810004e32b6328b2 ] ||
    ci_die "unrecognized tested WirePlumber headset cleanup config: $actual"
  actual=$(sha256sum "$package_root/$old_script" | awk '{print $1}')
  [ "$actual" = 6da046508f8965e05d9ec2d2b9e8b7bb7d556924f21f671b41b2451714f988c9 ] ||
    ci_die "unrecognized tested WirePlumber headset cleanup script: $actual"

  [ -f "$payload_dir/52-tb321fu-headset-route-reconcile.conf" ] ||
    ci_die "missing canonical TB321FU WirePlumber route reconcile config"
  [ -f "$payload_dir/tb321fu-headset-route-reconcile.lua" ] ||
    ci_die "missing canonical TB321FU WirePlumber route reconcile script"

  rm -f -- "$package_root/$old_conf" "$package_root/$old_script"
  rmdir --ignore-fail-on-non-empty "$package_root/usr/share/wireplumber/scripts/y700" 2>/dev/null || true
  install -D -m 0644 "$payload_dir/52-tb321fu-headset-route-reconcile.conf" \
    "$package_root/$new_conf"
  install -D -m 0644 "$payload_dir/tb321fu-headset-route-reconcile.lua" \
    "$package_root/$new_script"
}

ci_remove_tb321fu_legacy_sensor_haptics() {
  local root=$1 relative
  local -a files=(
    etc/dbus-1/system.d/net.hadess.SensorProxy-y700-ssc.conf
    etc/systemd/system/iio-sensor-proxy.service.d/10-y700-ssc.conf
    etc/systemd/system/y700-sns-init.service
    etc/systemd/system/y700-aw86937-haptics.service
    etc/systemd/system/multi-user.target.wants/y700-sns-init.service
    etc/systemd/system/multi-user.target.wants/y700-aw86937-haptics.service
    etc/udev/rules.d/80-y700-iio-sensor-proxy.rules
    etc/udev/rules.d/90-y700-haptics.rules
    usr/lib/systemd/system/y700-sns-init.service
    usr/lib/systemd/system/y700-aw86937-haptics.service
    usr/lib/udev/rules.d/80-y700-iio-sensor-proxy.rules
    usr/lib/udev/rules.d/90-y700-haptics.rules
    usr/local/bin/y700-sns-init.sh
    usr/local/sbin/y700-sns-init.sh
    usr/local/bin/y700-iio-sensor-proxy
    usr/local/bin/y700-monitor-sensor
    usr/local/sbin/y700-iio-sensor-proxy
    usr/local/libexec/y700-iio-sensor-proxy
    usr/local/bin/y700-aw86937-bind
    usr/local/sbin/y700-aw86937-bind
  )

  [ -d "$root" ] || ci_die "legacy cleanup root not found: $root"
  for relative in "${files[@]}"; do
    rm -f -- "$root/$relative"
  done
  rm -rf -- "$root/usr/local/lib/y700-sns" "$root/usr/local/share/y700-sns"
}

ci_prepare_y700_daily_payload_deb() {
  local payload_dir=$1 scratch=$2 deb package daily_deb= haptics_deb= camera_deb=
  local daily_stage="$scratch/y700-daily-rootfs-overlay" haptics_stage="$scratch/tb321fu-haptics"
  local camera_stage="$scratch/tb321fu-camera-stack"
  local rebuilt="$scratch/y700-daily-rootfs-overlay.rebuilt.deb"
  local relative owners owner_count
  local -a firmware=(
    usr/lib/firmware/haptic_ram.bin
    usr/lib/firmware/haptic_click.bin
  )

  [ -d "$payload_dir" ] || return 0
  install -d -m 0700 "$scratch"
  while IFS= read -r -d '' deb; do
    package=$(dpkg-deb -f "$deb" Package)
    case "$package" in
      y700-daily-rootfs-overlay)
        [ -z "$daily_deb" ] || ci_die "multiple y700-daily-rootfs-overlay packages were supplied"
        daily_deb=$deb
        ;;
      tb321fu-haptics|tb321fu-haptics-common)
        if ci_deb_has_member "$deb" usr/lib/firmware/haptic_ram.bin ||
           ci_deb_has_member "$deb" usr/lib/firmware/haptic_click.bin; then
          [ -z "$haptics_deb" ] || ci_die "multiple TB321FU haptics firmware packages were supplied"
          haptics_deb=$deb
        fi
        ;;
      tb321fu-camera-stack)
        [ -z "$camera_deb" ] || ci_die "multiple tb321fu-camera-stack packages were supplied"
        camera_deb=$deb
        ;;
    esac
  done < <(find "$payload_dir" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)

  if [ -n "$camera_deb" ]; then
    ci_assert_tb321fu_camera_stack_deb "$camera_deb" "$camera_stage"
  fi

  if [ -z "$daily_deb" ]; then
    ci_assert_unique_deb_payload_paths "$payload_dir" "$scratch/payload-ownership"
    rm -rf -- "$camera_stage"
    return 0
  fi
  [ -n "$haptics_deb" ] || \
    ci_die "y700-daily-rootfs-overlay requires a canonical tb321fu-haptics firmware package"

  for relative in "${firmware[@]}"; do
    owners=$(ci_deb_member_owners "$payload_dir" "$relative")
    owner_count=$(printf '%s\n' "$owners" | sed '/^$/d' | wc -l)
    [ "$owner_count" -eq 2 ] || \
      ci_die "expected daily and canonical owners for /$relative before migration, found $owner_count"
    printf '%s\n' "$owners" | cut -f1 | grep -Fx y700-daily-rootfs-overlay >/dev/null || \
      ci_die "daily package does not own /$relative before migration"
  done

  rm -rf -- "$daily_stage" "$haptics_stage"
  dpkg-deb -R "$daily_deb" "$daily_stage"
  dpkg-deb -x "$haptics_deb" "$haptics_stage"
  ci_remove_tb321fu_legacy_sensor_haptics "$daily_stage"
  for relative in "${firmware[@]}"; do
    [ -f "$daily_stage/$relative" ] || ci_die "daily haptics firmware is missing: /$relative"
    [ -f "$haptics_stage/$relative" ] || ci_die "canonical haptics firmware is missing: /$relative"
    cmp -s "$daily_stage/$relative" "$haptics_stage/$relative" || \
      ci_die "haptics firmware differs between daily and canonical packages: /$relative"
    rm -f -- "$daily_stage/$relative"
  done

  ci_migrate_tb321fu_audio_route_policy "$daily_stage"
  if [ -n "$camera_deb" ]; then
    ci_migrate_tb321fu_camera_payload "$daily_stage" "$camera_stage"
    ci_mark_tb321fu_camera_payload_migrated "$daily_stage"
  fi

  ci_normalize_system_payload_modes "$daily_stage"
  ci_regenerate_deb_md5sums "$daily_stage"
  ci_assert_normalized_system_payload_modes "$daily_stage"
  ci_normalize_package_tree "$daily_stage"
  dpkg-deb --build --root-owner-group "$daily_stage" "$rebuilt" >/dev/null
  mv -f -- "$rebuilt" "$daily_deb"

  for relative in "${firmware[@]}"; do
    owners=$(ci_deb_member_owners "$payload_dir" "$relative")
    owner_count=$(printf '%s\n' "$owners" | sed '/^$/d' | wc -l)
    [ "$owner_count" -eq 1 ] || ci_die "expected one owner for /$relative after migration, found $owner_count"
    printf '%s\n' "$owners" | cut -f1 | grep -E '^tb321fu-haptics(-common)?$' >/dev/null || \
      ci_die "canonical TB321FU haptics package does not uniquely own /$relative"
  done
  if [ -n "$camera_deb" ]; then
    ci_assert_camera_payloads_have_unique_owners "$payload_dir" "$camera_stage"
    ci_deb_relation_has_exact_clause "$daily_deb" Provides \
      "tb321fu-camera-payload-migrated (= $TB321FU_CAMERA_PAYLOAD_MIGRATION_ABI)" ||
      ci_die "rewritten daily package lacks the versioned tb321fu camera migration capability"
  fi

  ci_assert_unique_deb_payload_paths "$payload_dir" "$scratch/payload-ownership"

  rm -rf -- "$daily_stage" "$haptics_stage" "$camera_stage"
  ci_log "normalized y700-daily-rootfs-overlay modes and migrated haptics/audio/camera policy ownership"
}
