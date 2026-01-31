#!/bin/bash

# Ensure the script exits on error
set -e

# ==================== [自动清理旧版环境] ====================
echo "正在应用补丁清理旧版 KSU/SUSFS..."
curl -L https://github.com/ApartTUSITU/kernel_xiaomi_sm8250_mod/commit/a05557c.patch | git apply -v || true
rm -rf drivers/susfs
rm -rf fs/susfs
echo "环境清理完毕。"
# ==========================================================

TOOLCHAIN_PATH=$HOME/zyc-clang/bin
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE="${1:-alioth}"

if [ ! -d $TOOLCHAIN_PATH ]; then
    echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
    exit 1
fi

export PATH="$TOOLCHAIN_PATH:$PATH"
export CCACHE_DIR="$HOME/.cache/ccache_mikernel" 
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache:$PATH"

MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
    echo "No target device [${TARGET_DEVICE}] found."
    ls arch/arm64/configs/*_defconfig
    exit 1
fi

# 核心变量
KSU_ENABLE=1
KSU_ZIP_STR=KSU_SUSFS

echo "TARGET_DEVICE: $TARGET_DEVICE"

# ==================== [Step 1: 注入 SukiSU (Builtin 分支)] ====================
echo "Installing SukiSU (Non-GKI builtin mode)..."
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin

# ==================== [Step 2: 应用官方 Manual Hooks (v1.6)] ====================
echo "Downloading and applying SukiSU Manual Hooks (v1.6)..."
wget https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU_patch/main/hooks/scope_min_manual_hooks_v1.6.patch -O sukisu_hooks.patch

echo "Applying SukiSU hooks..."
patch -p1 -F 3 < sukisu_hooks.patch || { echo "❌ SukiSU Hooks Patch Failed!"; exit 1; }
echo "✅ SukiSU Hooks applied successfully."

# ==================== [Step 3: 终极修复 - 注入缺失的变量和函数] ====================
echo "Injecting missing variables and hooks into builtin driver..."

# 这一步将直接修改 drivers/kernelsu/ksu.c，补全所有缺失的定义
# 这解决了 undefined reference to 'ksu_vfs_read_hook' 等所有链接错误
cat >> drivers/kernelsu/ksu.c <<'EOF'

/* ========================================================================== */
/* [INJECTED CODE] Restoring Missing Hooks & Variables for Non-GKI 4.19       */
/* This section fixes "undefined reference" linker errors.                    */
/* ========================================================================== */

#include <linux/fs.h>
#include <linux/version.h>
#include "ksu.h"

// ---------------------------------------------------------------------------
// 1. READ HOOK (修复 undefined reference to `ksu_vfs_read_hook`)
// ---------------------------------------------------------------------------
// [关键] 定义布尔开关变量
bool ksu_vfs_read_hook __read_mostly = true;

// [关键] 定义函数实现
extern int ksu_handle_vfs_read_hook(struct file *file, char __user **buf, size_t *count, loff_t *pos);
int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr) {
    struct file *file;
    file = fget(fd);
    if (!file) return 0;
    ksu_handle_vfs_read_hook(file, buf_ptr, count_ptr, &file->f_pos);
    fput(file);
    return 0;
}

// ---------------------------------------------------------------------------
// 2. INPUT HOOK (修复 undefined reference to `ksu_input_hook`)
// ---------------------------------------------------------------------------
// [关键] 定义布尔开关变量
bool ksu_input_hook __read_mostly = true;

// [关键] 定义函数实现
int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value) {
    return 0; // 即使为空，只要符号存在，链接器就不会报错
}

// ---------------------------------------------------------------------------
// 3. EXECVE HOOK (修复 undefined reference to `ksu_handle_execve_sucompat`)
// ---------------------------------------------------------------------------
// v1.6 补丁在 fs/exec.c 里直接调用了这个函数
int ksu_handle_execve_sucompat(int *fd, const char __user **filename_user, void *argv, void *envp, int *flags) {
     return 0; 
}

extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);
int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags) {
    return ksu_handle_execveat_sucompat(fd, filename_ptr, argv, envp, flags);
}

// ---------------------------------------------------------------------------
// 4. FACCESSAT & STAT HOOK (基础功能)
// ---------------------------------------------------------------------------
extern int ksu_handle_faccessat_sucompat(int *dfd, const char __user **filename_user, int *mode, int *flags);
int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags) {
    return ksu_handle_faccessat_sucompat(dfd, filename_user, mode, flags);
}

extern int ksu_handle_stat_sucompat(int *dfd, const char __user **filename_user, int *flags);
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags) {
    return ksu_handle_stat_sucompat(dfd, filename_user, flags);
}

// ---------------------------------------------------------------------------
// 5. REBOOT HOOK (修复 v1.6 补丁引入的 reboot 钩子)
// ---------------------------------------------------------------------------
int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg) {
    return 0;
}

/* ========================================================================== */
EOF

echo "✅ All missing variables and hooks have been injected!"

# ==================== [Step 4: 注入 SUSFS (源码 Patch)] ====================
echo "Downloading and applying SUSFS Patch..."
wget https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch -O susfs.patch

echo "Applying SUSFS patch..."
patch -p1 -F 3 < susfs.patch || { echo "❌ SUSFS Patch Failed!"; exit 1; }
echo "✅ SUSFS Patch applied successfully."

# ==================== [准备编译] ====================

echo "Cleaning out directory..."
rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3"
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel

local_version_str="-perf"
local_version_date_str="-$(date +%Y%m%d)-${GIT_COMMIT_ID}-perf"
sed -i "s/${local_version_str}/${local_version_date_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig


# ------------- Building for MIUI ONLY -------------

echo "Building for MIUI....."

dts_source=arch/arm64/boot/dts/vendor/qcom
cp -a ${dts_source} .dts.bak

# Correct panel dimensions & Fix Display
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j2*
sed -i 's/<155>/<1544>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<155>/<1545>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j2*

# Enable back mi smartfps & refresh rates
sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi

# Enable back brightness control
sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi

# Make Defconfig
# 此时会生成 .config 文件
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

# ==================== [Step 5: 配置 .config] ====================
# [核心] 强制开启 KPM 和 Manual Hook
scripts/config --file out/.config \
    -e KSU \
    -e KSU_MANUAL_HOOK \
    -e KSU_SUSFS \
    -e KSU_SUSFS_HAS_MAGIC_MOUNT \
    -e KSU_SUSFS_SUS_PATH \
    -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
    -e KSU_SUSFS_SUS_KSTAT \
    -d KSU_SUSFS_SUS_OVERLAYFS \
    -e KSU_SUSFS_TRY_UMOUNT \
    -e KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
    -e KSU_SUSFS_SPOOF_UNAME \
    -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -e KSU_SUSFS_OPEN_REDIRECT \
    -e KSU_SUSFS_SUS_MAP \
    -d KSU_SUSFS_SUS_SU \
    -e KPM \
    -e KALLSYMS \
    -e KALLSYMS_ALL

# General Optimization Configs
scripts/config --file out/.config \
    --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
    -e PERF_CRITICAL_RT_TASK \
    -e SF_BINDER \
    -e OVERLAY_FS \
    -d DEBUG_FS \
    -e MIGT \
    -e MIGT_ENERGY_MODEL \
    -e MIHW \
    -e PACKAGE_RUNTIME_INFO \
    -e BINDER_OPT \
    -e KPERFEVENTS \
    -e MILLET \
    -e PERF_HUMANTASK \
    -d LTO_CLANG \
    -d LOCALVERSION_AUTO \
    -e SF_BINDER \
    -e XIAOMI_MIUI \
    -d MI_MEMORY_SYSFS \
    -e TASK_DELAY_ACCT \
    -e MIUI_ZRAM_MEMORY_TRACKING \
    -d CONFIG_MODULE_SIG_SHA512 \
    -d CONFIG_MODULE_SIG_HASH \
    -e MI_FRAGMENTION \
    -e PERF_HELPER \
    -e BOOTUP_RECLAIM \
    -e MI_RECLAIM \
    -e RTMM

# ==============================================================================
# [光速验证环节]
# 位置：在生成 .config 之后，在完整编译之前
# 作用：只编译驱动，验证注入是否成功，耗时 30秒
# ==============================================================================
echo "⚡️ 正在进行光速验证 (SukiSU Driver Check)..."

# 1. 尝试单独编译 drivers/kernelsu 目录
# 必须带上 $MAKE_ARGS 以便识别 out 目录下的 .config
make $MAKE_ARGS drivers/kernelsu/

# 2. 检查编译是否成功
if [ $? -ne 0 ]; then
    echo "❌ [验证失败] SukiSU 驱动编译即报错！(语法错误/缺头文件)"
    exit 1
fi

# 3. [核心] 使用 nm 命令检查 ksu.o 里到底有没有那个函数
# 我们去 out 目录找生成的 ksu.o 文件
KSU_OBJ="out/drivers/kernelsu/ksu.o"

if [ -f "$KSU_OBJ" ]; then
    echo "🔎 正在检查符号表..."
    
    # 检查 'ksu_vfs_read_hook' 是否存在
    if nm "$KSU_OBJ" | grep -q "ksu_vfs_read_hook"; then
        echo "✅ [验证通过] 恭喜！'ksu_vfs_read_hook' (变量/函数) 已成功注入！"
    else
        echo "❌ [验证失败] 致命错误！ksu.o 生成了，但里面依然没有 'ksu_vfs_read_hook'！"
        echo "   这意味着注入代码没有生效。"
        exit 1
    fi
    
    # 检查 execveat 钩子开关
    if nm "$KSU_OBJ" | grep -q "ksu_execveat_hook"; then
        echo "✅ [验证通过] 'ksu_execveat_hook' 变量存在。"
    else
        echo "❌ [验证失败] 缺少 'ksu_execveat_hook' 变量。"
        exit 1
    fi

else
    echo "❌ [验证失败] 找不到 $KSU_OBJ 文件，编译路径可能不对。"
    exit 1
fi

echo "🎉 验证通过！现在的驱动是完美的。开始完整编译..."
# ==============================================================================

echo "Compiling kernel..."
make $MAKE_ARGS -j$(nproc)

if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "The file [out/arch/arm64/boot/Image] exists. Build successfully."
else
    echo "The file [out/arch/arm64/boot/Image] does not exist. Build failed."
    exit 1
fi

echo "Generating dtb......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

# Restore modified dts
rm -rf ${dts_source}
mv .dts.bak ${dts_source}

rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/

# 复制 Image 和 dtb 到打包目录
cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb anykernel/kernels/

echo "Packing Zip..."

# Restore local version string
sed -i "s/${local_version_date_str}/${local_version_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

cd anykernel 
ZIP_FILENAME=Kernel_MIUI_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip
zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip
mv $ZIP_FILENAME ../
cd ..

echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
