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
cat >> drivers/kernelsu/ksu.c <<'EOF'

/* ========================================================================== */
/* [INJECTED CODE] Restoring Missing Hooks & Variables for Non-GKI 4.19       */
/* This section fixes "undefined reference" linker errors.                    */
/* ========================================================================== */

#include <linux/fs.h>
#include <linux/version.h>
#include "ksu.h"

// 1. READ HOOK
bool ksu_vfs_read_hook __read_mostly = true;
extern int ksu_handle_vfs_read_hook(struct file *file, char __user **buf, size_t *count, loff_t *pos);
int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr) {
    struct file *file;
    file = fget(fd);
    if (!file) return 0;
    ksu_handle_vfs_read_hook(file, buf_ptr, count_ptr, &file->f_pos);
    fput(file);
    return 0;
}

// 2. INPUT HOOK
bool ksu_input_hook __read_mostly = true;
int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value) {
    return 0; 
}

// 3. EXECVE HOOK
int ksu_handle_execve_sucompat(int *fd, const char __user **filename_user, void *argv, void *envp, int *flags) {
     return 0; 
}
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);
int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags) {
    return ksu_handle_execveat_sucompat(fd, filename_ptr, argv, envp, flags);
}

// 4. FACCESSAT & STAT HOOK
extern int ksu_handle_faccessat_sucompat(int *dfd, const char __user **filename_user, int *mode, int *flags);
int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags) {
    return ksu_handle_faccessat_sucompat(dfd, filename_user, mode, flags);
}
extern int ksu_handle_stat_sucompat(int *dfd, const char __user **filename_user, int *flags);
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags) {
    return ksu_handle_stat_sucompat(dfd, filename_user, flags);
}

// 5. REBOOT HOOK
int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg) {
    return 0;
}
/* ========================================================================== */
EOF

# ==================== [Step 3.1: 修复 flask.h 头文件找不到的问题] ====================
echo "Fixing missing header includes in drivers/kernelsu/Makefile..."
# 强制把 SELinux 的头文件路径加到 KSU 的编译参数里
# 这样编译器就能找到 flask.h 和 avtab.h 了
if [ -f "drivers/kernelsu/Makefile" ]; then
    sed -i '$a ccflags-y += -I$(srctree)/security/selinux/include' drivers/kernelsu/Makefile
    sed -i '$a ccflags-y += -I$(srctree)/security/selinux/ss' drivers/kernelsu/Makefile
    echo "✅ Added SELinux include paths to drivers/kernelsu/Makefile"
fi

# ==================== [Step 4: 注入 SUSFS (源码 Patch)] ====================
echo "Downloading and applying SUSFS Patch..."
wget https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch -O susfs.patch

echo "Applying SUSFS patch..."
patch -p1 -F 3 < susfs.patch || { echo "❌ SUSFS Patch Failed!"; exit 1; }
echo "✅ SUSFS Patch applied successfully."

# Make Defconfig
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

# ==================== [Step 5: 配置 .config] ====================
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
    -e KALLSYMS_ALL \
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

# ==================== [光速验证环节] ====================
echo "⚡️ 正在进行光速验证 (SukiSU Driver Check)..."
make $MAKE_ARGS drivers/kernelsu/
if [ $? -ne 0 ]; then
    echo "❌ [验证失败] SukiSU 驱动编译报错！请检查上方错误日志。"
    exit 1
fi

KSU_OBJ="out/drivers/kernelsu/ksu.o"
if [ -f "$KSU_OBJ" ]; then
    if nm "$KSU_OBJ" | grep -q "ksu_vfs_read_hook"; then
        echo "✅ [验证通过] 'ksu_vfs_read_hook' (变量/函数) 已成功注入！"
    else
        echo "❌ [验证失败] 致命错误！ksu.o 中没有 'ksu_vfs_read_hook'！"
        exit 1
    fi
else
    echo "❌ [验证失败] 找不到 $KSU_OBJ 文件。"
    exit 1
fi
echo "🎉 验证通过！开始完整编译..."

# ==================== [完整编译] ====================
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

rm -rf ${dts_source}
mv .dts.bak ${dts_source}

rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/
cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb anykernel/kernels/

echo "Packing Zip..."
sed -i "s/${local_version_date_str}/${local_version_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

cd anykernel 
ZIP_FILENAME=Kernel_MIUI_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip
zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip
mv $ZIP_FILENAME ../
cd ..
echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
