#!/bin/bash
set -euo pipefail

### Configuration
RELEASE="noble"
ARCH="amd64"
MIRROR="http://archive.ubuntu.com/ubuntu"
WORKDIR="$(pwd)/uminibuild"
CHROOTDIR="$WORKDIR/chroot"
ISODIR="$WORKDIR/iso"
IMAGENAME="uMini-${RELEASE}-$(date +%Y%m%d).iso"

REQUIRED_PACKAGES=(
  debootstrap xorriso syslinux-utils squashfs-tools grub-pc-bin grub-efi-amd64-bin mtools
)

# Utilities
log() {
  echo -e "[\e[1;34mINFO\e[0m] $1"
}
err() {
  echo -e "[\e[1;31mERROR\e[0m] $1" >&2
}

cleanup() {
  if [[ "${CLEANUP_RUNNING:-}" == "1" ]]; then return; fi
  CLEANUP_RUNNING=1
  log "Cleaning up chroot and temporary directories..."
  if [[ -n "$CHROOTDIR" && -d "$CHROOTDIR" ]]; then
    # Fixed unmounting order - nested mount points first
    for mp in dev/pts proc sys run dev; do
      if mountpoint -q "$CHROOTDIR/$mp" 2>/dev/null; then
        sudo umount -lf "$CHROOTDIR/$mp" || true
      fi
    done
  fi
  if [[ -n "$WORKDIR" && -d "$WORKDIR" && "$WORKDIR" != "/" ]]; then
    sudo rm -rf "$WORKDIR"
  fi
}
trap 'err "An error occurred on line $LINENO"' ERR
trap cleanup EXIT INT TERM

# Check root/sudo permissions
if [[ $EUID -eq 0 ]]; then
  err "Do not run this script as root! Use sudo only where necessary."
  exit 1
fi

# Check sudo availability
if ! sudo -n true 2>/dev/null; then
  log "Sudo privileges required. Please enter your password:"
  sudo true
fi

# Determine host timezone
HOST_TIMEZONE=""
if [[ -L /etc/localtime ]]; then
  # Method 1: Read symlink
  HOST_TIMEZONE=$(readlink /etc/localtime | sed 's|^.*/zoneinfo/||')
  log "Detected timezone from /etc/localtime symlink: $HOST_TIMEZONE"
elif [[ -f /etc/timezone ]]; then
  # Method 2: Read /etc/timezone file
  HOST_TIMEZONE=$(cat /etc/timezone)
  log "Detected timezone from /etc/timezone: $HOST_TIMEZONE"
elif command -v timedatectl >/dev/null 2>&1; then
  # Method 3: Use timedatectl
  HOST_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
  if [[ -n "$HOST_TIMEZONE" ]]; then
    log "Detected timezone using timedatectl: $HOST_TIMEZONE"
  fi
fi

# Fallback to UTC if detection failed
if [[ -z "$HOST_TIMEZONE" || ! -f "/usr/share/zoneinfo/$HOST_TIMEZONE" ]]; then
  HOST_TIMEZONE="UTC"
  log "Could not detect host timezone or timezone file not found, using fallback: $HOST_TIMEZONE"
else
  log "Using detected timezone: $HOST_TIMEZONE"
fi

log "Checking dependencies..."
MISSING=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if ! dpkg -s "$pkg" &>/dev/null; then
    MISSING+=("$pkg")
  fi
done
if [ "${#MISSING[@]}" -ne 0 ]; then
  log "Installing missing packages: ${MISSING[*]}"
  sudo apt update && sudo apt install -y "${MISSING[@]}"
fi

log "Creating working directories..."
sudo mkdir -p "$CHROOTDIR" "$ISODIR"

log "Downloading base system via debootstrap..."
sudo debootstrap --arch=$ARCH --variant=minbase \
  --include=apt,dpkg,gpg,gnupg,ca-certificates,sudo,wget,curl,netbase,net-tools,iproute2,iputils-ping,coreutils,grub-pc,os-prober,parted,fdisk,e2fsprogs,keyboard-configuration,console-setup,locales,debconf,bind9-utils,cpio,cron,dmidecode,dosfstools,ed,file,ftp,hdparm,logrotate,lshw,lsof,man-db,media-types,nftables,pciutils,psmisc,rsync,strace,time,usbutils,xz-utils,zstd,nano \
  $RELEASE "$CHROOTDIR" "$MIRROR"

log "Configuring system inside chroot..."
# Save original resolv.conf for restoration
if [[ -f "$CHROOTDIR/etc/resolv.conf" ]]; then
  sudo cp "$CHROOTDIR/etc/resolv.conf" "$CHROOTDIR/etc/resolv.conf.orig"
fi
sudo cp /etc/resolv.conf "$CHROOTDIR/etc/"

# Mount pseudo-filesystems
for dir in dev dev/pts proc sys run; do 
  sudo mount --bind /$dir "$CHROOTDIR/$dir"
done

# Pass the detected timezone to chroot environment
sudo chroot "$CHROOTDIR" /bin/bash <<EOF
set -e
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive
export HOST_TIMEZONE="$HOST_TIMEZONE"

echo "Setting up hostname and locales..."
echo "uMini" > /etc/hostname
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8 LANGUAGE=en_US LC_ALL=en_US.UTF-8

# Set timezone from host system
echo "Setting timezone to: \$HOST_TIMEZONE"
if [[ -f "/usr/share/zoneinfo/\$HOST_TIMEZONE" ]]; then
  ln -sfn "/usr/share/zoneinfo/\$HOST_TIMEZONE" /etc/localtime
  echo "\$HOST_TIMEZONE" > /etc/timezone
  echo "Timezone successfully set to \$HOST_TIMEZONE"
else
  echo "Warning: Timezone file /usr/share/zoneinfo/\$HOST_TIMEZONE not found, using UTC"
  ln -sfn /usr/share/zoneinfo/UTC /etc/localtime
  echo "UTC" > /etc/timezone
fi

# Create /etc/hosts
echo "Creating /etc/hosts..."
cat <<HOSTS > /etc/hosts
127.0.0.1	localhost
127.0.1.1	uMini
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS

echo "Setting up repositories..."
cat <<LIST > /etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
LIST

# Remove automatically added cdrom lines (if any)
sed -i '/^deb cdrom:/d' /etc/apt/sources.list

# Update package lists
echo "Updating package lists..."
apt update

# Install kernel and live system
echo "Installing kernel and live components..."
if ! apt install --no-install-recommends -y \
  linux-image-generic linux-headers-generic live-boot casper \
  initramfs-tools systemd-sysv libpam-systemd systemd-resolved iwd \
  bash-completion apt-file command-not-found; then
  
  echo "ERROR: Failed to install packages" >&2
  echo "Checking available kernel packages:"
  apt-cache search linux-image-generic || true
  exit 1
fi

# Verify kernel installation
echo "Checking installed kernel files..."
ls -la /boot/vmlinuz-* || {
  echo "ERROR: Kernel files not found after installation!" >&2
  ls -la /boot/ || true
  exit 1
}

# Update apt-file database
echo "Updating apt-file database..."
apt-file update

# Configure bash completion for users
echo "Setting up bash completion..."
for HOME in /root /home/ubuntu /home/umini; do
  if [[ -d "\$HOME" ]]; then
    echo -e "\nif [ -f /etc/bash_completion ]; then\n . /etc/bash_completion\nfi" >> "\$HOME/.bashrc"
  fi
done

# Enable network services
echo "Enabling network services..."
systemctl enable iwd
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# Network configuration
echo "Configuring network interfaces..."
mkdir -p /etc/systemd/network/
cat <<CFG > /etc/systemd/network/20-wired.network
[Match]
Name=en*

[Network]
DHCP=yes
CFG

# DNS configuration
echo "Configuring DNS..."
rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Create unattended-upgrades configuration
echo "Setting up automatic updates..."
mkdir -p /etc/apt/apt.conf.d
cat <<UPG > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
    "Ubuntu stable";
    "Ubuntu noble-security";
    "Ubuntu noble-updates";
};
Unattended-Upgrade::Automatic-Reboot "false";
UPG

# Enable automatic updates
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/10periodic
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/10periodic

# Create users
echo "Creating users..."
# User umini
if ! id "umini" &>/dev/null; then
  adduser --disabled-password --gecos "" umini
  echo "umini:umini" | chpasswd
  usermod -aG sudo umini
  mkdir -p /home/umini
  chown umini:umini /home/umini
fi

# User ubuntu
if ! id "ubuntu" &>/dev/null; then
  adduser --disabled-password --gecos "" ubuntu
  echo "ubuntu:ubuntu" | chpasswd
  usermod -aG sudo ubuntu
  mkdir -p /home/ubuntu
  chown ubuntu:ubuntu /home/ubuntu
fi

# Root password
echo "root:toor" | chpasswd

# Configure autologin for umini user
echo "Setting up autologin..."
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat <<AUTOLOGIN > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin umini --noclear %I \$TERM
AUTOLOGIN

# Welcome message
echo "Creating welcome message..."
mkdir -p /etc/profile.d/
cat <<WELCOME > /etc/profile.d/uminilive.sh
#!/bin/bash
echo -e "\e[1;32mWelcome to uMini Live!\e[0m"
echo -e "Users: umini/umini, ubuntu/ubuntu, root/toor"
echo -e "Timezone: \$(cat /etc/timezone 2>/dev/null || echo 'UTC')"
WELCOME
chmod +x /etc/profile.d/uminilive.sh

# Cleanup
echo "Cleaning temporary files..."
apt clean
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* 
rm -rf /var/cache/apt/* /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Restore original resolv.conf if it existed
if [[ -f /etc/resolv.conf.orig ]]; then
  mv /etc/resolv.conf.orig /etc/resolv.conf
fi

echo "Chroot configuration completed successfully!"
EOF

log "Generating initramfs..."
sudo chroot "$CHROOTDIR" update-initramfs -u -k all

log "Copying kernel and initrd..."
sudo mkdir -p "$ISODIR/casper"

# Find kernel version in chroot
KERNEL_FILES=($(sudo ls "$CHROOTDIR/boot/vmlinuz-"* 2>/dev/null || true))
if [[ ${#KERNEL_FILES[@]} -eq 0 ]]; then
  err "Could not find kernel files in $CHROOTDIR/boot/"
  err "Contents of $CHROOTDIR/boot/:"
  sudo ls -la "$CHROOTDIR/boot/" || true
  exit 1
fi

# Take the first found kernel
KERNEL_FILE="${KERNEL_FILES[0]}"
KERNEL_VER=$(basename "$KERNEL_FILE" | sed 's/vmlinuz-//')
log "Found kernel version: $KERNEL_VER"

# Check file existence
if [[ ! -f "$CHROOTDIR/boot/vmlinuz-$KERNEL_VER" ]]; then
  err "Kernel file not found: $CHROOTDIR/boot/vmlinuz-$KERNEL_VER"
  exit 1
fi

if [[ ! -f "$CHROOTDIR/boot/initrd.img-$KERNEL_VER" ]]; then
  err "Initrd file not found: $CHROOTDIR/boot/initrd.img-$KERNEL_VER"
  exit 1
fi

# Copy files
sudo cp "$CHROOTDIR/boot/vmlinuz-$KERNEL_VER" "$ISODIR/casper/vmlinuz"
sudo cp "$CHROOTDIR/boot/initrd.img-$KERNEL_VER" "$ISODIR/casper/initrd.img"
log "Kernel and initrd successfully copied"

log "Unmounting chroot before creating squashfs..."
# Fixed unmounting order
for mp in dev/pts proc sys run dev; do
  if mountpoint -q "$CHROOTDIR/$mp" 2>/dev/null; then
    echo " - Unmounting $CHROOTDIR/$mp"
    sudo umount -lf "$CHROOTDIR/$mp" || true
  fi
done

log "Creating squashfs..."
sudo mksquashfs "$CHROOTDIR" "$ISODIR/casper/filesystem.squashfs" -e boot -comp xz

log "Generating filesystem.size..."
# Create file with filesystem size in bytes
FILESYSTEM_SIZE=$(sudo du -sb "$CHROOTDIR" | cut -f1)
echo "$FILESYSTEM_SIZE" | sudo tee "$ISODIR/casper/filesystem.size" > /dev/null
log "Filesystem size: $FILESYSTEM_SIZE bytes ($(($FILESYSTEM_SIZE / 1024 / 1024)) MB)"

log "Creating manifest files..."
sudo mkdir -p "$ISODIR/.disk"
echo "uMini Live System" | sudo tee "$ISODIR/.disk/info" > /dev/null
echo "$(date -u +%Y%m%d-%H:%M)" | sudo tee "$ISODIR/.disk/casper-uuid" > /dev/null

# Create filesystem.manifest - list of all installed packages
log "Generating filesystem.manifest..."
sudo chroot "$CHROOTDIR" dpkg-query -W --showformat='${Package} ${Version}\n' | sudo tee "$ISODIR/casper/filesystem.manifest" > /dev/null

# Create filesystem.manifest-desktop (copy of main manifest for desktop version)
sudo cp "$ISODIR/casper/filesystem.manifest" "$ISODIR/casper/filesystem.manifest-desktop"

# Create filesystem.manifest-remove (packages to remove during installation)
# Usually live-boot, casper and other live-specific packages
cat <<MANIFEST_REMOVE | sudo tee "$ISODIR/casper/filesystem.manifest-remove" > /dev/null
live-boot
live-boot-initramfs-tools
casper
lupin-casper
MANIFEST_REMOVE

log "Creating GRUB menu..."
sudo mkdir -p "$ISODIR/boot/grub"
cat <<GRUBCFG | sudo tee "$ISODIR/boot/grub/grub.cfg"
set timeout=10
set default=0

menuentry "Start uMini Live" {
    linux /casper/vmlinuz boot=casper quiet splash username=umini hostname=uMini
    initrd /casper/initrd.img
}

menuentry "Start uMini Live (Safe Mode)" {
    linux /casper/vmlinuz boot=casper quiet splash username=umini hostname=uMini nomodeset
    initrd /casper/initrd.img
}

menuentry "Check disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet splash username=umini hostname=uMini
    initrd /casper/initrd.img
}
GRUBCFG

log "Generating md5sum.txt..."
(cd "$ISODIR" && find . -type f ! -name "md5sum.txt" -print0 | sudo xargs -0 md5sum | sudo tee md5sum.txt > /dev/null)

log "Creating hybrid ISO image..."
sudo grub-mkrescue -o "$IMAGENAME" "$ISODIR" --compress=xz

log "Setting permissions for ISO image..."
sudo chown "$USER:$USER" "$IMAGENAME"
chmod 644 "$IMAGENAME"

ISO_SIZE=$(du -h "$IMAGENAME" | cut -f1)

log "✅ ISO image successfully created!"
echo -e "\n=============================="
echo -e "📦 Filename:         $IMAGENAME"
echo -e "📁 Path:             $(realpath "$IMAGENAME")"
echo -e "📏 Size:             $ISO_SIZE"
echo -e "🧊 Compression:      SquashFS (xz)"
echo -e "🖥️ Architecture:     $ARCH"
echo -e "🗓️ Build date:       $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "🌍 Timezone:         $HOST_TIMEZONE"
echo -e "💽 Bootloader:       GRUB (BIOS + UEFI)"
echo -e "📂 Working folder:   $WORKDIR"
echo -e "==============================="
echo -e "\nTo test the ISO:"
echo -e "qemu-system-x86_64 -m 2048 -cdrom $IMAGENAME"
