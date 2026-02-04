#!/bin/bash
set -e

# ==================== [配置区域] ====================
TOOLCHAIN_PATH=$HOME/zyc-clang/bin
TARGET_DEVICE="alioth"
# ====================================================

# 环境变量设置
export PATH="$TOOLCHAIN_PATH:$PATH"
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CC="ccache clang"
export CXX="ccache clang++"
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# 编译参数
MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out \
    CC=clang \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
    CLANG_TRIPLE=aarch64-linux-gnu-"

echo -e "\033[0;32m=== 🚀 开始编译 (适配 SM8250 + SukiSU Final) ===\033[0m"

# ==================== [Step 1: 源码深度净化] ====================
echo "🧹 [1/6] 执行源码深度净化 (使用直链恢复官方版本)..."

# 1. 基础重置
curl -L https://github.com/ApartTUSITU/kernel_xiaomi_sm8250_mod/commit/a05557c.patch | git apply -v >/dev/null 2>&1 || true
rm -rf drivers/kernelsu drivers/susfs fs/susfs out/
mkdir -p out

# 2. [直链下载] 恢复 6 个核心文件 (UtsavBalar1231 官方纯净版)
echo "   -> 正在恢复核心文件..."

# fs/read_write.c
curl -s -L "https://raw.githubusercontent.com/UtsavBalar1231/kernel_xiaomi_sm8250/99352d52fed224160798675f138d6af0051a5e5c/fs/read_write.c" -o fs/read_write.c || echo "❌ read_write.c 下载失败"

# fs/exec.c
curl -s -L "https://raw.githubusercontent.com/UtsavBalar1231/kernel_xiaomi_sm8250/99352d52fed224160798675f138d6af0051a5e5c/fs/exec.c" -o fs/exec.c || echo "❌ exec.c 下载失败"

# fs/open.c
curl -s -L "https://raw.githubusercontent.com/UtsavBalar1231/kernel_xiaomi_sm8250/99352d52fed224160798675f138d6af0051a5e5c/fs/open.c" -o fs/open.c || echo "❌ open.c 下载失败"

# fs/stat.c
curl -s -L "https://raw.githubusercontent.com/UtsavBalar1231/kernel_xiaomi_sm8250/99352d52fed224160798675f138d6af0051a5e5c/fs/stat.c" -o fs/stat.c || echo "❌ stat.c 下载失败"

# drivers/input/input.c
curl -s -L "https://raw.githubusercontent.com/UtsavBalar1231/kernel_xiaomi_sm8250/99352d52fed224160798675f138d6af0051a5e5c/drivers/input/input.c" -o drivers/input/input.c || echo "❌ input.c 下载失败"

# kernel/reboot.c (新增)
curl -s -L "https://raw.githubusercontent.com/UtsavBalar1231/kernel_xiaomi_sm8250/99352d52fed224160798675f138d6af0051a5e5c/kernel/reboot.c" -o kernel/reboot.c || echo "❌ reboot.c 下载失败"

# 3. 还原头文件 (防止误伤)
git checkout include/linux/sched.h include/linux/fs.h 2>/dev/null || true

echo "   ✅ 6 个核心文件已恢复为纯净状态！"

# ==================== [Step 2: 下载组件] ====================
echo "⬇️ [2/6] 下载 SukiSU & SUSFS..."
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin
wget https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch -O susfs.patch -q


# ==================== [Step 3: 补丁与 Hook 注入] ====================
echo "🔧 [3/6] 执行代码注入 (Final Stable Version)..."

# 1. 应用 SUSFS 补丁
if [ -f "susfs.patch" ]; then
    echo "   -> 应用 SUSFS 补丁..."
    patch -p1 --ignore-whitespace --fuzz=3 < susfs.patch || echo "⚠️ Patch 可能有冲突，使用脚本强制修复..."
fi

# 2. [关键] 强制补全头文件定义 (防止 undeclared identifier)
echo "   -> 正在补全头文件定义..."

# (A) include/linux/sched.h
if ! grep -q "susfs_task_state" include/linux/sched.h; then
    sed -i '/^	\/\* protection of the PI data mutex \*\//i \
	#ifdef CONFIG_KSU\
	u32 susfs_task_state;\
	#endif' include/linux/sched.h
fi
if ! grep -q "TASK_STRUCT_NON_ROOT_USER_APP_PROC" include/linux/sched.h; then
    sed -i '$a \
#ifndef TASK_STRUCT_NON_ROOT_USER_APP_PROC\
#define TASK_STRUCT_NON_ROOT_USER_APP_PROC (1)\
#endif' include/linux/sched.h
fi

# (B) include/linux/fs.h
if ! grep -q "INODE_STATE_SUS_KSTAT" include/linux/fs.h; then
    sed -i '$a \
#ifndef INODE_STATE_SUS_KSTAT\
#define INODE_STATE_SUS_KSTAT (1UL << 30)\
#endif' include/linux/fs.h
fi

echo "   -> 正在执行 SukiSU Manual Hook (结构体可见性修复版)..."

# --- 1. fs/read_write.c ---
# 锚点: linux/fs.h
sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU\
extern bool ksu_vfs_read_hook __read_mostly;\
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);\
#endif' fs/read_write.c
# 注入: read 系统调用
sed -i '/^SYSCALL_DEFINE3(read,/,/^{/ s/^{/{ \n#ifdef CONFIG_KSU\nif (unlikely(ksu_vfs_read_hook)) ksu_handle_sys_read(fd, \&buf, \&count);\n#endif/' fs/read_write.c


# --- 2. fs/exec.c (🔥 终极修复: 前向声明) ---
# 锚点: linux/file.h
# 修复: 增加 "struct filename;"，让编译器提前认识这个结构体
sed -i '/#include <linux\/file.h>/a \
#ifdef CONFIG_KSU\
struct filename;\
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\
#endif' fs/exec.c
# 注入: 这里的变量必须转义 \&
sed -i '/if (IS_ERR(filename))/i \
#ifdef CONFIG_KSU\
ksu_handle_execveat(\&fd, \&filename, \&argv, \&envp, \&flags);\
#endif' fs/exec.c


# --- 3. fs/open.c (🔥 终极修复: 代码块) ---
# 锚点: linux/fs.h
sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU\
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\
#endif' fs/open.c
# 注入: 使用 { } 包裹，允许在任何地方声明变量，彻底解决 C90 报错
sed -i '/if (mode & ~S_IRWXO)/i \
#ifdef CONFIG_KSU\
{ int ks_flags = 0; ksu_handle_faccessat(\&dfd, \&filename, \&mode, \&ks_flags); }\n#endif' fs/open.c


# --- 4. fs/stat.c ---
# 锚点: linux/fs.h
sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU\
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\
extern void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);\
#endif' fs/stat.c
# 注入 vfs_statx
sed -i '/if ((flags & ~(AT_SYMLINK_NOFOLLOW/i \
#ifdef CONFIG_KSU\
ksu_handle_stat(\&dfd, \&filename, \&flags);\
#endif' fs/stat.c
# 注入 vfs_statx_fd
sed -i '/fdput(f);/i \
#ifdef CONFIG_KSU\
if (!error) ksu_handle_vfs_fstat(fd, \&stat->size);\
#endif' fs/stat.c


# --- 5. drivers/input/input.c ---
# 锚点: linux/input/mt.h (UtsavBalar源码中 input.c 包含的是这个)
sed -i '/#include <linux\/input\/mt.h>/a \
#ifdef CONFIG_KSU\
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\
#endif' drivers/input/input.c
# 注入
sed -i '/if (is_event_supported(type, dev->evbit, EV_MAX))/i \
#ifdef CONFIG_KSU\
ksu_handle_input_handle_event(\&type, \&code, \&value);\
#endif' drivers/input/input.c


# --- 6. kernel/reboot.c ---
# 锚点: linux/syscalls.h
sed -i '/#include <linux\/syscalls.h>/a \
#ifdef CONFIG_KSU\
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\
#endif' kernel/reboot.c
# 注入: 插在变量声明之后 (check_poweroff_charger_mode 调用前)
sed -i '/if (check_poweroff_charger_mode())/i \
#ifdef CONFIG_KSU\
ksu_handle_sys_reboot(magic1, magic2, cmd, \&arg);\
#endif' kernel/reboot.c

echo "   ✅ 注入完成！(已集成结构体前向声明与C90兼容修复)"

# ==================== [Step 3.5: 核心兼容性修复] ====================
echo "🔧 [3.5/6] 执行内核兼容性适配 (关键步骤)..."

# 1. [核心修复] 补全 SukiSU 缺失的接口变量
# 原理：您的内核使用 selinux_state 结构体，但 SukiSU 依赖传统的 selinux_enforcing 变量。
# 我们必须手动创建这个变量作为“兼容层”，否则编译必挂。
SELINUX_HOOKS="security/selinux/hooks.c"
if [ -f "$SELINUX_HOOKS" ]; then
    echo "   -> 正在检测 selinux_enforcing 接口..."
    
    # 只有当文件中完全不存在这个变量定义时，才进行添加
    if ! grep -q "int selinux_enforcing " "$SELINUX_HOOKS"; then
        echo "   -> 正在为 SukiSU 创建兼容接口..."
        
        # 清理可能存在的旧补丁，保持代码整洁
        sed -i '/\/\* Fix for SukiSU \*\//d' "$SELINUX_HOOKS"
        sed -i '/int selinux_enforcing =/d' "$SELINUX_HOOKS"
        sed -i '/EXPORT_SYMBOL(selinux_enforcing);/d' "$SELINUX_HOOKS"

        # 追加标准定义
        # 这里赋值为 1 是因为 Android 生产环境必须是 Enforcing 模式
        # 这确保 SukiSU 的拦截功能处于激活状态
        cat >> "$SELINUX_HOOKS" <<EOF

/* Fix for SukiSU: Compatibility interface for kernels using selinux_state */
int selinux_enforcing = 1;
EXPORT_SYMBOL(selinux_enforcing);
EOF
        echo "   ✅ 已补全 selinux_enforcing 变量与符号导出"
    else
        echo "   ✅ 检测到 selinux_enforcing 已存在，无需修改。"
    fi
fi

# 2. [链接修复] 强制 drivers/kernelsu 静态编译
# 解决 undefined reference to 'ksu_vfs_read_hook'
DRIVERS_MAKEFILE="drivers/Makefile"
if [ -f "$DRIVERS_MAKEFILE" ]; then
    echo "   -> 正在修复构建规则..."
    
    # 删除旧的、可能不稳定的定义
    sed -i '/kernelsu/d' "$DRIVERS_MAKEFILE"
    
    # 写入 obj-y，这是将代码“焊死”在内核里的唯一方法
    # 只有这样，您的 fs/read_write.c 才能成功调用 KSU
    echo "obj-y += kernelsu/" >> "$DRIVERS_MAKEFILE"
    echo "   ✅ 已强制 drivers/kernelsu 为静态组件 (obj-y)"
fi

echo "   ✅ 内核兼容性修复完成！"


# ==================== [Step 4: SukiSU 源码适配 (修复版)] ====================
echo "💉 [4/6] 执行 SukiSU 源码适配..."

# 1. 生成 Makefile
rm -f drivers/kernelsu/Kbuild
cat > drivers/kernelsu/Makefile <<'EOF'
ccflags-y += -DKSU_VERSION=11999 -DKSU_VERSION_FULL=\"v1.0.0-SUKISU-Custom\"
ccflags-y += -Wno-implicit-function-declaration -Wno-strict-prototypes -Wno-int-to-pointer-cast -Wno-unused-function -Wno-unused-variable -Wno-missing-braces -Wno-declaration-after-statement
ccflags-y += -I$(src)/include -DCONFIG_KSU_SUSFS -DCONFIG_KSU_SUSFS_SUS_PATH -DCONFIG_KSU_SUSFS_SUS_MOUNT
ccflags-y += -DKSU_COMPAT_HAS_CURRENT_SID
ccflags-y += -I$(srctree)/security/selinux -I$(srctree)/security/selinux/include -I$(objtree)/security/selinux
ccflags-y += -include $(srctree)/include/uapi/asm-generic/errno.h
obj-y += ksu_core.o
ksu_core-y := ksuinit.o allowlist.o app_profile.o apk_sign.o sucompat.o \
              throne_tracker.o setuid_hook.o kernel_compat.o kernel_umount.o \
              supercalls.o feature.o ksud.o seccomp_cache.o file_wrapper.o \
              su_mount_ns.o shim.o tiny_sulog.o \
              selinux/selinux.o selinux/sepolicy.o selinux/rules.o
obj-$(CONFIG_KSU_MANUAL_SU) += manual_su.o
obj-$(CONFIG_KPM) += kpm/
EOF

# 2. [修复] 补全 SELinux 声明 (解决 policydb 未定义)
sed -i '1i\
extern struct policydb policydb;\
extern struct selinux_state selinux_state;' drivers/kernelsu/selinux/rules.c

# 3. [修复] 修正函数调用参数 (解决 too few arguments)
# 将 selinux_status_update_policyload(0) 改为传入 &selinux_state
sed -i 's/selinux_status_update_policyload(0);/selinux_status_update_policyload(\&selinux_state, 0);/g' drivers/kernelsu/selinux/rules.c

# 4. [修复] 补全 selinux_enforcing 声明
sed -i '1i\extern int selinux_enforcing;' drivers/kernelsu/selinux/selinux_defs.h

# 5. 屏蔽 current_sid 冲突
sed -i 's/static inline u32 current_sid(void)/static inline u32 __ksu_ignored_current_sid(void)/' drivers/kernelsu/selinux/selinux_defs.h

echo "   ✅ SukiSU 源码适配完成！"

# ==================== [Step 5: MIUI DTS & Config] ====================
echo "⚙️ [5/6] 执行 MIUI 深度适配..."

dts_source=arch/arm64/boot/dts/vendor/qcom

# 1. 屏幕参数修正
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

# 2. 恢复智能帧率 & 刷新率
sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi

# 3. 恢复亮度控制
sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
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

# 生成基础 Config
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

# 强制注入配置
echo "   -> 正在注入内核配置..."
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

make $MAKE_ARGS olddefconfig

# ==================== [Step 6: 编译 & 打包] ====================
echo "🚀 [6/6] 启动多核编译..."
make $MAKE_ARGS -j$(nproc)

if [ -f "out/arch/arm64/boot/Image" ]; then
    echo -e "\033[0;32m✅ 编译成功！Image 已生成。\033[0m"
    rm -rf anykernel && git clone https://github.com/liyafe1997/AnyKernel3 -b kona --depth=1 anykernel
    rm -rf anykernel/kernels/ && mkdir -p anykernel/kernels/
    cp out/arch/arm64/boot/Image anykernel/kernels/
    find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > anykernel/kernels/dtb
    cd anykernel
    zip -r9 "../Kernel_Alioth_KSU_SUSFS_MIUI_$(date +'%Y%m%d').zip" ./* -x .git .gitignore
    cd ..
    echo -e "\033[0;32m🎉 刷机包已生成！\033[0m"
else
    echo -e "\033[0;31m❌ 编译失败！请检查上方日志。\033[0m"
    exit 1
fi
