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

# ==================== [Step 1: 优先级最高 - 清理] ====================
echo "🧹 [1/6] 执行深度清理..."
# 回滚可能存在的旧修改
curl -L https://github.com/ApartTUSITU/kernel_xiaomi_sm8250_mod/commit/a05557c.patch | git apply -v >/dev/null 2>&1 || true
# 删除冲突目录
rm -rf drivers/kernelsu drivers/susfs fs/susfs out/
mkdir -p out

# ==================== [Step 2: 下载组件] ====================
echo "⬇️ [2/6] 下载 SukiSU & SUSFS..."
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin
wget https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch -O susfs.patch -q


# ==================== [Step 3: 暴力注入 Manual Hook (修复版)] ====================
echo "🔧 [3/6] 执行代码暴力注入 (SukiSU 修复版)..."

# 重置文件，防止重复修改
git checkout fs/exec.c fs/open.c fs/stat.c fs/read_write.c drivers/input/input.c

# -------------------------------------------------------------------
# 1. 修改 fs/exec.c (模块加载、Root授权)
# -------------------------------------------------------------------
echo "   -> 正在修改 fs/exec.c..."
sed -i '1i\
#ifdef CONFIG_KSU\
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\
#endif' fs/exec.c

sed -i '/return __do_execve_file/i \
#ifdef CONFIG_KSU\
ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\
#endif' fs/exec.c

# -------------------------------------------------------------------
# 2. 修改 fs/open.c (核心修复：解决 C99 变量声明报错)
# -------------------------------------------------------------------
echo "   -> 正在修改 fs/open.c..."
sed -i '1i\
#ifdef CONFIG_KSU\
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\
#endif' fs/open.c

# [核心修复点] 使用 { } 包裹代码块，允许在函数中间声明 int ks_flags
# 针对 faccessat (有 dfd 参数)
sed -i '/return do_faccessat(dfd,/i \
#ifdef CONFIG_KSU\
{ int ks_flags = 0; ksu_handle_faccessat(&dfd, &filename, &mode, &ks_flags); }\
#endif' fs/open.c

# 针对 access (无 dfd 参数)
sed -i '/return do_faccessat(AT_FDCWD,/i \
#ifdef CONFIG_KSU\
{ int dfd = AT_FDCWD; int ks_flags = 0; ksu_handle_faccessat(&dfd, &filename, &mode, &ks_flags); }\
#endif' fs/open.c

# -------------------------------------------------------------------
# 3. 修改 fs/stat.c (SUSFS 隐藏文件状态)
# -------------------------------------------------------------------
echo "   -> 正在修改 fs/stat.c..."
sed -i '1i\
#ifdef CONFIG_KSU\
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\
extern void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);\
#endif' fs/stat.c

sed -i '/error = vfs_fstatat/i \
#ifdef CONFIG_KSU\
ksu_handle_stat(&dfd, &filename, &flag);\
#endif' fs/stat.c

sed -i '/return error;/i \
#ifdef CONFIG_KSU\
if (!error) ksu_handle_vfs_fstat(fd, &stat->size);\
#endif' fs/stat.c

# -------------------------------------------------------------------
# 4. 修改 fs/read_write.c (开机自启注入 init.rc)
# -------------------------------------------------------------------
echo "   -> 正在修改 fs/read_write.c..."
sed -i '1i\
#ifdef CONFIG_KSU\
extern void ksu_handle_sys_read(unsigned int fd);\
#endif' fs/read_write.c

sed -i '/return ret;/i \
#ifdef CONFIG_KSU\
if (ret > 0) ksu_handle_sys_read(fd);\
#endif' fs/read_write.c

# -------------------------------------------------------------------
# 5. 修改 drivers/input/input.c (安全模式)
# -------------------------------------------------------------------
echo "   -> 正在修改 drivers/input/input.c..."
sed -i '1i\
#ifdef CONFIG_KSU\
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\
#endif' drivers/input/input.c

sed -i '/if (disposition & INPUT_IGNORE_EVENT)/i \
#ifdef CONFIG_KSU\
ksu_handle_input_handle_event(&type, &code, &value);\
#endif' drivers/input/input.c

echo "   ✅ SukiSU Hook 代码注入全部完成！"

echo "   -> 应用 SUSFS 补丁..."
patch -p1 --ignore-whitespace --fuzz=3 < susfs.patch


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

# 2. [修复] 补充 policydb 和 selinux_state 声明
# 修复 drivers/kernelsu/selinux/rules.c 中的 "undeclared identifier"
sed -i '1i\
extern struct policydb policydb;\
extern struct selinux_state selinux_state;' drivers/kernelsu/selinux/rules.c

# 3. [修复] 修正 selinux_status_update_policyload 参数调用
# 将 selinux_status_update_policyload(0) 改为 selinux_status_update_policyload(&selinux_state, 0)
sed -i 's/selinux_status_update_policyload(0);/selinux_status_update_policyload(\&selinux_state, 0);/g' drivers/kernelsu/selinux/rules.c

# 4. 修复 selinux_enforcing 未声明错误
sed -i '1i\extern int selinux_enforcing;' drivers/kernelsu/selinux/selinux_defs.h

# 5. 仅替换 current_sid，不替换 policydb
sed -i 's/static inline u32 current_sid(void)/static inline u32 __ksu_ignored_current_sid(void)/' drivers/kernelsu/selinux/selinux_defs.h

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
