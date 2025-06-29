# uMini Build Script
# Version: 0.0.2-rc
# Author: Maksym Titenko
# Email: titenko.m@gmail.com
# Website: https://linuxmative.github.io/
# GitHub: https://github.com/linuxmative/uMini
# License: MIT
# Description:
#   This script builds a minimal Ubuntu-based Live ISO using debootstrap,
#   squashfs, and GRUB2 with support for BIOS and UEFI booting.
#
#   Features:
#   - Modular package sets for base, system, and live environments
#   - Clean chroot management with auto unmounting and logging
#   - Multiple fallback methods for ISO creation (grub-mkrescue, xorriso)
#   - Optional performance-enhancing dependencies (aria2, pigz, pbzip2)
#
#   Usage and Redistribution:
#   You are free to use and modify this script in your own projects.
#   However, proper credit to the original author must be clearly stated
#   in your source code or documentation.
#
# Copyright (c) Maksym Titenko

#!/bin/bash
set -euo pipefail

### Configuration
RELEASE="${RELEASE:-noble}"
ARCH="${ARCH:-amd64}"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
WORKDIR="${WORKDIR:-$(pwd)/uminibuild}"
CHROOTDIR="$WORKDIR/chroot"
ISODIR="$WORKDIR/iso"
IMAGENAME="uMini-${RELEASE}-$(date +%Y%m%d-%H%M).iso"
BUILD_THREADS="${BUILD_THREADS:-$(nproc)}"

# Build configuration
SQUASHFS_COMP="${SQUASHFS_COMP:-xz}"
SQUASHFS_BLOCK_SIZE="${SQUASHFS_BLOCK_SIZE:-1M}"
ISO_COMPRESSION="${ISO_COMPRESSION:-xz}"

# Suppress apt warnings
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export DEBCONF_NONINTERACTIVE_SEEN=true
export DEBCONF_NOWARNINGS=yes

REQUIRED_PACKAGES=(
  debootstrap xorriso syslinux-utils squashfs-tools grub-pc-bin grub-efi-amd64-bin mtools aria2
)

# Essential packages for debootstrap - absolute minimum
DEBOOTSTRAP_ESSENTIAL=(
  "apt" "dpkg" "gpg" "gnupg" "ca-certificates" "coreutils" "bash" "util-linux" "locales"
)

# Additional packages to install in chroot - organized by category
SYSTEM_PACKAGES=(
  # Network essentials
  "sudo" "wget" "curl" "netbase" "net-tools" "iproute2" "iputils-ping"
  
  # Boot and filesystem
  "grub-pc" "os-prober" "parted" "fdisk" "e2fsprogs"
  
  # Localization and keyboard
  "keyboard-configuration" "console-setup" "locales" "debconf"
  
  # System utilities
  "bind9-utils" "cpio" "cron" "dmidecode" "dosfstools" "ed" "file" "ftp"
  "hdparm" "logrotate" "lshw" "lsof" "man-db" "media-types" "nftables"
  "pciutils" "psmisc" "rsync" "strace" "time" "usbutils" "xz-utils" "zstd"
  
  # Text editor
  "nano"
)

LIVE_SYSTEM_PACKAGES=(
  # Kernel (укажи версию явно, если нужно)
  "linux-image-generic" "linux-headers-generic"

  # Live boot
  "live-boot" "live-boot-initramfs-tools" "casper"
  "initramfs-tools"

  # Init + udev
  "systemd" "systemd-sysv" "libpam-systemd" "udev" "uuid-runtime"

  # GRUB utilities only
  "grub-common" "grub-pc-bin" "grub-efi-amd64-bin"

  # OverlayFS, BusyBox
  "overlayroot" "busybox-initramfs" "cryptsetup-initramfs"

  # HW tools
  "pciutils" "usbutils" "lshw" "hwdata" "dmidecode"

  # Live config
  "live-tools" "live-config" "live-config-systemd"

  # Network
  "iwd" "systemd-resolved" "net-tools" "iproute2"

  # CLI utils
  "bash-completion" "apt-file" "command-not-found" "less" "nano"
)

# Utilities with improved error handling
log() {
  echo -e "[\e[1;34m$(date '+%H:%M:%S')\e[0m] $1"
}

warn() {
  echo -e "[\e[1;33mWARN\e[0m] $1" >&2
}

err() {
  echo -e "[\e[1;31mERROR\e[0m] $1" >&2
}

success() {
  echo -e "[\e[1;32mSUCCESS\e[0m] $1"
}

# Improved cleanup with better error handling
cleanup() {
  if [[ "${CLEANUP_RUNNING:-}" == "1" ]]; then return; fi
  CLEANUP_RUNNING=1
  log "Starting cleanup process..."
  
  if [[ -n "${CHROOTDIR:-}" && -d "$CHROOTDIR" ]]; then
    # Improved unmounting with timeout and fallback
    local mount_points=("dev/pts" "proc" "sys" "run" "dev")
    for mp in "${mount_points[@]}"; do
      local full_path="$CHROOTDIR/$mp"
      if mountpoint -q "$full_path" 2>/dev/null; then
        log "Unmounting $full_path"
        if ! timeout 10 sudo umount "$full_path" 2>/dev/null; then
          warn "Normal unmount failed for $full_path, trying lazy unmount"
          sudo umount -l "$full_path" 2>/dev/null || true
        fi
      fi
    done
    
    # Kill any remaining processes in chroot
    if command -v lsof >/dev/null 2>&1; then
      sudo lsof +D "$CHROOTDIR" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | xargs -r sudo kill -9 2>/dev/null || true
    fi
  fi
  
  # Conditional cleanup of work directory
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" && "$WORKDIR" != "/" && "$WORKDIR" != "$HOME" ]]; then
    if [[ "${PRESERVE_WORKDIR:-}" != "1" ]]; then
      log "Removing work directory: $WORKDIR"
      sudo rm -rf "$WORKDIR"
    else
      log "Preserving work directory as requested: $WORKDIR"
    fi
  fi
}

# Enhanced error handling
handle_error() {
  local line_no=$1
  local exit_code=$2
  err "Script failed at line $line_no with exit code $exit_code"
  if [[ -f "$CHROOTDIR/tmp/chroot.log" ]]; then
    err "Last lines from chroot log:"
    tail -10 "$CHROOTDIR/tmp/chroot.log" 2>/dev/null || true
  fi
}

trap 'handle_error $LINENO $?' ERR
trap cleanup EXIT INT TERM

# Create apt configuration to suppress warnings
create_apt_config() {
  sudo mkdir -p /etc/apt/apt.conf.d/ 2>/dev/null || true
  sudo tee /etc/apt/apt.conf.d/99no-warnings >/dev/null <<EOF
APT::Get::Assume-Yes "true";
APT::Get::Fix-Broken "true";
DPkg::Options "--force-confold";
DPkg::Options "--force-confdef";
DPkg::Options "--force-overwrite";
Dpkg::Use-Pty "0";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF
}

# Improved dependency checking
check_dependencies() {
  log "Checking build dependencies..."
  local missing=()
  local optional_missing=()
  
  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      missing+=("$pkg")
    fi
  done
  
  # Check for optional but recommended packages
  for pkg in "aria2" "pigz" "pbzip2"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      optional_missing+=("$pkg")
    fi
  done
  
  if [[ ${#missing[@]} -ne 0 ]]; then
    log "Installing missing required packages: ${missing[*]}"
    create_apt_config
    sudo apt-get -qq update && sudo apt-get -qq install -y "${missing[@]}"
  fi
  
  if [[ ${#optional_missing[@]} -ne 0 ]]; then
    log "Optional packages not found (will improve performance): ${optional_missing[*]}"
    read -p "Install optional packages? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      sudo apt-get -qq install -y "${optional_missing[@]}"
    fi
  fi
}

# Enhanced timezone detection
detect_timezone() {
  local timezone=""
  
  # Method 1: timedatectl (most reliable)
  if command -v timedatectl >/dev/null 2>&1; then
    timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
  fi
  
  # Method 2: /etc/localtime symlink
  if [[ -z "$timezone" && -L /etc/localtime ]]; then
    timezone=$(readlink /etc/localtime | sed 's|^.*/zoneinfo/||')
  fi
  
  # Method 3: /etc/timezone file
  if [[ -z "$timezone" && -f /etc/timezone ]]; then
    timezone=$(cat /etc/timezone)
  fi
  
  # Validate timezone
  if [[ -n "$timezone" && -f "/usr/share/zoneinfo/$timezone" ]]; then
    echo "$timezone"
  else
    echo "UTC"
  fi
}

# Improved package list validation
validate_packages() {
  log "Validating package availability..."
  local all_packages=()
  all_packages+=("${DEBOOTSTRAP_ESSENTIAL[@]}")
  all_packages+=("${SYSTEM_PACKAGES[@]}")
  all_packages+=("${LIVE_SYSTEM_PACKAGES[@]}")
  
  # Remove duplicates
  local unique_packages=($(printf "%s\n" "${all_packages[@]}" | sort -u))
  
  # Create temporary sources.list for validation
  local temp_sources="/tmp/sources.list.$$"
  cat > "$temp_sources" <<EOF
deb $MIRROR $RELEASE main restricted universe multiverse
deb $MIRROR $RELEASE-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $RELEASE-security main restricted universe multiverse
EOF
  
  # Check package availability (sample check)
  log "Checking availability of critical packages..."
  for pkg in "linux-image-generic" "live-boot" "casper"; do
    if ! apt-cache --option Dir::Etc::SourceList="$temp_sources" search "^$pkg\$" >/dev/null 2>&1; then
      warn "Package $pkg might not be available for $RELEASE"
    fi
  done
  
  rm -f "$temp_sources"
  echo "${unique_packages[@]}"
}

# Optimized debootstrap with parallel downloads
run_debootstrap() {
  local include_list=$(IFS=,; echo "${DEBOOTSTRAP_ESSENTIAL[*]}")
  
  log "Creating minimal base system with debootstrap..."
  log "Essential packages: $include_list"
  
  # Use aria2 for faster downloads if available
  local debootstrap_opts="--arch=$ARCH --variant=minbase --include=$include_list"
  if command -v aria2c >/dev/null 2>&1; then
    export DEBOOTSTRAP_DOWNLOAD_OPTS="--continue --max-connection-per-server=5 --max-concurrent-downloads=5"
  fi
  
  sudo debootstrap $debootstrap_opts $RELEASE "$CHROOTDIR" "$MIRROR"
}

# Pre-ISO creation checks
check_iso_prerequisites() {
  log "Performing pre-ISO checks..."
  
  # Check if grub-mkrescue exists and works
  if ! command -v grub-mkrescue >/dev/null 2>&1; then
    err "grub-mkrescue not found. Install grub-common package."
    exit 1
  fi
  
  # Test grub-mkrescue basic functionality
  if ! grub-mkrescue --help >/dev/null 2>&1; then
    err "grub-mkrescue is not working properly"
    exit 1
  fi
  
  # Check required files exist
  local required_files=(
    "$ISODIR/casper/vmlinuz"
    "$ISODIR/casper/initrd.img"
    "$ISODIR/casper/filesystem.squashfs"
    "$ISODIR/boot/grub/grub.cfg"
  )
  
  for file in "${required_files[@]}"; do
    if [[ ! -f "$file" ]]; then
      err "Required file missing: $file"
      exit 1
    fi
    log "✓ Found: $(basename "$file") ($(du -h "$file" | cut -f1))"
  done
  
  # Check squashfs integrity
  if ! sudo unsquashfs -l "$ISODIR/casper/filesystem.squashfs" >/dev/null 2>&1; then
    err "Squashfs filesystem is corrupted"
    exit 1
  fi
  
  log "All pre-ISO checks passed"
}

# Create ISO with multiple fallback methods
create_iso() {
  log "Creating bootable ISO image..."

  # Check available disk space
  local available_space=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
  log "Available disk space: ${available_space}GB"

  if [[ $available_space -lt 2 ]]; then
    err "Insufficient disk space. Need at least 2GB free."
    exit 1
  fi

  # Method 1: Try grub-mkrescue with fixed volid syntax
  log "Attempting ISO creation with grub-mkrescue (method 1)..."
  if sudo grub-mkrescue -o "$IMAGENAME" "$ISODIR" \
    --compress="$ISO_COMPRESSION" \
    -- -volid UMINI_LIVE 2>&1 | tee /tmp/grub-mkrescue.log; then
    
    log "ISO created successfully with method 1"
    
  # Method 2: Try without volid
  elif sudo grub-mkrescue -o "$IMAGENAME" "$ISODIR" \
    --compress="$ISO_COMPRESSION" 2>&1 | tee /tmp/grub-mkrescue.log; then
    
    log "ISO created successfully with method 2 (no volid)"
    
  else
    # Method 3: Use xorriso directly
    warn "grub-mkrescue failed, trying direct xorriso approach..."
    
    if sudo xorriso -as mkisofs \
      -r -V "UMINI_LIVE" \
      -cache-inodes \
      -J -l \
      -o "$IMAGENAME" \
      "$ISODIR" 2>&1 | tee /tmp/xorriso.log; then
      
      log "ISO created successfully with xorriso method"
    else
      err "All ISO creation methods failed"
      cat /tmp/xorriso.log
      exit 1
    fi
  fi

  # Verify ISO was created
  if [[ ! -f "$IMAGENAME" ]]; then
    err "ISO file was not created: $IMAGENAME"
    exit 1
  fi

  local iso_size_bytes=$(stat -c%s "$IMAGENAME" 2>/dev/null || echo "0")
  if [[ $iso_size_bytes -lt 10485760 ]]; then  # Less than 10MB
    err "ISO file seems too small ($iso_size_bytes bytes), probably incomplete"
    exit 1
  fi

  sudo chown "$USER:$USER" "$IMAGENAME"
  chmod 644 "$IMAGENAME"

  log "ISO created successfully: $IMAGENAME ($(du -h "$IMAGENAME" | cut -f1))"
}

# Main execution flow
main() {
  local start_time=$(date +%s)
  
  # Pre-flight checks
  if [[ $EUID -eq 0 ]]; then
    err "Do not run this script as root! Use sudo only where necessary."
    exit 1
  fi
  
  if ! sudo -n true 2>/dev/null; then
    log "Sudo privileges required. Please enter your password:"
    sudo true
  fi
  
  # Configuration
  local host_timezone
  host_timezone=$(detect_timezone)
  log "Detected timezone: $host_timezone"
  
  check_dependencies
  
  log "Validating package lists..."
  local validated_packages
  readarray -t validated_packages < <(validate_packages)
  
  log "Creating working directories..."
  sudo mkdir -p "$CHROOTDIR" "$ISODIR"
  
  run_debootstrap
  
  # Configure chroot environment
  log "Configuring chroot environment..."
  
  # Preserve original resolv.conf
  [[ -f "$CHROOTDIR/etc/resolv.conf" ]] && sudo cp "$CHROOTDIR/etc/resolv.conf" "$CHROOTDIR/etc/resolv.conf.orig"
  sudo cp /etc/resolv.conf "$CHROOTDIR/etc/"
  
  # Mount pseudo-filesystems with better error handling
  local mount_points=("dev" "dev/pts" "proc" "sys" "run")
  for dir in "${mount_points[@]}"; do
    if ! mountpoint -q "$CHROOTDIR/$dir" 2>/dev/null; then
      sudo mkdir -p "$CHROOTDIR/$dir"
      sudo mount --bind "/$dir" "$CHROOTDIR/$dir"
    fi
  done
  
  # Prepare package lists
  local system_packages_str=$(IFS=' '; echo "${SYSTEM_PACKAGES[*]}")
  local live_packages_str=$(IFS=' '; echo "${LIVE_SYSTEM_PACKAGES[*]}")
  
  # Create configuration script outside chroot to avoid permission issues
  local config_script="/tmp/configure_chroot_$$.sh"
  
  cat > "$config_script" <<'SCRIPT_EOF'
#!/bin/bash
set -e
exec > >(tee /tmp/chroot.log) 2>&1

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export DEBCONF_NONINTERACTIVE_SEEN=true
export DEBCONF_NOWARNINGS=yes

echo "=== System Configuration Started ===" 
date

# Basic system setup
echo "uMini" > /etc/hostname
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8 LANGUAGE=en_US LC_ALL=en_US.UTF-8

# Timezone configuration
echo "Setting timezone to: $HOST_TIMEZONE"
ln -sfn "/usr/share/zoneinfo/$HOST_TIMEZONE" /etc/localtime
echo "$HOST_TIMEZONE" > /etc/timezone

# Hosts file
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
127.0.1.1	uMini
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
HOSTS

# Repository configuration
cat > /etc/apt/sources.list <<LIST
deb MIRROR_PLACEHOLDER RELEASE_PLACEHOLDER main restricted universe multiverse
deb MIRROR_PLACEHOLDER RELEASE_PLACEHOLDER-updates main restricted universe multiverse
deb MIRROR_PLACEHOLDER RELEASE_PLACEHOLDER-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu RELEASE_PLACEHOLDER-security main restricted universe multiverse
LIST

# Remove cdrom entries
sed -i '/^deb cdrom:/d' /etc/apt/sources.list

# Configure apt for faster downloads and suppress warnings
cat > /etc/apt/apt.conf.d/99parallel <<APT
APT::Acquire::Retries "3";
APT::Acquire::http::Timeout "10";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "en";
APT::Get::Assume-Yes "true";
DPkg::Options "--force-confold";
DPkg::Options "--force-confdef";
Dpkg::Use-Pty "0";
APT

# Update and install packages
echo "Updating package database..."
apt-get -qq update

echo "Installing system packages..."
if ! apt-get -qq install --no-install-recommends -y SYSTEM_PACKAGES_PLACEHOLDER; then
  echo "ERROR: Failed to install system packages" >&2
  exit 1
fi

echo "Installing live system packages..."
if ! apt-get -qq install --no-install-recommends -y LIVE_PACKAGES_PLACEHOLDER; then
  echo "ERROR: Failed to install live system packages" >&2
  exit 1
fi

# Verify critical components
echo "Verifying kernel installation..."
if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
  echo "ERROR: Kernel not installed properly"
  ls -la /boot/
  exit 1
fi

# User management
echo "Creating users..."
for user in umini ubuntu; do
  if ! id "$user" &>/dev/null; then
    adduser --disabled-password --gecos "" "$user"
    echo "$user:$user" | chpasswd
    usermod -aG sudo "$user"
  fi
done
echo "root:toor" | chpasswd

# Network configuration
echo "Configuring network..."
systemctl enable iwd systemd-networkd systemd-resolved

mkdir -p /etc/systemd/network/
cat > /etc/systemd/network/20-wired.network <<NET
[Match]
Name=en*

[Network]
DHCP=yes
NET

rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Autologin setup
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<AUTO
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ubuntu --noclear %I \$TERM
AUTO

# Welcome message
mkdir -p /etc/profile.d/
cat > /etc/profile.d/uminilive.sh <<WELCOME
#!/bin/bash
echo -e "\\e[1;32mWelcome to uMini Live!\\e[0m"
echo -e "Users: umini/umini, ubuntu/ubuntu, root/toor"
echo -e "To connect to Wi-Fi: sudo iwctl"
echo -e "Timezone: \\$(cat /etc/timezone)"
WELCOME
chmod +x /etc/profile.d/uminilive.sh

# Cleanup
echo "Cleaning up..."
apt-get -qq clean
apt-get -qq autoremove -y
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
rm -rf /var/cache/apt/* /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -rf /root/.cache /home/*/.cache 2>/dev/null || true

# Restore resolv.conf
[[ -f /etc/resolv.conf.orig ]] && mv /etc/resolv.conf.orig /etc/resolv.conf

echo "=== System Configuration Completed ==="
date
SCRIPT_EOF

  # Substitute placeholders with actual values
  sed -i "s|MIRROR_PLACEHOLDER|$MIRROR|g" "$config_script"
  sed -i "s|RELEASE_PLACEHOLDER|$RELEASE|g" "$config_script"
  sed -i "s|HOST_TIMEZONE|$host_timezone|g" "$config_script"
  sed -i "s|SYSTEM_PACKAGES_PLACEHOLDER|$system_packages_str|g" "$config_script"
  sed -i "s|LIVE_PACKAGES_PLACEHOLDER|$live_packages_str|g" "$config_script"
  
  chmod +x "$config_script"
  
  log "Running system configuration in chroot..."
  if ! sudo cp "$config_script" "$CHROOTDIR/tmp/configure_system.sh"; then
    err "Failed to copy configuration script to chroot"
    rm -f "$config_script"
    exit 1
  fi
  
  # Make script executable in chroot
  sudo chmod +x "$CHROOTDIR/tmp/configure_system.sh"
  
  if ! sudo chroot "$CHROOTDIR" /tmp/configure_system.sh; then
    err "Chroot configuration failed"
    [[ -f "$CHROOTDIR/tmp/chroot.log" ]] && tail -20 "$CHROOTDIR/tmp/chroot.log"
    rm -f "$config_script"
    exit 1
  fi
  
  # Clean up temporary script
  rm -f "$config_script"

  
  log "Updating initramfs..."
  sudo chroot "$CHROOTDIR" update-initramfs -u -k all
  
  # Copy kernel files
  log "Preparing boot files..."
  sudo mkdir -p "$ISODIR/casper"
  
  local kernel_files=($(sudo find "$CHROOTDIR/boot" -name "vmlinuz-*" -type f))
  if [[ ${#kernel_files[@]} -eq 0 ]]; then
    err "No kernel files found in chroot"
    exit 1
  fi
  
  local kernel_version=$(basename "${kernel_files[0]}" | sed 's/vmlinuz-//')
  log "Using kernel version: $kernel_version"
  
  sudo cp "$CHROOTDIR/boot/vmlinuz-$kernel_version" "$ISODIR/casper/vmlinuz"
  sudo cp "$CHROOTDIR/boot/initrd.img-$kernel_version" "$ISODIR/casper/initrd.img"
  
  # Unmount before creating squashfs
  log "Preparing for squashfs creation..."
  for mp in dev/pts proc sys run dev; do
    mountpoint -q "$CHROOTDIR/$mp" 2>/dev/null && sudo umount -l "$CHROOTDIR/$mp"
  done
  
  # Create optimized squashfs
  log "Creating compressed filesystem (this may take several minutes)..."
  local squashfs_opts="-comp $SQUASHFS_COMP -b $SQUASHFS_BLOCK_SIZE -processors $BUILD_THREADS"
  if command -v pigz >/dev/null 2>&1; then
    squashfs_opts="$squashfs_opts -Xcompression-level 6"
  fi
  
  sudo mksquashfs "$CHROOTDIR" "$ISODIR/casper/filesystem.squashfs" \
    -e boot $squashfs_opts -no-progress
  
  # Generate metadata
  log "Generating filesystem metadata..."
  local fs_size=$(sudo du -sb "$CHROOTDIR" | cut -f1)
  echo "$fs_size" | sudo tee "$ISODIR/casper/filesystem.size" >/dev/null
  
  sudo mkdir -p "$ISODIR/.disk"
  echo "uMini Live System - Built $(date)" | sudo tee "$ISODIR/.disk/info" >/dev/null
  echo "$(date -u +%Y%m%d-%H:%M)" | sudo tee "$ISODIR/.disk/casper-uuid" >/dev/null
  
  # Package manifests
  sudo chroot "$CHROOTDIR" dpkg-query -W --showformat='${Package} ${Version}\n' \
    | sudo tee "$ISODIR/casper/filesystem.manifest" >/dev/null
  sudo cp "$ISODIR/casper/filesystem.manifest" "$ISODIR/casper/filesystem.manifest-desktop"
  
  echo -e "live-boot\nlive-boot-initramfs-tools\ncasper\nlupin-casper" \
    | sudo tee "$ISODIR/casper/filesystem.manifest-remove" >/dev/null
  
  # GRUB configuration
  log "Creating bootloader configuration..."
  sudo mkdir -p "$ISODIR/boot/grub"
  cat <<GRUBCFG | sudo tee "$ISODIR/boot/grub/grub.cfg" >/dev/null
set timeout=10
set default=0

menuentry "Start uMini Live" {
    linux /casper/vmlinuz boot=casper quiet splash username=umini hostname=uMini
    initrd /casper/initrd.img
}

menuentry "Start uMini Live (Safe Graphics)" {
    linux /casper/vmlinuz boot=casper quiet splash username=umini hostname=uMini nomodeset
    initrd /casper/initrd.img
}

menuentry "Start uMini Live (Debug Mode)" {
    linux /casper/vmlinuz boot=casper debug username=umini hostname=uMini
    initrd /casper/initrd.img
}

menuentry "Memory Test (memtest86+)" {
    linux16 /boot/memtest86+.bin
}
GRUBCFG
  
  # Generate checksums
  log "Generating checksums..."
  (cd "$ISODIR" && find . -type f ! -name "md5sum.txt" -print0 \
    | sudo xargs -0 md5sum | sudo tee md5sum.txt >/dev/null)
  
# Create ISO with fixed parameters
log "Creating bootable ISO image..."

# Check available disk space
local available_space=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
log "Available disk space: ${available_space}GB"

if [[ $available_space -lt 2 ]]; then
  err "Insufficient disk space. Need at least 2GB free."
  exit 1
fi

# Method 1: Try with different volid format
log "Attempting ISO creation with grub-mkrescue..."
if sudo grub-mkrescue -o "$IMAGENAME" "$ISODIR" \
  --compress="$ISO_COMPRESSION" \
  -- -volid UMINI_LIVE 2>&1 | tee /tmp/grub-mkrescue.log; then
  
  log "ISO created successfully with method 1"
  
elif sudo grub-mkrescue -o "$IMAGENAME" "$ISODIR" \
  --compress="$ISO_COMPRESSION" 2>&1 | tee /tmp/grub-mkrescue.log; then
  
  log "ISO created successfully with method 2 (no volid)"
  
else
  # Method 3: Fall back to xorriso directly
  warn "grub-mkrescue failed, trying direct xorriso approach..."
  
  # Create temporary directory for GRUB files
  local temp_grub_dir=$(mktemp -d)
  
  # Copy GRUB boot files
  sudo mkdir -p "$temp_grub_dir/boot/grub"
  
  # Find GRUB files (different locations on different systems)
  local grub_files=""
  for grub_path in /usr/lib/grub/i386-pc /boot/grub/i386-pc /usr/share/grub; do
    if [[ -d "$grub_path" ]]; then
      grub_files="$grub_path"
      break
    fi
  done
  
  if [[ -n "$grub_files" ]]; then
    sudo cp -r "$grub_files"/* "$temp_grub_dir/boot/grub/" 2>/dev/null || true
  fi
  
  # Use xorriso directly with correct syntax
  log "Creating ISO with xorriso directly..."
  if sudo xorriso -as mkisofs \
    -r -V "UMINI_LIVE" \
    -cache-inodes \
    -J -l \
    -b boot/grub/i386-pc/eltorito.img \
    -c boot.catalog \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -o "$IMAGENAME" \
    "$ISODIR" 2>&1 | tee /tmp/xorriso.log; then
    
    log "ISO created successfully with xorriso method"
  else
    # Method 4: Minimal xorriso approach
    warn "Standard xorriso failed, trying minimal approach..."
    
    if sudo xorriso -as mkisofs \
      -r -V "UMINI_LIVE" \
      -o "$IMAGENAME" \
      "$ISODIR" 2>&1 | tee /tmp/xorriso-minimal.log; then
      
      log "ISO created with minimal xorriso method"
    else
      err "All ISO creation methods failed"
      cat /tmp/xorriso-minimal.log
      exit 1
    fi
  fi
  
  # Cleanup
  sudo rm -rf "$temp_grub_dir"
fi

# Verify ISO was created
if [[ ! -f "$IMAGENAME" ]]; then
  err "ISO file was not created: $IMAGENAME"
  exit 1
fi

local iso_size_bytes=$(stat -c%s "$IMAGENAME" 2>/dev/null || echo "0")
if [[ $iso_size_bytes -lt 10485760 ]]; then  # Less than 10MB
  err "ISO file seems too small ($iso_size_bytes bytes), probably incomplete"
  exit 1
fi

sudo chown "$USER:$USER" "$IMAGENAME"
chmod 644 "$IMAGENAME"

log "ISO created successfully: $IMAGENAME ($(du -h "$IMAGENAME" | cut -f1))"
  
  # Final statistics
  local end_time=$(date +%s)
  local build_time=$((end_time - start_time))
  local iso_size=$(du -h "$IMAGENAME" | cut -f1)
  local package_count=$(wc -l < "$ISODIR/casper/filesystem.manifest")
  
  success "ISO image created successfully!"
  
  cat <<SUMMARY

===============================
🎉 BUILD COMPLETED SUCCESSFULLY
===============================
📦 Filename:         $IMAGENAME
📁 Location:         $(realpath "$IMAGENAME")
📏 Size:             $iso_size
⏱️  Build time:       ${build_time}s ($((build_time / 60))m $((build_time % 60))s)
🧊 Compression:      SquashFS ($SQUASHFS_COMP) + ISO ($ISO_COMPRESSION)
🖥️ Architecture:     $ARCH
🗓️ Release:          $RELEASE
🌍 Timezone:         $host_timezone
📦 Packages:         $package_count installed
💽 Bootloader:       GRUB2 (BIOS + UEFI)
===============================

🧪 Test the ISO:
   qemu-system-x86_64 -m 2048 -cdrom $IMAGENAME -enable-kvm

🔧 Advanced test:
   qemu-system-x86_64 -m 2048 -cdrom $IMAGENAME -boot d -netdev user,id=net0 -device e1000,netdev=net0

===============================

SUMMARY
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
