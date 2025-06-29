# uMini Build Script Changelog

## Version RC (Release Candidate)

### Script Version: 0.0.2-rc

### 🚀 Major Improvements

#### **Enhanced Build Configuration**
- **Configurable build parameters** via environment variables:
  - `RELEASE`, `ARCH`, `MIRROR`, `WORKDIR` - Basic build configuration
  - `BUILD_THREADS` - Parallel processing control (defaults to CPU core count)
  - `SQUASHFS_COMP`, `SQUASHFS_BLOCK_SIZE` - Compression optimization
  - `ISO_COMPRESSION` - ISO compression method
  - `PRESERVE_WORKDIR` - Option to keep build directory for debugging

#### **Optimized Package Management**
- **Reorganized package lists** into logical categories:
  - `DEBOOTSTRAP_ESSENTIAL` - Absolute minimum for base system
  - `SYSTEM_PACKAGES` - Core system utilities organized by function
  - `LIVE_SYSTEM_PACKAGES` - Live boot and hardware support packages
- **Package validation** - Pre-build verification of package availability
- **Duplicate removal** - Automatic deduplication of package lists
- **Optional package support** - Suggests performance-enhancing packages (aria2, pigz, pbzip2)

#### **Advanced Error Handling & Logging**
- **Structured logging** with timestamps and color-coded messages
- **Enhanced cleanup** with timeout-based unmounting and process termination
- **Error context** - Shows chroot logs when configuration fails
- **Pre-flight checks** - Validates all requirements before starting build
- **ISO integrity verification** - Multiple validation steps for final image

### 🛠️ Technical Enhancements

#### **Improved Build Process**
- **Parallel downloads** using aria2 when available
- **Optimized SquashFS creation** with configurable compression and threading
- **Multiple ISO creation methods** with automatic fallback:
  1. grub-mkrescue with volume ID
  2. grub-mkrescue without volume ID  
  3. Direct xorriso with full boot support
  4. Minimal xorriso fallback
- **Disk space monitoring** - Checks available space before ISO creation

#### **Better System Configuration**
- **External configuration script** - Avoids permission issues in chroot
- **Template-based configuration** - Uses placeholders for dynamic values
- **APT optimization** - Parallel downloads, warning suppression, dependency handling
- **Network improvements** - Enhanced Wi-Fi setup with `iwctl` instructions

#### **Enhanced User Experience**
- **Progress tracking** - Better feedback during long operations
- **Build statistics** - Comprehensive summary with timing and package counts
- **Testing instructions** - Ready-to-use QEMU commands with networking
- **Debug support** - Preserved logs and optional directory retention

### 🔧 System Changes

#### **Updated Default User**
- **Changed autologin** from `umini` to `ubuntu` user
- **Improved welcome message** with Wi-Fi connection instructions
- **Better user management** with proper home directory setup

#### **Network Configuration**
- **Simplified network setup** with systemd-networkd
- **Wi-Fi ready** - Pre-configured with iwd and connection instructions
- **DNS resolution** - Proper systemd-resolved configuration

#### **Boot Configuration**
- **Enhanced GRUB menu** with additional boot options:
  - Safe Graphics mode (nomodeset)
  - Debug mode with verbose output
  - Memory test option (placeholder)
- **Better boot parameters** - Optimized for live system performance

### 🐛 Bug Fixes

#### **Mount/Unmount Issues**
- **Fixed unmounting order** - Proper sequence for nested mount points
- **Lazy unmounting** - Fallback for stuck mount points
- **Process cleanup** - Kills remaining processes using chroot
- **Mount point verification** - Checks before attempting operations

#### **Package Installation**
- **Improved error handling** - Better feedback when packages fail to install
- **Kernel verification** - Ensures kernel files exist after installation
- **Dependency resolution** - Enhanced handling of package conflicts

#### **ISO Creation**
- **Fixed volume ID syntax** - Proper parameter passing to grub-mkrescue
- **Size validation** - Prevents creation of corrupted small ISOs
- **Permission handling** - Proper ownership of final ISO file

### 📊 Performance Improvements

- **Parallel processing** - Multi-threaded SquashFS compression
- **Optimized downloads** - aria2 integration for faster package downloads
- **Better compression** - Configurable SquashFS options for size/speed balance
- **Reduced I/O** - Minimized file operations during build

### 🔒 Reliability Enhancements

- **Comprehensive validation** - Pre-build, mid-build, and post-build checks
- **Fallback mechanisms** - Multiple approaches for critical operations
- **Better error recovery** - Graceful handling of common failure scenarios
- **Build reproducibility** - Consistent results across different systems

### 📋 Configuration Details

#### **New Environment Variables**
```bash
RELEASE=noble              # Ubuntu release
ARCH=amd64                # Architecture
MIRROR=http://...         # Package mirror
BUILD_THREADS=4           # Parallel jobs
SQUASHFS_COMP=xz          # Compression type
SQUASHFS_BLOCK_SIZE=1M    # Block size
ISO_COMPRESSION=xz        # ISO compression
PRESERVE_WORKDIR=1        # Keep build directory
```

#### **Package Count Changes**
- **Reduced base packages** - More efficient minimal system
- **Better categorization** - Logical grouping for maintenance
- **Live system focus** - Optimized package selection for live boot

### 🎯 Migration Notes

#### **Breaking Changes**
- **Autologin user changed** from `umini` to `ubuntu`
- **Different package selection** - Some packages moved between categories
- **New environment variables** - Build behavior may differ with defaults

#### **Recommended Actions**
1. **Test new ISO** - Verify functionality with your use cases
2. **Check package list** - Ensure required packages are still included
3. **Update documentation** - References to user accounts and procedures
4. **Performance tune** - Experiment with new compression and threading options

---

*This changelog covers the transition from the original uMini.sh to uMini-rc.sh (Release Candidate)*
