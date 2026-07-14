#!/usr/bin/env bash

# Shared GRUB helpers for the daily direct-boot payload.
# shellcheck shell=bash

Y700_GRUB_BUILD_DIR=${Y700_GRUB_BUILD_DIR:-}
Y700_DIRECT_BOOT_EFI_NAME=${Y700_DIRECT_BOOT_EFI_NAME:-QCOMRAMP.EFI}
Y700_DIRECT_BOOT_RESERVED_MEMORY=${Y700_DIRECT_BOOT_RESERVED_MEMORY:-"/reserved-memory/qdss@82800000 /reserved-memory/splash-region /reserved-memory/trust-ui-vm@f3800000 /reserved-memory/oem-vm@f7c00000"}

y700_reject() {
	printf 'invalid GRUB configuration: %s\n' "$*" >&2
	return 1
}

y700_validate_kernel_args() {
	local label=$1 value=$2 token
	local -a tokens=()
	[ -n "$value" ] || { y700_reject "$label must not be empty"; return 1; }
	[[ $value != *$'\n'* && $value != *$'\r'* && $value != *$'\t'* ]] || {
		y700_reject "$label contains control whitespace"
		return 1
	}
	read -r -a tokens <<< "$value"
	[ "${#tokens[@]}" -gt 0 ] || { y700_reject "$label has no tokens"; return 1; }
	for token in "${tokens[@]}"; do
		[[ $token =~ ^[A-Za-z0-9_.,:=/@%+-]+$ ]] || {
			y700_reject "$label contains an unsafe token: $token"
			return 1
		}
	done
}

y700_validate_dtb_name() {
	local value=$1
	[[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || { y700_reject "unsafe DTB basename: $value"; return 1; }
}

y700_validate_cfg_name() {
	local value=$1 lower
	[[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.[Cc][Ff][Gg]$ ]] || {
		y700_reject "unsafe QCOMRAMP config basename: $value"
		return 1
	}
	lower=${value,,}
	[ "$lower" != grub.cfg ] || { y700_reject "QCOMRAMP config must not overwrite outer grub.cfg"; return 1; }
}

y700_validate_efi_name() {
	local value=$1 lower
	[[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.[Ee][Ff][Ii]$ ]] || {
		y700_reject "unsafe direct EFI basename: $value"
		return 1
	}
	lower=${value,,}
	[ "$lower" != bootaa64.efi ] || { y700_reject "direct EFI must not overwrite BOOTAA64.EFI"; return 1; }
}

y700_validate_timeout() {
	local value=$1
	[[ $value =~ ^[0-9]+$ ]] || { y700_reject "GRUB timeout is not an integer: $value"; return 1; }
	[ "$((10#$value))" -le 60 ] || { y700_reject "GRUB timeout exceeds 60 seconds: $value"; return 1; }
}

y700_reserved_memory_line() {
	local path line="qcomfdtmem disable-reserved"
	local -a paths=()
	read -r -a paths <<< "$Y700_DIRECT_BOOT_RESERVED_MEMORY"
	[ "${#paths[@]}" -gt 0 ] || { y700_reject "reserved-memory path list is empty"; return 1; }
	for path in "${paths[@]}"; do
		[[ $path =~ ^/[A-Za-z0-9._@,+/-]+$ ]] || { y700_reject "unsafe reserved-memory path: $path"; return 1; }
		[[ /$path/ != */../* && /$path/ != */./* ]] || {
			y700_reject "relative component in reserved-memory path: $path"
			return 1
		}
		line="$line $path"
	done
	printf '%s\n' "$line"
}

y700_write_direct_grub_cfg() {
	local cfg=$1
	local dtb_name=$2
	local rootargs=$3
	local stableargs=$4
	local reserved_line

	y700_validate_dtb_name "$dtb_name" || return 1
	y700_validate_kernel_args rootargs "$rootargs" || return 1
	y700_validate_kernel_args stableargs "$stableargs" || return 1
	reserved_line=$(y700_reserved_memory_line) || return 1

	cat > "$cfg" <<EOF
set timeout=0
set default=0
set gfxpayload=keep

menuentry "Qualcomm direct boot (RamPartition memory)" {
    search --no-floppy --file /Image --set=root
    devicetree /dtb/$dtb_name
    qcomfdtmem source rampartition
    $reserved_line
    linuxdirect /Image $rootargs $stableargs
}
EOF
}

y700_write_outer_grub_cfg() {
	local cfg=$1
	local timeout=$2
	local direct_efi_name=$3

	y700_validate_timeout "$timeout" || return 1
	y700_validate_efi_name "$direct_efi_name" || return 1
	cat > "$cfg" <<EOF
set timeout=$timeout
set default=0
set gfxpayload=keep

search --no-floppy --file /Image --set=root

menuentry "Continue boot" {
    search --no-floppy --file /Image --set=root
    chainloader /EFI/BOOT/$direct_efi_name
    boot
}

menuentry "Reboot" {
    reboot
}

menuentry "Power off" {
    halt
}
EOF
}

y700_build_direct_grub_efi() {
	local embedded_cfg=$1
	local out_efi=$2

	[ -n "$Y700_GRUB_BUILD_DIR" ] || {
		y700_reject "Y700_GRUB_BUILD_DIR is required for a fresh direct-GRUB EFI build"
		return 1
	}
	[ -x "$Y700_GRUB_BUILD_DIR/grub-mkstandalone" ] ||
		{ y700_reject "missing GRUB direct-boot builder: $Y700_GRUB_BUILD_DIR/grub-mkstandalone"; return 1; }
	[ -d "$Y700_GRUB_BUILD_DIR/grub-core" ] ||
		{ y700_reject "missing GRUB module directory: $Y700_GRUB_BUILD_DIR/grub-core"; return 1; }

	"$Y700_GRUB_BUILD_DIR/grub-mkstandalone" \
		-d "$Y700_GRUB_BUILD_DIR/grub-core" \
		-O arm64-efi \
		-o "$out_efi" \
		--locales= \
		--fonts= \
		--themes= \
		--modules="normal linuxdirect fdt fat part_gpt search search_fs_file reboot halt sleep rampartition" \
		"/boot/grub/grub.cfg=$embedded_cfg"
}

y700_stage_direct_grub_payload() {
	local out_dir=$1
	local dtb_name=$2
	local timeout=$3
	local rootargs=$4
	local stableargs=$5
	local direct_cfg="$out_dir/.QCOMRAMP-grub.cfg.tmp"
	local outer_cfg="$out_dir/grub.cfg"
	local direct_efi="$out_dir/$Y700_DIRECT_BOOT_EFI_NAME"

	y700_validate_efi_name "$Y700_DIRECT_BOOT_EFI_NAME" || return 1
	y700_write_direct_grub_cfg "$direct_cfg" "$dtb_name" "$rootargs" "$stableargs" || return 1
	y700_build_direct_grub_efi "$direct_cfg" "$direct_efi" || return 1
	rm -f "$direct_cfg"
	y700_write_outer_grub_cfg "$outer_cfg" "$timeout" "$Y700_DIRECT_BOOT_EFI_NAME" || return 1
}
