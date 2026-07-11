#!/bin/bash
set -e

# ============================================================
# SM8350 Kernel Build Script – Galaxy S21 FE Snapdragon (r9q2)
# ============================================================

SRC_DIR="$(pwd)"
PREBUILTS="$SRC_DIR/prebuilts"
DEFCONFIG="eureka/r9q_eur_openx2_defconfig"
DEVICE="r9q2"
CLANG_DIR="$PREBUILTS/clang-19"
MAGISKBOOT="$PREBUILTS/magiskboot"
BOOT_IMG="$PREBUILTS/boot.img"
VENDOR_BOOT_IMG="$PREBUILTS/vendor_boot.img"
MODULES_DIR="$SRC_DIR/modules_install"
FINAL_DIR="$SRC_DIR/final-images"
KMOD29_DEPMOD="/tmp/kmod29/sbin/depmod"
chmod +x prebuilts/magiskboot
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

abort() { echo -e "${RED}ERROR: $1${NC}"; exit 1; }
log_step() { echo -e "${GREEN}[+] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[!] $1${NC}"; }

# Auto-cleanup temporary directories on exit
cleanup() { rm -rf /tmp/tmp.* 2>/dev/null || true; }
trap cleanup EXIT

# --- Check prerequisites ---
log_step "Checking prerequisites..."
[ -f "$SRC_DIR/Makefile" ] || abort "Run from kernel source root"
command -v aarch64-linux-gnu-gcc &>/dev/null || abort "Install gcc-aarch64-linux-gnu & gcc-arm-linux-gnueabi"
[ -f "$MAGISKBOOT" ] || abort "magiskboot not found at $MAGISKBOOT"
[ -f "$BOOT_IMG" ] || abort "boot.img not found at $BOOT_IMG"
[ -f "$VENDOR_BOOT_IMG" ] || abort "vendor_boot.img not found at $VENDOR_BOOT_IMG"

# --- Download Clang if missing ---
CLANG_VERSION="r530567"
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-${CLANG_VERSION}.tar.gz"
if [ ! -f "$CLANG_DIR/bin/clang" ]; then
    log_step "Clang not found. Downloading Clang ${CLANG_VERSION}..."
    mkdir -p "$CLANG_DIR"
    cd "$CLANG_DIR"
    wget -q --show-progress https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r530567.tar.gz -O clang.tar.gz
    tar -xzf clang.tar.gz
    rm clang.tar.gz
    cd "$SRC_DIR"
    log_step "Clang ${CLANG_VERSION} installed."
else
    log_step "Clang ${CLANG_VERSION} already present."
fi

log_step "All prerequisites met."

# --- Environment ---
export ARCH=arm64
export PATH="$CLANG_DIR/bin:$PATH"
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# --- Download kmod29 if needed ---
if [ ! -f "$KMOD29_DEPMOD" ]; then
    log_step "Downloading kmod 29 (compatible depmod)..."
    cd /tmp
    wget -q http://archive.ubuntu.com/ubuntu/pool/main/k/kmod/kmod_29-1ubuntu1_amd64.deb
    mkdir -p kmod29 && dpkg-deb -x kmod_29-1ubuntu1_amd64.deb kmod29/
    rm kmod_29-1ubuntu1_amd64.deb
    cd "$SRC_DIR"
fi

# --- Build kernel + modules (no dtbo) ---
log_step "Building kernel Image and modules..."
rm -rf "$SRC_DIR/out" "$MODULES_DIR" "$SRC_DIR/modules"
mkdir -p "$SRC_DIR/out"

make O=out ARCH=arm64 "$DEFCONFIG"
yes "" | make O=out ARCH=arm64 oldconfig 2>/dev/null || true
./scripts/config --file out/.config --enable CONFIG_SECTION_MISMATCH_WARN_ONLY
yes "" | make O=out ARCH=arm64 oldconfig 2>/dev/null || true

make O=out ARCH=arm64 \
    CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
    STRIP=llvm-strip OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump \
    READELF=llvm-readelf LLVM_IAS=1 \
    -j$(nproc) Image modules || abort "Build failed"

log_step "Kernel build complete."

# --- Install & strip modules ---
log_step "Installing and stripping modules..."
mkdir -p "$MODULES_DIR"
make O=out ARCH=arm64 \
    INSTALL_MOD_PATH="../modules_install" \
    INSTALL_MOD_STRIP="--strip-debug --keep-section=.ARM.attributes" \
    modules_install || abort "Module install failed"

KERNEL_VERSION=$(ls "$MODULES_DIR/lib/modules/" | head -1)
MODPATH="$MODULES_DIR/lib/modules/$KERNEL_VERSION"
[ -d "$MODPATH" ] || abort "Module directory $MODPATH not found"

# --- Save a flat copy for inspection ---
mkdir -p "$SRC_DIR/modules"
find "$MODPATH" -name "*.ko" -exec cp {} "$SRC_DIR/modules/" \;
log_step "Stripped modules copied to $SRC_DIR/modules/ for inspection."

# --- Generate initial metadata (depmod) ---
log_step "Running depmod (kmod 29)..."
"$KMOD29_DEPMOD" -b "$MODULES_DIR" "$KERNEL_VERSION" 2>/dev/null || log_warn "depmod warnings (non‑critical)"

# ============================================================
#  Build correct modules.order and modules.load (Exynos logic)
# ============================================================
log_step "Generating module load order..."

# Create modules.order if missing (flat list of all .ko filenames)
if [ ! -f "$MODPATH/modules.order" ]; then
    find "$MODPATH" -name "*.ko" -exec basename {} \; | sort > "$MODPATH/modules.order"
fi

# Priority order list – exactly as provided
INITIAL_ORDER="
ssg-iosched.ko
blk-sec-stats.ko
llcc_perfmon.ko
rdbg.ko
nfc_sec.ko
cnss2.ko
cnss_utils.ko
wlan_firmware_service_v01.ko
device_management_service_v01.ko
cnss_nl.ko
cnss_prealloc.ko
rtl8150.ko
cdc_eem.ko
cdc_ncm.ko
aqc111.ko
tuner-xc2028.ko
tuner-simple.ko
tuner-types.ko
mt20xx.ko
tea5767.ko
tea5761.ko
tda9887.ko
xc5000.ko
xc4000.ko
msi001.ko
mt2060.ko
mt2063.ko
mt2266.ko
qt1010.ko
mt2131.ko
mxl5005s.ko
mxl5007t.ko
mc44s803.ko
max2165.ko
tda18218.ko
tda18212.ko
e4000.ko
fc2580.ko
tua9001.ko
si2157.ko
fc0011.ko
fc0012.ko
fc0013.ko
it913x.ko
r820t.ko
mxl301rf.ko
qm1d1c0042.ko
qm1d1b0004.ko
m88rs6000t.ko
tda18250.ko
radio-i2c-rtc6226-qca.ko
btpower.ko
bt_fm_slim.ko
hid-aksys.ko
wlan.ko
input_booster_lkm.ko
sec_tsp_log.ko
sec_tclm_v2.ko
sec_secure_touch.ko
sec_tsp_dumpkey.ko
sec_common_fn.ko
sec_cmd.ko
fingerprint.ko
fingerprint_sysfs.ko
slsi_ts.ko
snvm.ko
synaptics_ts.ko
slimbus.ko
slimbus-ngd.ko
snd-soc-cirrus-amp.ko
snd-soc-cs35l41-i2c.ko
snd-soc-wm-adsp.ko
sec_audio_sysfs.ko
camera.ko
rmnet_offload.ko
rmnet_shs.ko
rmnet_core.ko
rmnet_ctl.ko
pinctrl_wcd_dlkm.ko
pinctrl_lpi_dlkm.ko
snd_event_dlkm.ko
native_dlkm.ko
q6_dlkm.ko
adsp_loader_dlkm.ko
q6_pdr_dlkm.ko
q6_notifier_dlkm.ko
apr_dlkm.ko
bolero_cdc_dlkm.ko
va_macro_dlkm.ko
tx_macro_dlkm.ko
rx_macro_dlkm.ko
wcd_core_dlkm.ko
wcd9xxx_dlkm.ko
stub_dlkm.ko
hdmi_dlkm.ko
platform_dlkm.ko
machine_dlkm.ko
wireguard.ko
"

# Build modules.load with initial order first
rm -f "$MODPATH/modules.load"
for mod in $INITIAL_ORDER; do
    if grep -qx "$mod" "$MODPATH/modules.order"; then
        echo "$mod" >> "$MODPATH/modules.load"
        sed -i "/^$mod$/d" "$MODPATH/modules.order"
    fi
done

# Append remaining modules (newly built ones)
cat "$MODPATH/modules.order" >> "$MODPATH/modules.load"

log_step "modules.load created ($(wc -l < "$MODPATH/modules.load") entries)"

# Fix modules.dep paths (kernel/... → /lib/modules/...)
log_step "Adjusting modules.dep paths..."
if [ -f "$MODPATH/modules.dep" ]; then
    sed -i 's|kernel/[^: ]*/|/lib/modules/|g' "$MODPATH/modules.dep"
    log_step "modules.dep fixed."
else
    log_warn "modules.dep not found!"
fi

log_step "Module metadata ready."

MODULE_COUNT=$(find "$MODPATH" -name "*.ko" | wc -l)
log_step "Modules ready: $MODULE_COUNT .ko files"

# --- Output directory ---
rm -rf "$FINAL_DIR" && mkdir -p "$FINAL_DIR"

# --- Repack boot.img ---
log_step "Repacking boot.img..."
TMPD=$(mktemp -d)
cp "$BOOT_IMG" "$TMPD/boot.img"
cd "$TMPD"
"$MAGISKBOOT" unpack -h boot.img || abort "Failed to unpack boot.img"
rm -f kernel
cp "$SRC_DIR/out/arch/arm64/boot/Image" kernel
"$MAGISKBOOT" repack boot.img boot-new.img || abort "Failed to repack boot.img"
cp boot-new.img "$FINAL_DIR/boot.img"
cd "$SRC_DIR"
rm -rf "$TMPD"
log_step "boot.img repacked."

# --- Repack vendor_boot.img ---
log_step "Repacking vendor_boot.img..."
TMPD=$(mktemp -d)
cp "$VENDOR_BOOT_IMG" "$TMPD/vendor_boot.img"
cd "$TMPD"
"$MAGISKBOOT" unpack -h vendor_boot.img || abort "Failed to unpack vendor_boot.img"

# Replace old modules
"$MAGISKBOOT" cpio ramdisk.cpio "rm -r lib/modules" 2>/dev/null || true
"$MAGISKBOOT" cpio ramdisk.cpio "mkdir 0755 lib/modules"

# Add all .ko files (flat, like Samsung)
find "$MODPATH" -name "*.ko" | while read -r f; do
    "$MAGISKBOOT" cpio ramdisk.cpio "add 0644 lib/modules/$(basename "$f") $f"
done

# Add metadata files (modules.alias, modules.dep, modules.softdep, modules.load)
for meta in modules.alias modules.dep modules.softdep modules.load; do
    if [ -f "$MODPATH/$meta" ]; then
        "$MAGISKBOOT" cpio ramdisk.cpio "add 0644 lib/modules/$meta $MODPATH/$meta"
    else
        log_warn "Metadata $meta missing from $MODPATH"
    fi
done

"$MAGISKBOOT" repack vendor_boot.img vendor_boot-new.img || abort "Failed to repack vendor_boot.img"
cp vendor_boot-new.img "$FINAL_DIR/vendor_boot.img"
cd "$SRC_DIR"
rm -rf "$TMPD"
log_step "vendor_boot.img repacked."

# --- Done ---
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  BUILD COMPLETE${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
ls -lh "$FINAL_DIR/"
echo ""
echo -e "  ${YELLOW}boot.img${NC}        - Kernel Image"
echo -e "  ${YELLOW}vendor_boot.img${NC}  - $MODULE_COUNT modules + auto‑generated metadata"
echo ""
zip -r "kernel-artifacts-$DEVICE.zip" final-images/
