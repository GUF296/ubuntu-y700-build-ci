#!/usr/bin/env bash

# This file is sourced by CI build scripts after common.sh.

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

ci_regenerate_deb_md5sums() {
  local package_root=$1 relative

  : > "$package_root/DEBIAN/md5sums"
  while IFS= read -r -d '' relative; do
    (cd "$package_root" && md5sum -- "$relative") >> "$package_root/DEBIAN/md5sums"
  done < <(cd "$package_root" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | sort -z)
  chmod 0644 "$package_root/DEBIAN/md5sums"
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
  local payload_dir=$1 scratch=$2 deb package daily_deb= canonical_deb=
  local daily_stage="$scratch/y700-daily-rootfs-overlay" canonical_stage="$scratch/tb321fu-haptics"
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
          [ -z "$canonical_deb" ] || ci_die "multiple TB321FU haptics firmware packages were supplied"
          canonical_deb=$deb
        fi
        ;;
    esac
  done < <(find "$payload_dir" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)

  [ -n "$daily_deb" ] || return 0
  [ -n "$canonical_deb" ] || \
    ci_die "y700-daily-rootfs-overlay requires a canonical tb321fu-haptics firmware package"

  for relative in "${firmware[@]}"; do
    owners=$(ci_deb_member_owners "$payload_dir" "$relative")
    owner_count=$(printf '%s\n' "$owners" | sed '/^$/d' | wc -l)
    [ "$owner_count" -eq 2 ] || \
      ci_die "expected daily and canonical owners for /$relative before migration, found $owner_count"
    printf '%s\n' "$owners" | cut -f1 | grep -Fx y700-daily-rootfs-overlay >/dev/null || \
      ci_die "daily package does not own /$relative before migration"
  done

  rm -rf -- "$daily_stage" "$canonical_stage"
  dpkg-deb -R "$daily_deb" "$daily_stage"
  dpkg-deb -x "$canonical_deb" "$canonical_stage"
  ci_remove_tb321fu_legacy_sensor_haptics "$daily_stage"
  for relative in "${firmware[@]}"; do
    [ -f "$daily_stage/$relative" ] || ci_die "daily haptics firmware is missing: /$relative"
    [ -f "$canonical_stage/$relative" ] || ci_die "canonical haptics firmware is missing: /$relative"
    cmp -s "$daily_stage/$relative" "$canonical_stage/$relative" || \
      ci_die "haptics firmware differs between daily and canonical packages: /$relative"
    rm -f -- "$daily_stage/$relative"
  done

  ci_migrate_tb321fu_audio_route_policy "$daily_stage"

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

  rm -rf -- "$daily_stage" "$canonical_stage"
  ci_log "normalized y700-daily-rootfs-overlay modes and migrated haptics/audio policy ownership"
}
