#!/usr/bin/env bash
set -euo pipefail

PROGRAM=arch-dd-oneclick
VERSION=0.2.0

WORK_DIR=/archdd
STAGE2_DIR=$WORK_DIR/stage2
NETWORK_DIR=$WORK_DIR/networkd
STATE_FILE=$WORK_DIR/state.env
LOG_FILE=$WORK_DIR/stage1.log
INITRAMFS_TREE=$WORK_DIR/initramfs-tree
INITRD_IMAGE=$WORK_DIR/archdd-initrd.img
ALPINE_KERNEL_IMAGE=$WORK_DIR/archdd-vmlinuz
ALPINE_INITRD_DOWNLOAD=$WORK_DIR/alpine-initramfs-virt.gz
BOOT_KERNEL=/boot/archdd-vmlinuz
BOOT_INITRD=/boot/archdd-initrd.img
GRUB_SNIPPET=/etc/grub.d/41_archdd_oneclick
ALPINE_NETBOOT_BASE=${ALPINE_NETBOOT_BASE:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/netboot}
ALPINE_REPO_URL=${ALPINE_REPO_URL:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/main}
ALPINE_KERNEL_URL=${ALPINE_KERNEL_URL:-$ALPINE_NETBOOT_BASE/vmlinuz-virt}
ALPINE_INITRD_URL=${ALPINE_INITRD_URL:-$ALPINE_NETBOOT_BASE/initramfs-virt}
ALPINE_MODLOOP_URL=${ALPINE_MODLOOP_URL:-$ALPINE_NETBOOT_BASE/modloop-virt}
ALPINE_PKGS=${ALPINE_PKGS:-bash,curl,coreutils,iproute2,zstd,util-linux,parted,e2fsprogs}

IMAGE_URL=
IMAGE_SHA256=
IMAGE_FORMAT=zst
TARGET_DISK=
TARGET_DISK_ID=
ROOT_PASSWORD=
ROOT_PASSWORD_HASH=
ROOT_PASSWORD_FILE=
HOSTNAME=arch-dd
YES_WIPE=0
DRY_RUN=0
PREPARE_ONLY=0
REBOOT_AFTER_PREPARE=0
FORCE=0
PUBLIC_KEY_FILE=
GRUB_MKCONFIG=
GRUB_REBOOT=
GRUB_CFG=

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

info() {
  printf 'INFO: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  arch-dd-oneclick.sh --img URL --disk /dev/XXX --root-password PASSWORD [options]

Purpose:
  Auditable one-click Arch DD installer for owner-authorized VPS rebuilds.
  It does not call bin456789. It captures current network config, prepares a
  one-time GRUB boot into an official Alpine netboot stage2, downloads a
  generic Arch image, writes it to the selected disk by disk ID, injects the
  captured systemd-networkd config, ensures sshd root password login is enabled,
  then reboots.

Required:
  --img URL                         Raw .img/.img.zst/.zst image URL
  --disk /dev/XXX                   Whole target disk, not a partition
  --root-password PASSWORD          Root password for the installed Arch system
  --root-password-file PATH         Or read root password from first line of file
  --yes-i-know-this-wipes-disk      Required for any destructive prepare

Options:
  --sha256 HEX                      Expected SHA256 of downloaded image object
  --image-format zst|raw            Image stream format, default zst
  --hostname NAME                   Installed system hostname, default arch-dd
  --public-key-file PATH            Optional root authorized_keys file to inject
  --reboot                          Reboot automatically after prepare
  --dry-run                         Print plan and run non-destructive checks
  --prepare-only                    Build /archdd initramfs but do not touch GRUB
  --force                           Skip some conservative environment guards
  -h, --help                        Show this help

Safety controls:
  - Refuses to run unless executed as root.
  - Refuses partition paths such as /dev/sda1 for --disk.
  - Records the selected disk ID before reboot and finds that disk again in
    stage2 instead of trusting the old /dev/sdX name.
  - Requires --yes-i-know-this-wipes-disk.
  - Requires typing the exact target disk during interactive confirmation.
  - Does not scan networks, brute force, exploit, hide persistence, or collect
    credentials. It only rebuilds the local machine it is run on.

First-version limits:
  - Intended for common x86_64 Linux VPS systems booted by GRUB.
  - Stage2 uses official Alpine virt netboot kernel/initramfs.
  - Complex networking such as VRF/VLAN/bond/bridge/policy routing is not
    preserved in this first version.
  - Keep VNC/serial console access available during the first real run.
EOF
}

is_whole_disk() {
  local disk=$1
  [ -b "$disk" ] || return 1
  [ "$(lsblk -dn -o TYPE "$disk" 2>/dev/null || true)" = disk ]
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --img)
        [ "$#" -ge 2 ] || die "--img needs a value"
        IMAGE_URL=$2
        shift 2
        ;;
      --disk)
        [ "$#" -ge 2 ] || die "--disk needs a value"
        TARGET_DISK=$2
        shift 2
        ;;
      --root-password)
        [ "$#" -ge 2 ] || die "--root-password needs a value"
        ROOT_PASSWORD=$2
        shift 2
        ;;
      --root-password-file)
        [ "$#" -ge 2 ] || die "--root-password-file needs a value"
        ROOT_PASSWORD_FILE=$2
        shift 2
        ;;
      --sha256)
        [ "$#" -ge 2 ] || die "--sha256 needs a value"
        IMAGE_SHA256=$2
        shift 2
        ;;
      --image-format)
        [ "$#" -ge 2 ] || die "--image-format needs a value"
        IMAGE_FORMAT=$2
        shift 2
        ;;
      --hostname)
        [ "$#" -ge 2 ] || die "--hostname needs a value"
        HOSTNAME=$2
        shift 2
        ;;
      --public-key-file)
        [ "$#" -ge 2 ] || die "--public-key-file needs a value"
        PUBLIC_KEY_FILE=$2
        shift 2
        ;;
      --yes-i-know-this-wipes-disk)
        YES_WIPE=1
        shift
        ;;
      --reboot)
        REBOOT_AFTER_PREPARE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --prepare-only)
        PREPARE_ONLY=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

validate_args() {
  [ "$(id -u)" -eq 0 ] || die "must run as root"
  [ -n "$IMAGE_URL" ] || die "--img is required"
  [ -n "$TARGET_DISK" ] || die "--disk is required"
  if [ -n "$ROOT_PASSWORD" ] && [ -n "$ROOT_PASSWORD_FILE" ]; then
    die "use only one of --root-password or --root-password-file"
  fi
  if [ -n "$ROOT_PASSWORD_FILE" ]; then
    [ -f "$ROOT_PASSWORD_FILE" ] || die "--root-password-file not found: $ROOT_PASSWORD_FILE"
    IFS= read -r ROOT_PASSWORD <"$ROOT_PASSWORD_FILE" || true
  fi
  [ -n "$ROOT_PASSWORD" ] || die "--root-password or --root-password-file is required"

  case "$IMAGE_URL" in
    http://*|https://*) ;;
    *) die "--img must be http:// or https:// URL" ;;
  esac

  case "$HOSTNAME" in
    *[!A-Za-z0-9.-]*|'') die "--hostname contains unsupported characters" ;;
  esac

  if [ -n "$IMAGE_SHA256" ]; then
    case "$IMAGE_SHA256" in
      *[!A-Fa-f0-9]*|'') die "--sha256 must be hex" ;;
    esac
    [ "${#IMAGE_SHA256}" -eq 64 ] || die "--sha256 must be 64 hex characters"
  fi

  case "$IMAGE_FORMAT" in
    zst|raw) ;;
    *) die "--image-format must be zst or raw" ;;
  esac

  is_whole_disk "$TARGET_DISK" || die "--disk must be an existing whole disk"

  if [ -n "$PUBLIC_KEY_FILE" ]; then
    [ -f "$PUBLIC_KEY_FILE" ] || die "--public-key-file not found: $PUBLIC_KEY_FILE"
  fi
}

confirm_wipe() {
  if [ "$DRY_RUN" = 1 ] || [ "$PREPARE_ONLY" = 1 ]; then
    return 0
  fi
  [ "$YES_WIPE" = 1 ] || die "missing --yes-i-know-this-wipes-disk"

  printf '\n'
  printf 'This will overwrite %s and reinstall the machine.\n' "$TARGET_DISK" >&2
  printf 'Type the exact disk path to continue: ' >&2
  read -r answer
  [ "$answer" = "$TARGET_DISK" ] || die "confirmation mismatch"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

normalize_disk_id() {
  printf '%s' "$1" | sed 's/^0x//' | tr 'A-F' 'a-f'
}

detect_target_disk_id() {
  local id=""
  if command -v sfdisk >/dev/null 2>&1; then
    id=$(sfdisk --disk-id "$TARGET_DISK" 2>/dev/null | sed 's/^0x//' || true)
  fi
  if [ -z "$id" ] && command -v lsblk >/dev/null 2>&1; then
    id=$(lsblk -dn -o PTUUID "$TARGET_DISK" 2>/dev/null | awk 'NF {print; exit}' || true)
  fi
  if [ -z "$id" ] && command -v blkid >/dev/null 2>&1; then
    id=$(blkid -o value -s PTUUID "$TARGET_DISK" 2>/dev/null || true)
  fi
  [ -n "$id" ] || die "could not determine disk ID for $TARGET_DISK"
  TARGET_DISK_ID=$(normalize_disk_id "$id")
}

write_state() {
  mkdir -p "$WORK_DIR"
  chmod 0700 "$WORK_DIR"
  {
    printf 'IMAGE_URL=%s\n' "$(shell_quote "$IMAGE_URL")"
    printf 'IMAGE_SHA256=%s\n' "$(shell_quote "$IMAGE_SHA256")"
    printf 'IMAGE_FORMAT=%s\n' "$(shell_quote "$IMAGE_FORMAT")"
    printf 'TARGET_DISK_HINT=%s\n' "$(shell_quote "$TARGET_DISK")"
    printf 'TARGET_DISK_ID=%s\n' "$(shell_quote "$TARGET_DISK_ID")"
    printf 'HOSTNAME=%s\n' "$(shell_quote "$HOSTNAME")"
    printf 'ROOT_PASSWORD_HASH=%s\n' "$(shell_quote "$ROOT_PASSWORD_HASH")"
  } >"$STATE_FILE"
  chmod 0600 "$STATE_FILE"
}

make_password_hash() {
  if command -v openssl >/dev/null 2>&1; then
    ROOT_PASSWORD_HASH=$(printf '%s\n' "$ROOT_PASSWORD" | openssl passwd -6 -stdin)
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    ROOT_PASSWORD_HASH=$(
      printf '%s\n' "$ROOT_PASSWORD" |
        python3 -c 'import crypt, random, string, sys; password = sys.stdin.readline().rstrip("\n"); salt = "".join(random.choice(string.ascii_letters + string.digits) for _ in range(16)); print(crypt.crypt(password, "$6$" + salt + "$"))'
    )
    return
  fi
  die "need openssl or python3 to generate root password hash"
}

default_ifaces() {
  ip -4 route show default 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "dev" && (i + 1) <= NF) print $(i + 1)}'
  ip -6 route show default 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "dev" && (i + 1) <= NF) print $(i + 1)}'
}

first_up_iface() {
  ip -o link show up 2>/dev/null |
    awk -F': ' '$2 != "lo" {sub(/@.*/, "", $2); print $2; exit}'
}

dns_lines() {
  {
    if command -v resolvectl >/dev/null 2>&1; then
      resolvectl dns 2>/dev/null |
        awk '{
          for (i = 2; i <= NF; i++) {
            value = $i
            sub(/,$/, "", value)
            if (value ~ /^[0-9][0-9.]*[0-9]$/ && value ~ /\./) print value
            else if (value ~ /:/ && value ~ /^[0-9A-Fa-f:.%_-]+$/) print value
          }
        }'
    fi
    if [ -r /etc/resolv.conf ]; then
      awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf
    fi
  } |
    awk '
      $0 ~ /^127\./ {next}
      $0 == "::1" {next}
      $0 == "0.0.0.0" {next}
      $0 == "::" {next}
      NF && !seen[$0]++ {print "DNS="$0}
    '
}

emit_networkd_routes() {
  local ver=$1 dev=$2 dest
  if [ "$ver" = 4 ]; then
    dest=0.0.0.0/0
  else
    dest=::/0
  fi
  ip "-$ver" route show default 2>/dev/null |
    awk -v d="$dev" -v dest="$dest" -v ver="$ver" '
      {
        hasdev = 0
        gw = ""
        metric = ""
        pref = ""
        src = ""
        for (i = 1; i <= NF; i++) {
          if ($i == "dev" && (i + 1) <= NF && $(i + 1) == d) hasdev = 1
          if ($i == "via" && (i + 1) <= NF) gw = $(i + 1)
          if ($i == "metric" && (i + 1) <= NF) metric = $(i + 1)
          if ($i == "pref" && (i + 1) <= NF) pref = $(i + 1)
          if ($i == "src" && (i + 1) <= NF) src = $(i + 1)
        }
        if (hasdev) {
          print ""
          print "[Route]"
          print "Destination=" dest
          if (gw != "") {
            print "Gateway=" gw
            print "GatewayOnLink=yes"
          }
          if (metric != "") print "Metric=" metric
          if (src != "") print "PreferredSource=" src
          if (ver == "6" && (pref == "high" || pref == "medium" || pref == "low")) print "IPv6Preference=" pref
        }
      }
    '
}

emit_networkd_file() {
  local dev=$1 mac mtu dns
  mac=$(cat "/sys/class/net/$dev/address")
  mtu=$(cat "/sys/class/net/$dev/mtu" 2>/dev/null || true)

  cat <<EOF
# Generated by $PROGRAM
# Source interface: $dev

[Match]
MACAddress=$mac

[Link]
MTUBytes=$mtu

[Network]
IPv6AcceptRA=yes
EOF

  dns=$(dns_lines || true)
  if [ -n "$dns" ]; then
    printf '%s\n' "$dns"
  else
    printf '%s\n' 'DNS=1.1.1.1' 'DNS=2606:4700:4700::1111'
  fi

  ip -o -4 addr show dev "$dev" scope global 2>/dev/null | awk '{print "Address="$4}'
  ip -o -6 addr show dev "$dev" scope global 2>/dev/null |
    awk '$0 !~ / temporary / && $0 !~ / tentative / && $0 !~ / deprecated / {print "Address="$4}'

  cat <<'EOF'

[IPv6AcceptRA]
UseDNS=yes
UseGateway=yes
EOF

  emit_networkd_routes 4 "$dev"
  emit_networkd_routes 6 "$dev"
}

write_fallback_networkd() {
  cat >"$NETWORK_DIR/90-dhcp-fallback.network" <<'EOF'
[Match]
Name=*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseRoutes=yes

[IPv6AcceptRA]
UseDNS=yes
UseGateway=yes
EOF
  chmod 0644 "$NETWORK_DIR/90-dhcp-fallback.network"
}

stage2_route_commands() {
  local ver=$1 dev=$2
  ip "-$ver" route show default 2>/dev/null |
    awk -v d="$dev" -v ver="$ver" '
      {
        hasdev = 0
        gw = ""
        metric = ""
        src = ""
        for (i = 1; i <= NF; i++) {
          if ($i == "dev" && (i + 1) <= NF && $(i + 1) == d) hasdev = 1
          if ($i == "via" && (i + 1) <= NF) gw = $(i + 1)
          if ($i == "metric" && (i + 1) <= NF) metric = $(i + 1)
          if ($i == "src" && (i + 1) <= NF) src = $(i + 1)
        }
        if (hasdev && gw != "") {
          if (metric == "") metric = "100"
          if (ver == "4") {
            printf "  ip -4 route replace %s/32 dev \"$dev\" 2>/dev/null || true\n", gw
            printf "  ip -4 route replace default via %s dev \"$dev\" metric %s", gw, metric
          } else {
            printf "  ip -6 route replace %s/128 dev \"$dev\" 2>/dev/null || true\n", gw
            printf "  ip -6 route replace default via %s dev \"$dev\" metric %s", gw, metric
          }
          if (src != "") printf " src %s", src
          printf " 2>/dev/null || "
          if (ver == "4") {
            printf "ip -4 route replace default via %s dev \"$dev\" onlink metric %s", gw, metric
          } else {
            printf "ip -6 route replace default via %s dev \"$dev\" onlink metric %s", gw, metric
          }
          if (src != "") printf " src %s", src
          printf " || true\n"
        }
      }
    '
}

append_stage2_iface_config() {
  local dev=$1 mac mtu
  mac=$(cat "/sys/class/net/$dev/address")
  mtu=$(cat "/sys/class/net/$dev/mtu" 2>/dev/null || true)

  {
    printf 'dev=$(find_iface_by_mac %s || true)\n' "$(shell_quote "$mac")"
    printf 'if [ -n "$dev" ]; then\n'
    printf '  ip link set dev "$dev" up || true\n'
    [ -n "$mtu" ] && printf '  ip link set dev "$dev" mtu %s || true\n' "$mtu"
    ip -o -4 addr show dev "$dev" scope global 2>/dev/null |
      awk '{printf "  ip -4 addr add %s dev \"$dev\" 2>/dev/null || true\n", $4}'
    ip -o -6 addr show dev "$dev" scope global 2>/dev/null |
      awk '$0 !~ / temporary / && $0 !~ / tentative / && $0 !~ / deprecated / {printf "  ip -6 addr add %s dev \"$dev\" 2>/dev/null || true\n", $4}'
    stage2_route_commands 4 "$dev"
    stage2_route_commands 6 "$dev"
    printf 'fi\n\n'
  } >>"$STAGE2_DIR/configure-network.sh"
}

write_stage2_network_script() {
  rm -rf "$STAGE2_DIR"
  mkdir -p "$STAGE2_DIR"
  cat >"$STAGE2_DIR/configure-network.sh" <<'EOF'
#!/bin/sh
set -eu

find_iface_by_mac() {
  want=$1
  for path in /sys/class/net/*; do
    dev=${path##*/}
    [ "$dev" != lo ] || continue
    [ -r "$path/address" ] || continue
    mac=$(cat "$path/address")
    if [ "$mac" = "$want" ]; then
      printf '%s\n' "$dev"
      return 0
    fi
  done
  return 1
}

ip link set lo up || true
modprobe ipv6 2>/dev/null || true
EOF
}

finish_stage2_network_script() {
  {
    printf 'cat >/etc/resolv.conf <<'\''RESOLV_EOF'\''\n'
    resolvers=$(dns_lines || true)
    if [ -n "$resolvers" ]; then
      printf '%s\n' "$resolvers" | sed 's/^DNS=/nameserver /'
    else
      printf '%s\n' 'nameserver 1.1.1.1'
      printf '%s\n' 'nameserver 2606:4700:4700::1111'
    fi
    printf 'RESOLV_EOF\n'
  } >>"$STAGE2_DIR/configure-network.sh"
  chmod 0755 "$STAGE2_DIR/configure-network.sh"
}

collect_network() {
  mkdir -p "$NETWORK_DIR"
  rm -f "$NETWORK_DIR"/*.network
  write_fallback_networkd
  write_stage2_network_script

  local ifaces="" dev clean name
  while IFS= read -r dev; do
    clean=${dev%%@*}
    [ -n "$clean" ] || continue
    [ "$clean" != lo ] || continue
    [ -e "/sys/class/net/$clean/address" ] || continue
    case " $ifaces " in
      *" $clean "*) ;;
      *) ifaces="$ifaces $clean" ;;
    esac
  done < <(default_ifaces)

  if [ -z "$ifaces" ]; then
    dev=$(first_up_iface || true)
    [ -n "$dev" ] && ifaces=" $dev"
  fi
  [ -n "$ifaces" ] || die "could not find a usable network interface"

  for dev in $ifaces; do
    name=$(printf '%s\n' "$dev" | sed 's/[^A-Za-z0-9_.-]/_/g')
    emit_networkd_file "$dev" >"$NETWORK_DIR/10-target-$name.network"
    chmod 0644 "$NETWORK_DIR/10-target-$name.network"
    append_stage2_iface_config "$dev"
  done
  finish_stage2_network_script
}

write_stage2_runner() {
  mkdir -p "$STAGE2_DIR"
  cat >"$STAGE2_DIR/run" <<'EOF'
#!/bin/bash
set -Eeuo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
STAGE2_ROOT=/archdd-stage2
LOG=/archdd-stage2/stage2.log
mkdir -p "$STAGE2_ROOT"
if [ -w /dev/tty0 ]; then
  exec > >(tee -a "$LOG" /dev/tty0) 2>&1
else
  exec > >(tee -a "$LOG" /dev/console) 2>&1
fi

die() {
  echo "ERROR: $*" >&2
  emergency_shell
}

info() {
  echo "INFO: $*"
}

emergency_shell() {
  echo "Dropping to emergency shell on console. The disk may be partially written."
  exec /bin/bash
}

trap 'die "stage2 failed at line $LINENO"' ERR

source "$STAGE2_ROOT/state.env"

cleanup_oldroot() {
  info "detaching old root"
  umount -R /oldroot 2>/dev/null || umount -l /oldroot 2>/dev/null || true
}

normalize_disk_id() {
  printf '%s' "$1" | sed 's/^0x//' | tr 'A-F' 'a-f'
}

disk_id_for() {
  local disk=$1 id=""
  if command -v sfdisk >/dev/null 2>&1; then
    id=$(sfdisk --disk-id "$disk" 2>/dev/null | sed 's/^0x//' || true)
  fi
  if [ -z "$id" ] && command -v lsblk >/dev/null 2>&1; then
    id=$(lsblk -dn -o PTUUID "$disk" 2>/dev/null | awk 'NF {print; exit}' || true)
  fi
  if [ -z "$id" ] && command -v blkid >/dev/null 2>&1; then
    id=$(blkid -o value -s PTUUID "$disk" 2>/dev/null || true)
  fi
  normalize_disk_id "$id"
}

find_target_disk() {
  local i disk id
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    for disk in /dev/nvme*n* /dev/vd* /dev/sd* /dev/xvd*; do
      [ -b "$disk" ] || continue
      [ "$(lsblk -dn -o TYPE "$disk" 2>/dev/null || true)" = disk ] || continue
      id=$(disk_id_for "$disk")
      if [ -n "$id" ] && [ "$id" = "$TARGET_DISK_ID" ]; then
        printf '%s\n' "$disk"
        return 0
      fi
    done
    sleep 1
  done
  return 1
}

ensure_stage2_tools() {
  local pkgs=""
  for cmd in bash curl dd sha256sum tee awk sed grep ip lsblk blkid mount umount chroot; do
    command -v "$cmd" >/dev/null 2>&1 || pkgs="$pkgs $cmd"
  done
  command -v zstd >/dev/null 2>&1 || pkgs="$pkgs zstd"
  command -v partprobe >/dev/null 2>&1 || pkgs="$pkgs parted"
  command -v sfdisk >/dev/null 2>&1 || pkgs="$pkgs util-linux"
  if [ -n "$pkgs" ]; then
    apk add --no-cache bash curl coreutils iproute2 util-linux parted e2fsprogs zstd
  fi
}

download_and_write() {
  local hash_pipe=/tmp/archdd.hash.pipe
  local hash_file=/tmp/archdd.sha256
  local target_disk=$1
  local curl_args=(-fL --connect-timeout 20 --retry 10 --retry-delay 5)
  rm -f "$hash_pipe" "$hash_file"

  info "writing image to $target_disk"
  if [ -n "$IMAGE_SHA256" ]; then
    mkfifo "$hash_pipe"
    sha256sum <"$hash_pipe" >"$hash_file" &
    hash_pid=$!
    if [ "$IMAGE_FORMAT" = zst ]; then
      curl "${curl_args[@]}" "$IMAGE_URL" | tee "$hash_pipe" | zstd -dc | dd of="$target_disk" bs=16M conv=fsync status=progress
    else
      curl "${curl_args[@]}" "$IMAGE_URL" | tee "$hash_pipe" | dd of="$target_disk" bs=16M conv=fsync status=progress
    fi
    wait "$hash_pid"
    got=$(awk '{print $1}' "$hash_file")
    [ "$got" = "$IMAGE_SHA256" ] || die "image sha256 mismatch: got $got expected $IMAGE_SHA256"
  else
    if [ "$IMAGE_FORMAT" = zst ]; then
      curl "${curl_args[@]}" "$IMAGE_URL" | zstd -dc | dd of="$target_disk" bs=16M conv=fsync status=progress
    else
      curl "${curl_args[@]}" "$IMAGE_URL" | dd of="$target_disk" bs=16M conv=fsync status=progress
    fi
  fi
  sync
}

find_new_root_part() {
  local target_disk=$1
  local part i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    part=$(lsblk -nrpo NAME,TYPE,FSTYPE,LABEL "$target_disk" 2>/dev/null | awk '$2 == "part" && $4 == "archroot" {print $1; exit}')
    if [ -n "$part" ]; then
      printf '%s\n' "$part"
      return 0
    fi
    part=$(lsblk -nrpo NAME,TYPE,FSTYPE "$target_disk" 2>/dev/null | awk '$2 == "part" && ($3 == "ext4" || $3 == "xfs" || $3 == "btrfs") {print $1}' | tail -n 1)
    if [ -n "$part" ]; then
      printf '%s\n' "$part"
      return 0
    fi
    sleep 1
  done
  return 1
}

inject_installed_system() {
  local root_part=$1 mnt=/mnt/archdd-newroot
  mkdir -p "$mnt"
  if mountpoint -q "$mnt"; then
    umount -R "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
  fi
  mount "$root_part" "$mnt"
  [ -d "$mnt/etc" ] || die "mounted root has no /etc: $root_part"
  [ -x "$mnt/bin/bash" ] || die "mounted root has no executable /bin/bash: $root_part"

  info "injecting network and ssh config into $root_part"
  mkdir -p "$mnt/etc/systemd/network" "$mnt/etc/ssh/sshd_config.d"
  rm -f "$mnt/etc/systemd/network"/*.network
  cp -a "$STAGE2_ROOT"/networkd/*.network "$mnt/etc/systemd/network/"
  chmod 0644 "$mnt/etc/systemd/network"/*.network

  printf '%s\n' "$HOSTNAME" >"$mnt/etc/hostname"

  cat >"$mnt/etc/ssh/sshd_config.d/01-root-password.conf" <<'SSHD_EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PubkeyAuthentication yes
UsePAM yes
SSHD_EOF

  if [ -f "$mnt/etc/ssh/sshd_config" ] &&
     ! head -n 1 "$mnt/etc/ssh/sshd_config" | grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf'; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$mnt/etc/ssh/sshd_config"
  elif [ ! -f "$mnt/etc/ssh/sshd_config" ]; then
    printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf' >"$mnt/etc/ssh/sshd_config"
  fi

  if [ -f "$mnt/etc/shadow" ]; then
    awk -F: -v hash="$ROOT_PASSWORD_HASH" 'BEGIN {OFS=FS} $1 == "root" {$2 = hash} {print}' "$mnt/etc/shadow" >"$mnt/etc/shadow.archdd"
    chmod 000 "$mnt/etc/shadow.archdd"
    mv "$mnt/etc/shadow.archdd" "$mnt/etc/shadow"
  else
    die "installed system has no /etc/shadow"
  fi

  if [ -f "$STAGE2_ROOT/authorized_keys" ]; then
    mkdir -p "$mnt/root/.ssh"
    cp -a "$STAGE2_ROOT/authorized_keys" "$mnt/root/.ssh/authorized_keys"
    chmod 0700 "$mnt/root/.ssh"
    chmod 0600 "$mnt/root/.ssh/authorized_keys"
  fi

  mkdir -p "$mnt/dev" "$mnt/proc" "$mnt/sys" "$mnt/run/sshd"
  mount --bind /dev "$mnt/dev" || true
  mount --bind /proc "$mnt/proc" || true
  mount --bind /sys "$mnt/sys" || true
  chroot "$mnt" /bin/bash -c '
ssh-keygen -A || true
command -v sshd >/dev/null 2>&1 || exit 1
sshd -t
for svc in sshd systemd-networkd systemd-resolved systemd-timesyncd grow-rootfs-once.service; do
  systemctl enable "$svc" 2>/dev/null || true
done
'
  umount -R "$mnt/sys" 2>/dev/null || true
  umount -R "$mnt/proc" 2>/dev/null || true
  umount -R "$mnt/dev" 2>/dev/null || true

  sync
  umount "$mnt"
}

main() {
  local target_disk root_part
  info "stage2 started"
  /bin/bash "$STAGE2_ROOT/configure-network.sh" || true
  ensure_stage2_tools
  cleanup_oldroot
  target_disk=$(find_target_disk) || die "target disk with id $TARGET_DISK_ID not found; old hint was $TARGET_DISK_HINT"
  info "target disk resolved: $target_disk (old hint: $TARGET_DISK_HINT, id: $TARGET_DISK_ID)"
  download_and_write "$target_disk"
  blockdev --rereadpt "$target_disk" 2>/dev/null || true
  partprobe "$target_disk" 2>/dev/null || true
  sleep 3
  root_part=$(find_new_root_part "$target_disk") || die "could not locate installed root partition"
  inject_installed_system "$root_part"
  sync
  info "Arch DD complete; rebooting"
  sleep 3
  sync
  echo 1 >/proc/sys/kernel/sysrq 2>/dev/null || true
  echo b >/proc/sysrq-trigger 2>/dev/null || reboot -f || true
  sleep 30
}

main "$@"
EOF
  chmod 0755 "$STAGE2_DIR/run"
}

environment_checks() {
  need_cmd awk
  need_cmd sed
  need_cmd ip
  need_cmd lsblk
  need_cmd findmnt
  need_cmd blkid
  need_cmd curl
  need_cmd cpio
  need_cmd gzip
  need_cmd zcat
  need_cmd find
  if [ "$(uname -m)" != x86_64 ] && [ "$FORCE" != 1 ]; then
    die "this first version expects x86_64 target runtime; use --force only if the image and boot path are compatible"
  fi
}

find_grub_tools() {
  if command -v grub-mkconfig >/dev/null 2>&1; then
    GRUB_MKCONFIG=$(command -v grub-mkconfig)
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    GRUB_MKCONFIG=$(command -v grub2-mkconfig)
  else
    die "missing grub-mkconfig/grub2-mkconfig"
  fi

  if command -v grub-reboot >/dev/null 2>&1; then
    GRUB_REBOOT=$(command -v grub-reboot)
  elif command -v grub2-reboot >/dev/null 2>&1; then
    GRUB_REBOOT=$(command -v grub2-reboot)
  else
    die "missing grub-reboot/grub2-reboot"
  fi

  if [ -f /boot/grub/grub.cfg ]; then
    GRUB_CFG=/boot/grub/grub.cfg
  elif [ -f /boot/grub2/grub.cfg ]; then
    GRUB_CFG=/boot/grub2/grub.cfg
  else
    GRUB_CFG=$(find /boot/efi/EFI -maxdepth 2 -type f -name grub.cfg 2>/dev/null | head -n 1 || true)
  fi
  [ -n "$GRUB_CFG" ] || die "could not locate grub.cfg"
}

build_initramfs() {
  rm -rf "$INITRAMFS_TREE" "$INITRD_IMAGE"
  mkdir -p "$INITRAMFS_TREE" "$WORK_DIR"

  info "downloading Alpine netboot kernel"
  curl -fL --connect-timeout 20 --retry 5 --retry-delay 3 -o "$ALPINE_KERNEL_IMAGE.tmp" "$ALPINE_KERNEL_URL"
  mv -f "$ALPINE_KERNEL_IMAGE.tmp" "$ALPINE_KERNEL_IMAGE"
  chmod 0644 "$ALPINE_KERNEL_IMAGE"

  info "downloading Alpine netboot initramfs"
  curl -fL --connect-timeout 20 --retry 5 --retry-delay 3 -o "$ALPINE_INITRD_DOWNLOAD.tmp" "$ALPINE_INITRD_URL"
  mv -f "$ALPINE_INITRD_DOWNLOAD.tmp" "$ALPINE_INITRD_DOWNLOAD"

  (cd "$INITRAMFS_TREE" && zcat "$ALPINE_INITRD_DOWNLOAD" | cpio -idm --quiet)

  mkdir -p "$INITRAMFS_TREE/archdd-stage2"
  cp -a "$STAGE2_DIR/configure-network.sh" "$INITRAMFS_TREE/archdd-stage2/configure-network.sh"
  cp -a "$STAGE2_DIR/run" "$INITRAMFS_TREE/archdd-stage2/run"
  cp -a "$NETWORK_DIR" "$INITRAMFS_TREE/archdd-stage2/networkd"
  cp -a "$STATE_FILE" "$INITRAMFS_TREE/archdd-stage2/state.env"
  if [ -n "$PUBLIC_KEY_FILE" ]; then
    cp -a "$PUBLIC_KEY_FILE" "$INITRAMFS_TREE/archdd-stage2/authorized_keys"
    chmod 0600 "$INITRAMFS_TREE/archdd-stage2/authorized_keys"
  fi

  awk '
    /^configure_ip\(\) \{/ {
      print
      print "\tif /bin/sh /archdd-stage2/configure-network.sh >/dev/console 2>&1; then"
      print "\t\tif ip route show default 2>/dev/null | grep -q . || ip -6 route show default 2>/dev/null | grep -q .; then"
      print "\t\t\techo \"archdd: using captured network\" >/dev/console 2>&1 || true"
      print "\t\t\tMAC_ADDRESS=archdd"
      print "\t\t\treturn"
      print "\t\tfi"
      print "\tfi"
      next
    }
    /^exec switch_root / || /^exec \/bin\/busybox switch_root / {
      print "\tif [ -d /archdd-stage2 ]; then"
      print "\t\tmkdir -p \"$sysroot/archdd-stage2\" \"$sysroot/etc/local.d\" \"$sysroot/etc/runlevels/default\""
      print "\t\tcp -a /archdd-stage2/. \"$sysroot/archdd-stage2/\""
      print "\t\tcp /archdd-stage2/run \"$sysroot/etc/local.d/archdd.start\""
      print "\t\tchmod +x \"$sysroot/etc/local.d/archdd.start\" \"$sysroot/archdd-stage2/run\""
      print "\t\tln -sf /etc/init.d/local \"$sysroot/etc/runlevels/default/local\""
      print "\tfi"
    }
    { print }
  ' "$INITRAMFS_TREE/init" >"$INITRAMFS_TREE/init.archdd"
  mv -f "$INITRAMFS_TREE/init.archdd" "$INITRAMFS_TREE/init"
  chmod 0755 "$INITRAMFS_TREE/init" "$INITRAMFS_TREE/archdd-stage2/run" "$INITRAMFS_TREE/archdd-stage2/configure-network.sh"

  (cd "$INITRAMFS_TREE" && find . | cpio --quiet -o -H newc -R 0:0 | gzip -1 >"$INITRD_IMAGE.tmp")
  mv -f "$INITRD_IMAGE.tmp" "$INITRD_IMAGE"
  chmod 0600 "$INITRD_IMAGE"
}

boot_relative_path() {
  local abs=$1 boot_target
  boot_target=$(findmnt -n -T /boot -o TARGET 2>/dev/null || true)
  if [ "$boot_target" = /boot ]; then
    printf '/%s\n' "${abs#/boot/}"
  else
    printf '%s\n' "$abs"
  fi
}

install_boot_files() {
  [ -n "$GRUB_CFG" ] && [ -f "$GRUB_CFG" ] && cp -f "$GRUB_CFG" "$WORK_DIR/grub.cfg.backup"
  cp -f "$ALPINE_KERNEL_IMAGE" "$BOOT_KERNEL"
  cp -f "$INITRD_IMAGE" "$BOOT_INITRD"
  chmod 0644 "$BOOT_KERNEL" "$BOOT_INITRD"
}

write_grub_entry() {
  local kernel_path initrd_path
  find_grub_tools
  kernel_path=$(boot_relative_path "$BOOT_KERNEL")
  initrd_path=$(boot_relative_path "$BOOT_INITRD")

  cat >"$GRUB_SNIPPET" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry 'archdd-oneclick' --id archdd-oneclick {
    linux $kernel_path alpine_repo=$ALPINE_REPO_URL modloop=$ALPINE_MODLOOP_URL pkgs=$ALPINE_PKGS modules=loop,squashfs,ipv6,sd-mod,sr-mod,usb-storage,virtio_pci,virtio_blk,virtio_scsi,virtio_net,nvme,ahci,xhci_pci,ehci_pci,uhci_hcd,ext4 console=ttyS0,115200n8 console=tty0
    initrd $initrd_path
}
EOF
  chmod 0755 "$GRUB_SNIPPET"

  "$GRUB_MKCONFIG" -o "$GRUB_CFG"
  "$GRUB_REBOOT" archdd-oneclick
}

main() {
  parse_args "$@"
  validate_args
  confirm_wipe
  environment_checks
  detect_target_disk_id
  make_password_hash
  collect_network
  write_stage2_runner
  write_state
  info "$PROGRAM $VERSION prepared network capture under $NETWORK_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    sh -n "$STAGE2_DIR/configure-network.sh"
    bash -n "$STAGE2_DIR/run"
    info "dry-run complete; no boot entry was written"
    exit 0
  fi
  build_initramfs
  if [ "$PREPARE_ONLY" = 1 ]; then
    info "prepare-only complete; initramfs built at $INITRD_IMAGE"
    info "no boot files, GRUB entry, reboot, or DD action was performed"
    exit 0
  fi
  find_grub_tools
  install_boot_files
  write_grub_entry
  info "prepared one-time GRUB entry archdd-oneclick"
  if [ "$REBOOT_AFTER_PREPARE" = 1 ]; then
    info "rebooting now"
    reboot
  else
    info "not rebooting; run 'reboot' when ready to start DD"
  fi
}

main "$@"
