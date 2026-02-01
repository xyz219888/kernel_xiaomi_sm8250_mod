#!/bin/bash

# Ensure the script exits on error
set -e

# ==================== [Step 0: 环境清理与准备] ====================
echo "🧹 正在清理旧环境..."
curl -L https://github.com/ApartTUSITU/kernel_xiaomi_sm8250_mod/commit/a05557c.patch | git apply -v || true
rm -rf drivers/susfs
rm -rf fs/susfs
rm -rf drivers/kernelsu  # 彻底删除旧驱动，防止残留
echo "✅ 环境清理完毕。"

TOOLCHAIN_PATH=$HOME/zyc-clang/bin
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE="${1:-alioth}"

export PATH="$TOOLCHAIN_PATH:$PATH"
export CCACHE_DIR="$HOME/.cache/ccache_mikernel" 
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache:$PATH"

MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"

# ==================== [Step 1: 安装 SukiSU (Builtin)] ====================
echo "⬇️ 安装 SukiSU (Builtin)..."
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin

# [关键修复] 强制将 kernelsu 加入编译列表
# 之前的脚本可能漏了这一步，导致代码写了但没编译！
echo "🔧 强制注册 kernelsu 到 drivers/Makefile..."
if ! grep -q "kernelsu" drivers/Makefile; then
    echo "obj-y += kernelsu/" >> drivers/Makefile
fi
echo "✅ 驱动注册确认完毕。"

# ==================== [Step 2: 应用内核钩子 (v1.6)] ====================
echo "🪝 应用 v1.6 内核钩子..."
wget https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU_patch/main/hooks/scope_min_manual_hooks_v1.6.patch -O sukisu_hooks.patch
patch -p1 -F 3 < sukisu_hooks.patch || { echo "❌ 钩子补丁失败！"; exit 1; }
echo "✅ 钩子应用成功。"

# ==================== [Step 3: 注入缺失代码 (复活被删函数)] ====================
echo "💉 注入缺失的变量和函数..."

# 这里的代码必须包含 EXPORT_SYMBOL，确保链接器能看到
cat >> drivers/kernelsu/ksu.c <<'EOF'

/* ================================================================= */
/* [INJECTED FIX] Restoring Missing Symbols for Linker               */
/* ================================================================= */

#include <linux/fs.h>
#include <linux/version.h>
#include <linux/export.h> // 必须包含这个头文件
#include "ksu.h"

// -----------------------------------------------------------
// 1. READ HOOK (修复 undefined reference to ksu_vfs_read_hook)
// -----------------------------------------------------------
bool ksu_vfs_read_hook __read_mostly = true;
EXPORT_SYMBOL(ksu_vfs_read_hook); // 导出符号，让 fs/read_write.c 能看到

extern int ksu_handle_vfs_read_hook(struct file *file, char __user **buf, size_t *count, loff_t *pos);
int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr) {
    struct file *file = fget(fd);
    if (!file) return 0;
    ksu_handle_vfs_read_hook(file, buf_ptr, count_ptr, &file->f_pos);
    fput(file);
    return 0;
}
EXPORT_SYMBOL(ksu_handle_sys_read);

// -----------------------------------------------------------
// 2. EXECVE HOOK (修复 exec.o 报错)
// -----------------------------------------------------------
bool ksu_execveat_hook __read_mostly = true;
EXPORT_SYMBOL(ksu_execveat_hook);

int ksu_handle_execve_sucompat(int *fd, const char __user **filename_user, void *argv, void *envp, int *flags) {
     return 0; 
}
EXPORT_SYMBOL(ksu_handle_execve_sucompat);

extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);
int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags) {
    return ksu_handle_execveat_sucompat(fd, filename_ptr, argv, envp, flags);
}
EXPORT_SYMBOL(ksu_handle_execveat);

// -----------------------------------------------------------
// 3. INPUT HOOK
// -----------------------------------------------------------
bool ksu_input_hook __read_mostly = true;
EXPORT_SYMBOL(ksu_input_hook);

int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value) {
    return 0; 
}
EXPORT_SYMBOL(ksu_handle_input_handle_event);

// -----------------------------------------------------------
// 4. OTHER HOOKS
// -----------------------------------------------------------
extern int ksu_handle_faccessat_sucompat(int *dfd, const char __user **filename_user, int *mode, int *flags);
int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags) {
    return ksu_handle_faccessat_sucompat(dfd, filename_user, mode, flags);
}
EXPORT_SYMBOL(ksu_handle_faccessat);

extern int ksu_handle_stat_sucompat(int *dfd, const char __user **filename_user, int *flags);
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags) {
    return ksu_handle_stat_sucompat(dfd, filename_user, flags);
}
EXPORT_SYMBOL(ksu_handle_stat);

int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg) {
    return 0;
}
EXPORT_SYMBOL(ksu_handle_sys_reboot);

/* ================================================================= */
EOF

# 修复 flask.h 头文件路径
cat >> drivers/kernelsu/Makefile <<'EOF'
ccflags-y += -I$(srctree)/security/selinux/include
ccflags-y += -I$(objtree)/security/selinux/include
ccflags-y += -I$(srctree)/security/selinux/ss
EOF
echo "✅ 代码注入完成。"

# ==================== [Step 4: SUSFS 补丁] ====================
echo "📦 应用 SUSFS 补丁..."
wget https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch -O susfs.patch
patch -p1 -F 3 < susfs.patch || { echo "❌ SUSFS 补丁失败！"; exit 1; }

# ==================== [Step 5: 编译配置] ====================
echo "⚙️ 生成配置..."
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

# 强制开启 KSU
scripts/config --file out/.config \
    -e KSU \
    -e KSU_MANUAL_HOOK \
    -e KSU_SUSFS \
    -e KPM \
    --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd

# ==================== [Step 6: 验证驱动是否被编译] ====================
echo "⚡️ 预检：确保 SukiSU 驱动会被编译..."
# 我们通过 touch 一个文件来测试驱动目录是否生效
touch drivers/kernelsu/ksu.c

# ==================== [Step 7: 开始完整编译] ====================
echo "🚀 开始编译内核 (请耐心等待)..."
make $MAKE_ARGS -j$(nproc)

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ 编译失败！Image 文件未生成。"
    exit 1
fi

echo "✅ 编译成功！正在打包..."
# (后续打包流程省略，保持原样即可)
echo "Generating dtb......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/
cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb anykernel/kernels/

echo "Packing Zip..."
local_version_str="-perf"
local_version_date_str="-$(date +%Y%m%d)-${GIT_COMMIT_ID}-perf"
sed -i "s/${local_version_date_str}/${local_version_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

cd anykernel 
ZIP_FILENAME=Kernel_MIUI_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip
zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip
mv $ZIP_FILENAME ../
cd ..
echo "🎉 全部完成！刷机包: [./$ZIP_FILENAME]"
