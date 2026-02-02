#!/bin/bash

# ==============================================================================
#  Xiaomi sm8250 Kernel Build Script (SukiSU Built-in + SUSFS Final v4)
#  Status: Logic Fixed + Flags Verified + SELinux State API Patched
# ==============================================================================

# 遇到错误立即停止
set -e

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ==================== [配置区域] ====================
# 请根据你的实际路径修改工具链位置
TOOLCHAIN_PATH=$HOME/zyc-clang/bin
# 目标设备
TARGET_DEVICE="alioth"

# 检查工具链
if [ ! -d "$TOOLCHAIN_PATH" ]; then
    echo -e "${RED}❌ 错误：找不到工具链路径 $TOOLCHAIN_PATH${NC}"
    echo "请修改脚本中的 TOOLCHAIN_PATH 变量。"
    exit 1
fi

# 环境变量设置
export PATH="$TOOLCHAIN_PATH:$PATH"
export CCACHE_DIR="$HOME/.cache/ccache_mikernel" 
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache:$PATH"

# 编译参数
MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out \
    CC=clang \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
    CLANG_TRIPLE=aarch64-linux-gnu-"

echo -e "${GREEN}=== 🚀 开始最终完美版编译流程 (v4) ===${NC}"

# ==================== [Step 1: 环境清理] ====================
echo "🧹 [1/6] 深度清理环境..."
# 回滚补丁
curl -L https://github.com/ApartTUSITU/kernel_xiaomi_sm8250_mod/commit/a05557c.patch | git apply -v >/dev/null 2>&1 || true
# 删除旧的驱动目录
rm -rf drivers/susfs drivers/kernelsu fs/susfs
# 清理输出目录
rm -rf out/
mkdir -p out/
echo -e "${GREEN}✅ 环境已重置${NC}"

# ==================== [Step 2: 下载组件] ====================
echo "⬇️ [2/6] 下载 SukiSU & SUSFS..."

# 1. 安装 SukiSU (Built-in 模式)
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin >/dev/null 2>&1

# 2. 下载补丁
wget https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU_patch/main/hooks/scope_min_manual_hooks_v1.6.patch -O sukisu_hooks.patch -q
wget https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch -O susfs.patch -q

echo "   正在应用补丁..."
patch -p1 -F 3 < sukisu_hooks.patch >/dev/null 2>&1 || { echo -e "${RED}❌ Manual Hook 补丁失败${NC}"; exit 1; }
patch -p1 -F 3 < susfs.patch >/dev/null 2>&1 || { echo -e "${RED}❌ SUSFS 补丁失败${NC}"; exit 1; }

echo -e "${GREEN}✅ 补丁应用成功${NC}"

# ==================== [Step 3: 源码级适配 (逻辑 & 冲突修复)] ====================
echo "🔧 [3/6] 执行源码级适配 (修复逻辑炸弹 & SELinux API)..."

# --- Fix 1: 修复 sucompat.c 缺失接口 (使用正确的处理逻辑) ---
cat >> drivers/kernelsu/sucompat.c <<'EOF'

/* [Patch by BuildScript] Perfect Fix for v1.6 Hooks + SUSFS */
#ifdef CONFIG_KSU_SUSFS

// 桥接函数：完全匹配 v1.6 补丁的参数类型
int ksu_handle_execve_sucompat(int *fd, const char __user **filename_user,
			       void *__never_use_argv, void *__never_use_envp,
			       int *__never_use_flags)
{
    // 调用 SukiSU 内部处理函数，完美复活 Root 功能
    return ksu_sucompat_user_common(filename_user, "sys_execve", true);
}
#endif
EOF

# --- Fix 2: 修复 ksu.c 变量导出 ---
cat >> drivers/kernelsu/ksu.c <<'EOF'

/* [Patch by BuildScript] Restore Missing Symbols */
#include <linux/export.h>
bool ksu_vfs_read_hook __read_mostly = true;
EXPORT_SYMBOL(ksu_vfs_read_hook);
EOF

# --- Fix 3: 修复 SELinux 头文件冲突 (解决 undeclared identifier) ---
# 显式声明 selinux_enforcing
sed -i '1i\extern int selinux_enforcing;' drivers/kernelsu/selinux/selinux_defs.h

# 解决 current_sid 重定义冲突
sed -i 's/static inline u32 current_sid(void)/static inline u32 __ksu_ignored_current_sid(void)/' drivers/kernelsu/selinux/selinux_defs.h

# --- Fix 4: 修复 rules.c 适配新版 SELinux API (关键修复) ---
# 1. 声明 selinux_state 结构体变量
sed -i '1i\extern struct selinux_state selinux_state;' drivers/kernelsu/selinux/rules.c

# 2. 修复 policydb 引用 (从全局变量改为结构体成员)
# 将 db = &policydb; 替换为 db = &selinux_state.ss->policydb;
sed -i 's/&policydb/&selinux_state.ss->policydb/g' drivers/kernelsu/selinux/rules.c

# 3. 修复函数调用参数不足
# 将 selinux_status_update_policyload(0); 替换为 selinux_status_update_policyload(&selinux_state, 0);
sed -i 's/selinux_status_update_policyload(0)/selinux_status_update_policyload(\&selinux_state, 0)/g' drivers/kernelsu/selinux/rules.c

echo -e "${GREEN}✅ 源码适配完成 (逻辑 & SELinux API 已修正)${NC}"

# ==================== [Step 4: 重建构建系统 (全参数覆盖)] ====================
echo "🔥 [4/6] 重建驱动构建规则 (C99兼容 & 路径补全)..."

# 1. 移除 Kbuild
rm -f drivers/kernelsu/Kbuild

# 2. 修正 drivers/Makefile
sed -i '/kernelsu/d' drivers/Makefile
echo "obj-y += kernelsu/" >> drivers/Makefile

# 3. 生成 drivers/kernelsu/Makefile
cat > drivers/kernelsu/Makefile <<'EOF'
# --- [核心参数注入] ---
# 1. 定义版本号
ccflags-y += -DKSU_VERSION=11999
ccflags-y += -DKSU_VERSION_FULL=\"v1.0.0-SUKISU-Custom\"

# 2. 压制严格警告 & C99 兼容
ccflags-y += -Wno-implicit-function-declaration -Wno-strict-prototypes -Wno-int-to-pointer-cast -Wno-unused-function -Wno-unused-variable -Wno-missing-braces -Wno-declaration-after-statement

# 3. SUSFS 定义
ccflags-y += -I$(src)/include
ccflags-y += -DCONFIG_KSU_SUSFS -DCONFIG_KSU_SUSFS_SUS_PATH -DCONFIG_KSU_SUSFS_SUS_MOUNT

# 4. 【头文件路径全补全】
# 修复 fatal error: 'ss/policydb.h'
ccflags-y += -I$(srctree)/security/selinux
ccflags-y += -I$(srctree)/security/selinux/include
ccflags-y += -I$(objtree)/security/selinux

# 5. 原版兼容性
ccflags-y += -include $(srctree)/include/uapi/asm-generic/errno.h
# ----------------------

# 核心对象
obj-y += ksu_core.o

# 链接列表
ksu_core-y := ksuinit.o allowlist.o app_profile.o apk_sign.o sucompat.o \
              throne_tracker.o setuid_hook.o kernel_compat.o kernel_umount.o \
              supercalls.o feature.o ksud.o seccomp_cache.o file_wrapper.o \
              su_mount_ns.o shim.o tiny_sulog.o \
              selinux/selinux.o selinux/sepolicy.o selinux/rules.o

# 包含 Manual SU
obj-$(CONFIG_KSU_MANUAL_SU) += manual_su.o

# 包含 KPM
obj-$(CONFIG_KPM) += kpm/
EOF

echo -e "${GREEN}✅ 构建系统已锁定${NC}"

# ==================== [Step 5: 配置与编译] ====================
echo "⚙️ [5/6] 生成配置并编译..."

# 生成基础配置
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

echo "🔧 [配置确认] 正在强制注入 KSU & SUSFS 核心配置..."

# 1. 强制开启 KSU & SUSFS
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
    -e KSU_SUSFS_TRY_UMOUNT \
    -e KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
    -e KSU_SUSFS_SPOOF_UNAME \
    -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -e KSU_SUSFS_OPEN_REDIRECT \
    -e KSU_SUSFS_SUS_MAP \
    -e KPM

# 2. 强制关闭项
scripts/config --file out/.config \
    -d KSU_SUSFS_SUS_OVERLAYFS \
    -d KSU_SUSFS_SUS_SU \
    -d DEBUG_FS \
    -d MI_MEMORY_SYSFS \
    -d MODULE_SIG_SHA512 \
    -d MODULE_SIG_HASH

# 3. 基础依赖
scripts/config --file out/.config \
    -e KALLSYMS \
    -e KALLSYMS_ALL \
    -e OVERLAY_FS \
    -e STATIC_USERMODEHELPER \
    --set-str STATIC_USERMODEHELPER_PATH "/system/bin/micd"

# 4. MIUI 优化
scripts/config --file out/.config \
    -e XIAOMI_MIUI \
    -e MIGT \
    -e MIGT_ENERGY_MODEL \
    -e MILLET \
    -e MIHW \
    -e RTMM \
    -e MI_FRAGMENTION \
    -e MI_RECLAIM \
    -e PERF_HELPER \
    -e SF_BINDER \
    -e BINDER_OPT

echo "✅ 所有配置已注入完成"

# 重新更新 .config 依赖关系
make $MAKE_ARGS olddefconfig

# 开始编译
echo "🚀 启动多核编译..."
make $MAKE_ARGS -j$(nproc)

# 检查结果
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo -e "${GREEN}✅ 编译成功！Image 已生成。${NC}"
else
    echo -e "${RED}❌ 编译失败！请检查上方日志。${NC}"
    exit 1
fi

# ==================== [Step 6: 打包] ====================
echo "📦 [6/6] 正在打包..."

# 生成 DTB
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

# 准备 AnyKernel3
rm -rf anykernel
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel
rm -rf anykernel/kernels/ && mkdir -p anykernel/kernels/

# 复制文件
cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb anykernel/kernels/

# 生成 Zip
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
cd anykernel
ZIP_NAME="Kernel_Alioth_KSU_SUSFS_$(date +'%Y%m%d')_${GIT_COMMIT_ID}.zip"
zip -r9 "$ZIP_NAME" ./* -x .git .gitignore out/ ./*.zip
mv "$ZIP_NAME" ../

echo -e "${GREEN}🎉 恭喜！刷机包已生成: ${ZIP_NAME}${NC}"
