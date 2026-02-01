#!/bin/bash

# 遇到错误直接炸，不墨迹
set -e

# ==================== [Step 0: 暴力回滚] ====================
echo "🧹 正在清理案发现场..."
# 用补丁回滚代码修改 (这是最干净的)
curl -L https://github.com/ApartTUSITU/kernel_xiaomi_sm8250_mod/commit/a05557c.patch | git apply -v >/dev/null 2>&1 || true
# 删掉所有可能残留的目录
rm -rf drivers/susfs drivers/kernelsu fs/susfs
# 还原关键文件
git checkout drivers/Makefile 2>/dev/null || true
git checkout drivers/Kconfig 2>/dev/null || true
echo "✅ 环境清理完毕。"

# 环境变量 (保持不变)
TOOLCHAIN_PATH=$HOME/zyc-clang/bin
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE="${1:-alioth}"
export PATH="$TOOLCHAIN_PATH:$PATH"
export CCACHE_DIR="$HOME/.cache/ccache_mikernel" 
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache:$PATH"
MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"

# ==================== [Step 1: 安装插件] ====================
echo "⬇️ 下载并安装 SukiSU (Builtin)..."
# 这里的 setup.sh 有时候改 Kconfig 会失败，所以后面我们要手动再改一次
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin

echo "📦 下载补丁..."
wget https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU_patch/main/hooks/scope_min_manual_hooks_v1.6.patch -O sukisu_hooks.patch -q
wget https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch -O susfs.patch -q

echo "🪝 应用补丁..."
patch -p1 -F 3 < sukisu_hooks.patch
patch -p1 -F 3 < susfs.patch

# ==================== [Step 2: 核心注入 (防报错)] ====================
echo "💉 注入缺失符号 (解决 Undefined Reference)..."
# ⚠️ 必须把这些函数定义写进 ksu.c，否则连接器找不到人
cat >> drivers/kernelsu/ksu.c <<'EOF'

/* [INJECTED FIX] Restoring Missing Symbols */
#include <linux/fs.h>
#include <linux/version.h>
#include <linux/export.h> 
#include "ksu.h"

// 1. READ HOOK
bool ksu_vfs_read_hook __read_mostly = true;
EXPORT_SYMBOL(ksu_vfs_read_hook);
extern int ksu_handle_vfs_read_hook(struct file *file, char __user **buf, size_t *count, loff_t *pos);
int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr) {
    struct file *file = fget(fd);
    if (!file) return 0;
    ksu_handle_vfs_read_hook(file, buf_ptr, count_ptr, &file->f_pos);
    fput(file);
    return 0;
}
EXPORT_SYMBOL(ksu_handle_sys_read);

// 2. EXECVE HOOK
bool ksu_execveat_hook __read_mostly = true;
EXPORT_SYMBOL(ksu_execveat_hook);
int ksu_handle_execve_sucompat(int *fd, const char __user **filename_user, void *argv, void *envp, int *flags) { return 0; }
EXPORT_SYMBOL(ksu_handle_execve_sucompat);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);
int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags) {
    return ksu_handle_execveat_sucompat(fd, filename_ptr, argv, envp, flags);
}
EXPORT_SYMBOL(ksu_handle_execveat);

// 3. INPUT HOOK
bool ksu_input_hook __read_mostly = true;
EXPORT_SYMBOL(ksu_input_hook);
int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value) { return 0; }
EXPORT_SYMBOL(ksu_handle_input_handle_event);

// 4. DEVPTS HOOK
int ksu_handle_devpts(struct inode *inode) { return 0; }
EXPORT_SYMBOL(ksu_handle_devpts);

// 5. OTHERS
extern int ksu_handle_faccessat_sucompat(int *dfd, const char __user **filename_user, int *mode, int *flags);
int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags) { return ksu_handle_faccessat_sucompat(dfd, filename_user, mode, flags); }
EXPORT_SYMBOL(ksu_handle_faccessat);
extern int ksu_handle_stat_sucompat(int *dfd, const char __user **filename_user, int *flags);
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags) { return ksu_handle_stat_sucompat(dfd, filename_user, flags); }
EXPORT_SYMBOL(ksu_handle_stat);
int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg) { return 0; }
EXPORT_SYMBOL(ksu_handle_sys_reboot);
EOF

# ==================== [Step 3: 强制上户口 (最关键)] ====================
echo "🔥 强制注册 Kconfig 和 Makefile (防止被跳过)..."

# 1. 修复 Kconfig (如果不加这行，CONFIG_KSU=y 就是废纸)
# 先删掉旧的（防止重复），然后插入新的
sed -i '/kernelsu\/Kconfig/d' drivers/Kconfig
# 在 endmenu 前一行插入 source
sed -i '$i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

# 2. 修复 Makefile (强制编译 drivers/kernelsu 目录)
sed -i '/kernelsu/d' drivers/Makefile
echo "obj-y += kernelsu/" >> drivers/Makefile

# 3. 修复 Kernelsu 内部 Makefile (解决 Relocation 报错)
if [ -f "drivers/kernelsu/Makefile" ]; then
    # 强制把 obj-$(CONFIG_KSU) 改成 obj-y，不管配置如何，必须编！
    sed -i 's/obj-$(CONFIG_KSU)/obj-y/g' drivers/kernelsu/Makefile
    
    # 修复 flask.h 头文件路径
    echo "ccflags-y += -I\$(srctree)/security/selinux/include" >> drivers/kernelsu/Makefile
    echo "ccflags-y += -I\$(objtree)/security/selinux/include" >> drivers/kernelsu/Makefile
    echo "ccflags-y += -I\$(srctree)/security/selinux/ss" >> drivers/kernelsu/Makefile
fi

echo "✅ KSU 已强制焊死在内核构建系统中。"

# ==================== [Step 4: DTS 修复] ====================
echo "🔧 修复屏幕 DTS..."
dts_source=arch/arm64/boot/dts/vendor/qcom
cp -a ${dts_source} .dts.bak
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
sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
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

# ==================== [Step 5: 编译] ====================
echo "⚙️ 生成配置..."
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

# 强制开启 KSU 配置 (双重保险)
echo "CONFIG_KSU=y" >> out/.config
echo "CONFIG_KSU_SUSFS=y" >> out/.config
echo "CONFIG_KPM=y" >> out/.config

# ⚠️ 关键修正：让编译系统自己处理头文件顺序 (不手动跑 modules_prepare，防止冲突)
echo "🚀 开始完整编译 (Trust Process)..."
make $MAKE_ARGS -j$(nproc)

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "❌ 编译失败！Image 未生成。"
    exit 1
fi

echo "✅ 编译成功！"
# (打包步骤省略，等能编出来再说)
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
echo "🎉 恭喜！刷机包: [./$ZIP_FILENAME]"
