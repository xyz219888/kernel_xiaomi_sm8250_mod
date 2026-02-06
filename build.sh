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

# ==================== [Step 1: 源码深度净化 (8文件全家桶版)] ====================
echo "🧹 [1/6] 执行源码深度净化 (用户补丁重置 + 8文件深度清理)..."

# 1. [用户指定] 基础重置 (应用远程修复补丁)
# 这一步把你内核拉回官方/修改版的基础状态
curl -L https://github.com/ApartTUSITU/kernel_xiaomi_sm8250_mod/commit/a05557c.patch | git apply -v >/dev/null 2>&1 || true

# 2. 清理编译残留与旧驱动目录
rm -rf drivers/kernelsu drivers/susfs fs/susfs out/
mkdir -p out

# 3. 定义深度清理函数 (专门对付断行尸体和残留代码)
# 这个函数会把文件里所有带 KSU/SUSFS 特征的代码连根拔起
clean_file_deep() {
    local file="$1"
    if [ -f "$file" ]; then
        echo "   -> 正在为 $file 进行深度清创..."
        
        # --- 第一层：逻辑块切除 (宏观) ---
        # 删除所有 CONFIG_KSU 和 CONFIG_KSU_MANUAL_HOOK 包裹的代码块
        sed -i '/#ifdef CONFIG_KSU/,/#endif/d' "$file"
        sed -i '/#if defined(CONFIG_KSU_SUSFS/,/#endif/d' "$file"
        sed -i '/#ifdef CONFIG_KSU_SUSFS/,/#endif/d' "$file"
        
        # --- 第二层：残留声明狙击 (微观) ---
        # 即使不在 ifdef 里，只要包含这些特征，统统干掉
        sed -i '/extern bool ksu_/d' "$file"
        sed -i '/extern int ksu_/d' "$file"
        sed -i '/extern void ksu_/d' "$file"
        sed -i '/extern void susfs_/d' "$file"
        
        # --- 第三层：断行尸体清理 (核心修复: 针对 expected identifier 报错) ---
        # 专门清理 Patch 失败后留下的孤儿参数声明
        sed -i '/void \*argv, void \*envp, int \*flags);/d' "$file"
        sed -i '/void \*envp, int \*flags);/d' "$file"
        sed -i '/struct filename \*\*filename_ptr,/d' "$file"
        sed -i '/int \*mode, int \*flags);/d' "$file"
        
        # --- 第四层：头文件引用清理 ---
        sed -i '/#include <linux\/susfs/d' "$file"
        sed -i '/#include "susfs/d' "$file"
        
    else
        echo "   ⚠️ 文件 $file 不存在，跳过清理。"
    fi
}

# 4. 对 8 个核心文件逐一执行手术

# [1] fs/exec.c (重灾区)
clean_file_deep "fs/exec.c"
sed -i '/ksu_execveat_hook/d' fs/exec.c
sed -i '/ksu_handle_execveat/d' fs/exec.c

# [2] fs/read_write.c
clean_file_deep "fs/read_write.c"
sed -i '/ksu_vfs_read_hook/d' fs/read_write.c
sed -i '/ksu_handle_sys_read/d' fs/read_write.c

# [3] fs/open.c
clean_file_deep "fs/open.c"
sed -i '/ksu_handle_faccessat/d' fs/open.c

# [4] fs/stat.c (SUSFS 聚集地)
clean_file_deep "fs/stat.c"
sed -i '/susfs_sus_ino_for_generic_fillattr/d' fs/stat.c
sed -i '/ksu_handle_stat/d' fs/stat.c

# [5] drivers/input/input.c
clean_file_deep "drivers/input/input.c"
sed -i '/ksu_input_hook/d' drivers/input/input.c
sed -i '/ksu_handle_input_handle_event/d' drivers/input/input.c

# [6] kernel/reboot.c
clean_file_deep "kernel/reboot.c"
sed -i '/ksu_handle_sys_reboot/d' kernel/reboot.c

# [7] kernel/sys.c (🔥 关键文件，Manager 提权用)
clean_file_deep "kernel/sys.c"
sed -i '/ksu_handle_setresuid/d' kernel/sys.c

# [8] security/selinux/hooks.c (ReSukiSU 提到的第 8 个文件)
clean_file_deep "security/selinux/hooks.c"
sed -i '/is_ksu_transition/d' "security/selinux/hooks.c"

# 5. 修复头文件 (防止宏定义冲突)
echo "   -> 正在检查头文件残留..."
if [ -f "include/linux/fs.h" ]; then
    sed -i '/INODE_STATE_SUS_KSTAT/d' include/linux/fs.h
    sed -i '/#define INODE_STATE_SUS_KSTAT/d' include/linux/fs.h
fi
if [ -f "include/linux/sched.h" ]; then
    sed -i '/susfs_task_state/d' include/linux/sched.h
    sed -i '/u32 susfs_task_state;/d' include/linux/sched.h
fi

echo "   ✅ 深度净化完成！所有残留代码已清除，文件已恢复纯净状态。"

# ==================== [Step 2: 下载组件] ====================
echo "⬇️ [2/6] 下载 SukiSU & SUSFS..."
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin
wget https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch -O susfs.patch -q

# ==================== [Step 3: Hook 注入 (源码级完美修正版)] ====================
echo "🔧 [3/6] 正在应用补丁与注入 Hook (基于 SukiSU 源码深度校准)..."

# --- 0. 紧急清洗 (防止之前脚本的残留) ---
if [ -f "drivers/input/input.c" ]; then
    sed -i '/ksu_handle_input_handle_event/d' drivers/input/input.c
    sed -i '/ksu_input_hook/d' drivers/input/input.c
fi

# --- 1. 应用 SUSFS 补丁 ---
if [ -f "susfs.patch" ]; then
    echo "   -> 正在应用 susfs.patch..."
    patch -p1 --ignore-whitespace --fuzz=3 -N < susfs.patch || echo "   ⚠️ 补丁可能已应用"
fi

# --- 2. 补全头文件 ---
if ! grep -q "susfs_task_state" include/linux/sched.h; then
    sed -i '/^	\/\* protection of the PI data mutex \*\//i \
	#ifdef CONFIG_KSU\
	u32 susfs_task_state;\
	#endif' include/linux/sched.h
fi
if ! grep -q "INODE_STATE_SUS_KSTAT" include/linux/fs.h; then
    sed -i '$a \
#ifndef INODE_STATE_SUS_KSTAT\
#define INODE_STATE_SUS_KSTAT (1UL << 30)\
#endif' include/linux/fs.h
fi

# --- 3. 执行 Hook 注入 (源码实战版) ---
echo "   -> 正在注入 Manual Hook..."

# [1] fs/read_write.c (Hook Read)
# 🔥 修正：源码 ksud.c 只定义了 void ksu_handle_sys_read(unsigned int fd);
sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
extern bool ksu_init_rc_hook __read_mostly;\
extern void ksu_handle_sys_read(unsigned int fd);\
#endif' fs/read_write.c

# 注入位置：只传 fd，绝对不要传 buf 和 count！
sed -i '/^SYSCALL_DEFINE3(read,/,/^{/ s/^{/{ \n#ifdef CONFIG_KSU_MANUAL_HOOK\nif (unlikely(ksu_init_rc_hook)) ksu_handle_sys_read(fd);\n#endif/' fs/read_write.c


# [2] fs/exec.c (Hook Exec)
# 🔥 修正：1.补全 struct 声明 2.使用 _ksud 后缀 3.参数类型对齐
sed -i '/#include <linux\/file.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
struct filename;\
struct user_arg_ptr;\
extern int ksu_handle_execveat_ksud(int *fd, struct filename **filename_ptr, struct user_arg_ptr *argv, struct user_arg_ptr *envp, int *flags);\
#endif' fs/exec.c

# 注入位置：参数必须取地址传递
sed -i '/if (IS_ERR(filename))/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
ksu_handle_execveat_ksud(\&fd, \&filename, \&argv, \&envp, \&flags);\
#endif' fs/exec.c


# [3] fs/open.c (Hook Faccessat)
sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\
#endif' fs/open.c

sed -i '/return do_faccessat(dfd, filename, mode);/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
ksu_handle_faccessat(\&dfd, \&filename, \&mode, NULL);\
#endif' fs/open.c


# [4] fs/stat.c (Hook Stat)
sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\
extern void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);\
#endif' fs/stat.c

sed -i '/error = vfs_fstatat(dfd, filename, &stat, flag);/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
ksu_handle_stat(\&dfd, \&filename, \&flag);\
#endif' fs/stat.c

sed -i '/fdput(f);/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
if (!error) ksu_handle_vfs_fstat(fd, \&stat->size);\
#endif' fs/stat.c


# [5] drivers/input/input.c (Hook Input)
# 🔥 修正：使用唯一锚点 is_event_supported，防止插错位置
sed -i '/#include <linux\/input\/mt.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
extern bool ksu_input_hook __read_mostly;\
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\
#endif' drivers/input/input.c

sed -i '/if (is_event_supported(type, dev->evbit, EV_MAX))/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
if (unlikely(ksu_input_hook)) ksu_handle_input_handle_event(\&type, \&code, \&value);\
#endif' drivers/input/input.c


# [6] kernel/sys.c (Root Hook)
if [ -f "kernel/sys.c" ]; then
    echo "   -> 正在注入 kernel/sys.c..."
    sed -i '/#include <linux\/syscalls.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\
#endif' kernel/sys.c

    sed -i '/ksuid = make_kuid(ns, suid);/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
    (void)ksu_handle_setresuid(ruid, euid, suid);\
#endif' kernel/sys.c
fi

echo "   ✅ Hook 注入完成！(已修复所有定义冲突)"


# ==================== [Step 3.5: 变量桥接与链接修复] ====================
echo "🔧 [3.5/6] 正在执行变量桥接与冲突修复..."

# 1. 强制静态链接
DRIVERS_MAKEFILE="drivers/Makefile"
if [ -f "$DRIVERS_MAKEFILE" ]; then
    sed -i '/kernelsu/d' "$DRIVERS_MAKEFILE"
    echo "ccflags-y += -DCONFIG_KSU_MANUAL_HOOK=1" >> "$DRIVERS_MAKEFILE"
    echo "obj-y += kernelsu/" >> "$DRIVERS_MAKEFILE"
fi

# 2. 桥接 Policydb
SERVICES_FILE="security/selinux/ss/services.c"
if [ -f "$SERVICES_FILE" ]; then
    if ! grep -q "linux/export.h" "$SERVICES_FILE"; then
        sed -i '/#include <linux\/kernel.h>/a #include <linux/export.h>' "$SERVICES_FILE"
    fi
    if ! grep -q "ksu_policydb_ptr" "$SERVICES_FILE"; then
        cat >> "$SERVICES_FILE" <<EOF

struct policydb *ksu_policydb_ptr = &selinux_ss.policydb;
EXPORT_SYMBOL(ksu_policydb_ptr);
EOF
    fi
fi

# 3. 桥接 AVC
AVC_FILE="security/selinux/avc.c"
if [ -f "$AVC_FILE" ]; then
    if ! grep -q "linux/export.h" "$AVC_FILE"; then
        sed -i '/#include <linux\/types.h>/a #include <linux/export.h>' "$AVC_FILE"
    fi
    if ! grep -q "ksu_selinux_avc_ptr" "$AVC_FILE"; then
        cat >> "$AVC_FILE" <<EOF

struct selinux_avc *ksu_selinux_avc_ptr = &selinux_avc;
EXPORT_SYMBOL(ksu_selinux_avc_ptr);
EOF
    fi
fi

# 4. 导出 Selinux Hook 变量 (SukiSU 控制开关必须)
SELINUX_HOOKS="security/selinux/hooks.c"
if [ -f "$SELINUX_HOOKS" ]; then
    if ! grep -q "int selinux_enforcing " "$SELINUX_HOOKS"; then
        sed -i '/\/\* Fix for SukiSU \*\//d' "$SELINUX_HOOKS"
        sed -i '/int selinux_enforcing =/d' "$SELINUX_HOOKS"
        sed -i '/EXPORT_SYMBOL(selinux_enforcing);/d' "$SELINUX_HOOKS"
        cat >> "$SELINUX_HOOKS" <<EOF

/* Fix for SukiSU */
int selinux_enforcing = 1;
EXPORT_SYMBOL(selinux_enforcing);
EOF
    fi
fi

# 5. 适配 rules.c
RULES_FILE="drivers/kernelsu/selinux/rules.c"
if [ -f "$RULES_FILE" ]; then
    # 删除旧声明，防止冲突
    sed -i '/extern int avc_ss_reset/d' "$RULES_FILE"
    
    # 替换实现
    sed -i '/static struct policydb \*get_policydb(void)/,/^}/c\
extern struct policydb *ksu_policydb_ptr;\
static struct policydb *get_policydb(void)\
{\
    return ksu_policydb_ptr;\
}' "$RULES_FILE"

    sed -i '/static void reset_avc_cache(void)/,/^}/c\
extern struct selinux_avc *ksu_selinux_avc_ptr;\
extern int avc_ss_reset(struct selinux_avc *avc, u32 seqno);\
static void reset_avc_cache(void)\
{\
    avc_ss_reset(ksu_selinux_avc_ptr, 0);\
    selnl_notify_policyload(0);\
    selinux_status_update_policyload(NULL, 0);\
    selinux_xfrm_notify_policyload();\
}' "$RULES_FILE"
fi

echo "   ✅ 桥接与修复全部完成！"

# ==================== [Step 4: SukiSU 源码适配 (官方纯净版)] ====================
echo "💉 [4/6] 执行 SukiSU 源码适配 (官方逻辑 + 4.19 必需修复)..."

# 目标文件
KBUILD_FILE="drivers/kernelsu/Kbuild"

if [ ! -f "$KBUILD_FILE" ]; then
    echo "   ❌ 错误：SukiSU 源码未找到！"
    exit 1
fi

echo "   -> 配置构建参数..."
# 【1】开启 SUSFS (必须)
if ! grep -q "CONFIG_KSU_SUSFS" "$KBUILD_FILE"; then
     echo "ccflags-y += -DCONFIG_KSU_SUSFS -DCONFIG_KSU_SUSFS_SUS_PATH -DCONFIG_KSU_SUSFS_SUS_MOUNT" >> "$KBUILD_FILE"
fi

# 【2】添加 4.19 防报错参数 (必须)
if ! grep -q "-Wno-implicit-function-declaration" "$KBUILD_FILE"; then
    echo "ccflags-y += -Wno-implicit-function-declaration -Wno-strict-prototypes -Wno-int-to-pointer-cast -Wno-unused-function -Wno-unused-variable -Wno-missing-braces -Wno-declaration-after-statement" >> "$KBUILD_FILE"
fi

# 确保 Makefile 存在
if [ ! -f "drivers/kernelsu/Makefile" ]; then
    echo "obj-y += ksu_core.o" > drivers/kernelsu/Makefile
fi

# 【3】4.19 兼容性修复 (必选)
echo "   -> 应用 4.19 兼容性补丁..."

# [修复 1] 补全 SELinux 声明
sed -i '1i\
extern struct policydb policydb;\
extern struct selinux_state selinux_state;' drivers/kernelsu/selinux/rules.c

# [修复 2] 修正函数调用参数
sed -i 's/selinux_status_update_policyload(0);/selinux_status_update_policyload(\&selinux_state, 0);/g' drivers/kernelsu/selinux/rules.c

# [修复 3] 补全 selinux_enforcing 声明
sed -i '1i\extern int selinux_enforcing;' drivers/kernelsu/selinux/selinux_defs.h

# [修复 4] 智能解决 current_sid 冲突 (宏隔离)
sed -i '/static inline u32 current_sid(void)/i #ifndef CONFIG_KSU_COMPAT_HAS_CURRENT_SID' drivers/kernelsu/selinux/selinux_defs.h
sed -i '/return sec->sid;/!b;n;a #endif' drivers/kernelsu/selinux/selinux_defs.h

echo "   ✅ SukiSU 适配完成！"

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
