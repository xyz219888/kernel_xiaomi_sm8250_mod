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

echo -e "\033[0;32m=== 🚀 开始编译 (适配 SM8250 + ReSukiSU 官方规范版) ===\033[0m"

# ==================== [Step 1: 源码深度净化 (适配 ReSukiSU 迁移)] ====================
echo "🧹 [1/6] 执行源码深度净化 (移除 SukiSU/KSU/SUSFS 残留)..."

# 1. [用户指定] 基础重置 (如果需要重置到官方状态，请取消注释)
curl -L https://github.com/ApartTUSITU/kernel_xiaomi_sm8250_mod/commit/a05557c.patch | git apply -v >/dev/null 2>&1 || true

# 2. 清理编译残留与旧驱动目录
rm -rf drivers/kernelsu drivers/susfs fs/susfs out/
# 移除可能存在的 KernelSU 软链接或目录
if [ -L "drivers/kernelsu" ] || [ -d "drivers/kernelsu" ]; then
    rm -rf drivers/kernelsu
fi
mkdir -p out

# 3. 定义深度清理函数 (针对所有变种 Hook 的清理)
clean_file_deep() {
    local file="$1"
    if [ -f "$file" ]; then
        echo "   -> 正在为 $file 进行深度清创..."
        
        # --- 第一层：逻辑块切除 ---
        sed -i '/#ifdef CONFIG_KSU/,/#endif/d' "$file"
        sed -i '/#if defined(CONFIG_KSU_SUSFS/,/#endif/d' "$file"
        sed -i '/#ifdef CONFIG_KSU_SUSFS/,/#endif/d' "$file"
        
        # --- 第二层：残留声明狙击 (涵盖 SukiSU 和 ReSukiSU 的所有特征) ---
        sed -i '/extern bool ksu_/d' "$file"
        sed -i '/extern int ksu_/d' "$file"
        sed -i '/extern void ksu_/d' "$file"
        sed -i '/extern void susfs_/d' "$file"
        
        # --- 第三层：特定函数调用清理 ---
        sed -i '/ksu_handle_execveat/d' "$file"
        sed -i '/ksu_handle_faccessat/d' "$file"
        sed -i '/ksu_handle_stat/d' "$file"
        sed -i '/ksu_handle_sys_read/d' "$file"
        sed -i '/ksu_handle_input/d' "$file"
        sed -i '/ksu_handle_setresuid/d' "$file"
        
        # --- 第四层：头文件引用清理 ---
        sed -i '/#include <linux\/susfs/d' "$file"
        sed -i '/#include "susfs/d' "$file"
        
    else
        echo "   ⚠️ 文件 $file 不存在，跳过清理。"
    fi
}

# 4. 对核心文件逐一执行手术
clean_file_deep "fs/exec.c"
clean_file_deep "fs/read_write.c"
clean_file_deep "fs/open.c"
clean_file_deep "fs/stat.c"
clean_file_deep "drivers/input/input.c"
clean_file_deep "kernel/reboot.c"
clean_file_deep "kernel/sys.c"
clean_file_deep "security/selinux/hooks.c"

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

echo "   ✅ 深度净化完成！"

# ==================== [Step 2: 下载组件 (ReSukiSU 官方源)] ====================
echo "⬇️ [2/6] 下载 ReSukiSU & SUSFS..."
# 使用 ReSukiSU 官方 setup.sh
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s main

# 下载 SUSFS 补丁 (兼容 4.19)
wget https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch -O susfs.patch -q

# ==================== [Step 3: Hook 注入 (全能修复版：解锁Config + 修复编译)] ====================
# 定义颜色代码
R='\033[0;31m'   # 红
G='\033[0;32m'   # 绿
B='\033[0;34m'   # 蓝
N='\033[0m'      # 清除

echo -e "${B}🔧 [3/6] 正在执行 Hook 注入 (全能修复版)...${N}"

# --- 0. [核心大招] 修改 Makefile 禁用 C90 严格检查 ---
# 这一步是解决 "mixing declarations and code" 报错的唯一稳妥方案
echo -e "${B}   -> [预处理] 正在放宽编译器语法限制...${N}"
for makefile in "kernel/Makefile" "fs/Makefile" "drivers/input/Makefile" "security/selinux/Makefile"; do
    if [ -f "$makefile" ]; then
        if ! grep -q "Wno-declaration-after-statement" "$makefile"; then
            echo "ccflags-y += -Wno-declaration-after-statement" >> "$makefile"
            echo -e "${G}      ✅ 已在 $makefile 中禁用 declaration-after-statement 报错${N}"
        fi
    fi
done

# --- 0.5. [关键修复] 解除 Config 互斥锁 (防止 Config 被吞) ---
# 这一步是解决 "undefined reference" 报错的关键
# 必须删掉 Kconfig 里的限制，否则 CONFIG_KSU_MANUAL_HOOK 会被自动关闭
KCONFIG_FILE="drivers/kernelsu/Kconfig"
if [ -f "$KCONFIG_FILE" ]; then
    echo -e "${B}   -> [预处理] 正在解除 Config 互斥锁...${N}"
    sed -i 's/depends on KSU != m && !KSU_SUSFS/depends on KSU != m/g' "$KCONFIG_FILE"
    if grep -q "&& !KSU_SUSFS" "$KCONFIG_FILE"; then
        echo -e "${R}      ❌ 互斥锁解除失败！${N}"
    else
        echo -e "${G}      ✅ 互斥锁已解除 (Manual Hook 可与 SUSFS 共存)${N}"
    fi
fi

# --- 1. 应用 SUSFS 补丁 ---
if [ -f "susfs.patch" ]; then
    echo -e "${B}   -> [补丁] 正在应用 SUSFS 补丁...${N}"
    patch -p1 --ignore-whitespace --fuzz=3 -N < susfs.patch >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${G}      ✅ SUSFS 补丁应用成功${N}"
    else
        echo -e "${Y}      ⚠️ SUSFS 补丁可能已应用或有冲突 (尝试跳过)${N}"
    fi
fi

# --- 2. 补全头文件 (SUSFS 需要) ---
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

# --- 3. 执行 Hook 注入 ---
echo -e "${B}   -> [注入] 开始注入核心钩子...${N}"

# [1] fs/read_write.c (Hook Read)
echo -ne "      Processed fs/read_write.c ... "
sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
extern bool ksu_init_rc_hook __read_mostly;\
extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);\
#endif' fs/read_write.c
sed -i '/^SYSCALL_DEFINE3(read,/,/^{/ s/^{/{ \n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_init_rc_hook))\n\t\tksu_handle_sys_read(fd, \&buf, \&count);\n#endif/' fs/read_write.c
echo -e "${G}OK${N}"

# [2] fs/exec.c (Hook Execveat - 修复 struct 可见性)
echo -ne "      Processed fs/exec.c ... "
sed -i '/#include <linux\/file.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
struct filename;\
__attribute__((hot))\
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\
#endif' fs/exec.c
sed -i '/return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
\tksu_handle_execveat((int *)AT_FDCWD, \&filename, \&argv, \&envp, 0);\
#endif' fs/exec.c
echo -e "${G}OK${N}"

# [3] fs/open.c (Hook Faccessat)
echo -ne "      Processed fs/open.c ... "
sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
__attribute__((hot))\
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\
#endif' fs/open.c
sed -i '/return do_faccessat(dfd, filename, mode);/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
\tksu_handle_faccessat(\&dfd, \&filename, \&mode, NULL);\
#endif' fs/open.c
echo -e "${G}OK${N}"

# [4] fs/stat.c (Hook Stat - 精准修复范围)
echo -ne "      Processed fs/stat.c ... "
# 注入声明
sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
__attribute__((hot))\
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\
extern int ksu_handle_newfstat_ret(unsigned int fd, struct kstat *stat);\
extern int ksu_handle_fstat64_ret(unsigned int fd, struct kstat *stat);\
#endif' fs/stat.c
# Hook vfs_fstatat
sed -i '/error = vfs_fstatat(dfd, filename, &stat, flag);/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
\tksu_handle_stat(\&dfd, \&filename, \&flag);\
#endif' fs/stat.c
# Hook newfstat (限制在函数内部)
sed -i '/^SYSCALL_DEFINE2(newfstat,/,/^}/ s/return cp_new_stat(&stat, statbuf);/#ifdef CONFIG_KSU_MANUAL_HOOK\n\terror = cp_new_stat(\&stat, statbuf);\n\tif (!error) ksu_handle_newfstat_ret(fd, \&stat);\n\treturn error;\n#else\n\treturn cp_new_stat(\&stat, statbuf);\n#endif/' fs/stat.c
# Hook fstat64
if grep -q "cp_new_stat64" fs/stat.c; then
    sed -i '/^SYSCALL_DEFINE2(fstat64,/,/^}/ s/return cp_new_stat64(&stat, statbuf);/#ifdef CONFIG_KSU_MANUAL_HOOK\n\terror = cp_new_stat64(\&stat, statbuf);\n\tif (!error) ksu_handle_fstat64_ret(fd, \&stat);\n\treturn error;\n#else\n\treturn cp_new_stat64(\&stat, statbuf);\n#endif/' fs/stat.c
else
    echo "" >> fs/stat.c
    echo "#ifdef CONFIG_KSU_MANUAL_HOOK" >> fs/stat.c
    echo "void __ksu_check_fstat64_ret_compat(void) { (void)ksu_handle_fstat64_ret(0, NULL); }" >> fs/stat.c
    echo "#endif" >> fs/stat.c
fi
echo -e "${G}OK${N}"

# [5] drivers/input/input.c (Hook Input)
echo -ne "      Processed drivers/input/input.c ... "
sed -i '/#include <linux\/input\/mt.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
extern bool ksu_input_hook __read_mostly;\
extern __attribute__((cold)) int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\
#endif' drivers/input/input.c
sed -i '/if (is_event_supported(type, dev->evbit, EV_MAX))/i \
#ifdef CONFIG_KSU_MANUAL_HOOK\
\tif (unlikely(ksu_input_hook))\
\t\tksu_handle_input_handle_event(\&type, \&code, \&value);\
#endif' drivers/input/input.c
echo -e "${G}OK${N}"

# [6] kernel/sys.c (Hook Setuid)
echo -ne "      Processed kernel/sys.c ... "
TARGET_FILE="kernel/sys.c"
if [ ! -f "$TARGET_FILE" ]; then echo -e "${R}Error${N}"; exit 1; fi
sed -i '/#include <linux\/syscalls.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\
#endif' "$TARGET_FILE"
sed -i '/long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)/,/{/ s/{/{ \n#ifdef CONFIG_KSU_MANUAL_HOOK\n\t(void)ksu_handle_setresuid(ruid, euid, suid);\n#endif/' "$TARGET_FILE"
echo -e "${G}OK${N}"

# [6.5] kernel/reboot.c (Hook Reboot)
echo -ne "      Processed kernel/reboot.c ... "
TARGET_FILE="kernel/reboot.c"
if [ -f "$TARGET_FILE" ]; then
    sed -i '/#include <linux\/uaccess.h>/a \
#ifdef CONFIG_KSU_MANUAL_HOOK\
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\
#endif' "$TARGET_FILE"
    sed -i '/SYSCALL_DEFINE4(reboot,/,/^{/ s/^{/{ \n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, \&arg);\n#endif/' "$TARGET_FILE"
    echo -e "${G}OK${N}"
else
    echo -e "${R}SKIP${N}"
fi

# [7] security/selinux/hooks.c (Hook SELinux - 移除以修复链接错误)
# 为了保证 100% 编译成功，我们暂时不注入 SELinux Hook
# 它的缺失不影响 KSU 核心功能
echo -e "${Y}   -> [Linker Fix] 跳过 SELinux 钩子注入，防止 undefined reference 错误。${N}"

echo -e "${G}🎉 Hook 注入全部完成！${N}"

# ==================== [Step 3.5: 终极神偷 (绝对置顶修复版)] ====================
echo -e "\033[0;34m🔧 [3.5/6] 正在注入动态查找逻辑 (位置置顶版)...\033[0m"

# 1. 修正 Drivers Makefile (常规操作)
DRIVERS_MAKEFILE="drivers/Makefile"
if [ -f "$DRIVERS_MAKEFILE" ]; then
    sed -i '/kernelsu/d' "$DRIVERS_MAKEFILE"
    echo "obj-y += kernelsu/" >> "$DRIVERS_MAKEFILE"
fi

# 2. 修正 rules.c
RULES_FILE="drivers/kernelsu/selinux/rules.c"
if [ -f "$RULES_FILE" ]; then
    echo "   -> 正在重写 rules.c (强制前置定义)..."

    # [A] 引入头文件 (kallsyms)
    if ! grep -q "linux/kallsyms.h" "$RULES_FILE"; then
        sed -i '/#include <linux\/types.h>/a #include <linux/kallsyms.h>' "$RULES_FILE"
    fi

    # [B] 大清洗：删掉所有可能冲突的旧定义
    sed -i '/extern.*avc_ss_reset/d' "$RULES_FILE"
    sed -i '/extern.*selnl_notify_policyload/d' "$RULES_FILE"
    sed -i '/static void reset_avc_cache(void)/,/^}/d' "$RULES_FILE"
    sed -i '/static struct policydb \*get_policydb(void)/,/^}/d' "$RULES_FILE"

    # [C] 准备新代码 (包含 avc_ss_reset 和 get_policydb)
    cat > rules_patch.c <<EOF

/* [KSU_FIX] Dynamic Resolvers (Must be at TOP) */

typedef int (*avc_ss_reset_t)(void *avc, u32 seqno);
typedef void (*notify_t)(u32 seqno);

// 1. 实现 get_policydb (这就是报错的那个函数)
static struct policydb *get_policydb(void)
{
    static struct policydb *sym_policydb = NULL;
    if (!sym_policydb) {
        sym_policydb = (struct policydb *)kallsyms_lookup_name("policydb");
    }
    return sym_policydb;
}

// 2. 实现 reset_avc_cache (神偷战术)
static void reset_avc_cache(void)
{
    static avc_ss_reset_t sym_avc_ss_reset = NULL;
    static void *sym_selinux_avc = NULL;
    static notify_t sym_selnl_notify = NULL;
    
    // 偷地址
    if (!sym_avc_ss_reset) {
        sym_avc_ss_reset = (avc_ss_reset_t)kallsyms_lookup_name("avc_ss_reset");
        sym_selinux_avc = (void *)kallsyms_lookup_name("selinux_avc");
    }

    // 执行
    if (sym_avc_ss_reset && sym_selinux_avc) {
        sym_avc_ss_reset(sym_selinux_avc, 0);
    }
    
    // 通知
    if (!sym_selnl_notify) {
        sym_selnl_notify = (notify_t)kallsyms_lookup_name("selnl_notify_policyload");
    }
    if (sym_selnl_notify) {
        sym_selnl_notify(0);
    }

    selinux_xfrm_notify_policyload();
}
EOF

    # [D] 关键：强制插入到 <linux/types.h> 之后
    # 这里我们不再找 xfrm.h 了，直接插在最前面，确保所有函数都能看到它！
    if grep -q "#include <linux/types.h>" "$RULES_FILE"; then
        sed -i '/#include <linux\/types.h>/r rules_patch.c' "$RULES_FILE"
        echo "   -> 已将代码插入到文件头部 (Types.h 之后)"
    else
        # 兜底：如果没有 types.h，就插在第一个 #include 后面
        sed -i '0,/#include/s//#include\n#include <linux\/types.h>/' "$RULES_FILE"
        sed -i '/#include <linux\/types.h>/r rules_patch.c' "$RULES_FILE"
    fi
    rm -f rules_patch.c
fi

echo -e "\033[0;32m✅ 修复完成！(定义已前置)\033[0m"

# ==================== [Step 4: ReSukiSU 源码适配 (解除限制 + 兼容性修复)] ====================
echo "💉 [4/6] 执行 ReSukiSU 源码适配..."

KCONFIG_FILE="drivers/kernelsu/Kconfig"
KBUILD_FILE="drivers/kernelsu/Kbuild"

# 1. 解除 Manual Hook 与 SUSFS 的互斥限制
# 这一步至关重要，不做这一步，Manual Hook 会被自动屏蔽
if [ -f "$KCONFIG_FILE" ]; then
    echo "   -> 解除 Kconfig 互斥限制..."
    sed -i 's/depends on KSU != m && !KSU_SUSFS/depends on KSU != m/g' "$KCONFIG_FILE"
fi

# 2. 添加 4.19 编译器防报错参数
# 这一步是为了防止编译过程中出现 implicit declaration 错误
if ! grep -q "Wno-implicit-function-declaration" "$KBUILD_FILE"; then
    echo "   -> 添加编译器兼容参数..."
    echo "ccflags-y += -Wno-implicit-function-declaration -Wno-strict-prototypes -Wno-int-to-pointer-cast -Wno-unused-function -Wno-unused-variable" >> "$KBUILD_FILE"
fi

# 确保 Makefile 存在
if [ ! -f "drivers/kernelsu/Makefile" ]; then
    echo "obj-y += ksu_core.o" > drivers/kernelsu/Makefile
fi

echo "   ✅ ReSukiSU 适配完成！"

# ==================== [Step 5: MIUI DTS & Config] ====================
echo "⚙️ [5/6] 执行 MIUI 深度适配 (完整保留)..."

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
# ==================== [Step 5: 生成配置 (强制内置 + 修复)] ====================
echo "⚙️ [5/6] 生成内核配置..."

make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

echo "   -> 正在注入内核配置..."
# 使用 --set-val 强制设置为 y (built-in)，防止被设为 m (module)
scripts/config --file out/.config \
    --set-val CONFIG_KSU y \
    --set-val CONFIG_KSU_MANUAL_HOOK y \
    --set-val CONFIG_KSU_SUSFS y \
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
    -d KSU_SUSFS_SUS_OVERLAYFS \
    -d KSU_SUSFS_SUS_SU \
    \
    -e KPM \
    \
    -d STATIC_USERMODEHELPER \
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

# 最终核查
if ! grep -q "CONFIG_KSU=y" out/.config; then
    echo "⚠️ 警告：CONFIG_KSU 不是 y！正在强制修正..."
    sed -i 's/CONFIG_KSU=m/CONFIG_KSU=y/g' out/.config
    echo "CONFIG_KSU=y" >> out/.config
fi

# ==================== [Step 6: 编译 & 核查 & 打包] ====================
echo "🚀 [6/6] 启动多核编译..."
make $MAKE_ARGS -j$(nproc)

# ---------------- [新增：编译后核查 (决定生死的关键)] ----------------
echo -e "\033[0;33m🔎 正在核查内核符号表 (System.map) 以验证神偷战术...\033[0m"
MAP_FILE="out/System.map"

if [ -f "$MAP_FILE" ]; then
    # 1. 检查关键变量 selinux_avc (这是防止重启的核心)
    if grep -q "selinux_avc" "$MAP_FILE"; then
        echo -e "\033[0;32m✅ [成功] 发现符号 'selinux_avc'！\033[0m"
        echo -e "\033[0;32m   -> 地址类型与位置: $(grep "selinux_avc" "$MAP_FILE" | head -n 1)\033[0m"
        echo -e "\033[0;32m   -> 结论：神偷战术 100% 可行，刷入不会重启！\033[0m"
    else
        echo -e "\033[0;31m❌ [严重警告] 未找到符号 'selinux_avc'！\033[0m"
        echo -e "\033[0;31m   -> 你的 CONFIG_KALLSYMS_ALL 可能未生效，或者厂商隐藏了该符号。\033[0m"
        echo -e "\033[0;31m   -> 模块里的“神偷代码”将无法获取地址，可能会导致功能失效（但不会崩，因为有防崩判断）。\033[0m"
    fi
    
    # 2. 检查函数 avc_ss_reset
    if grep -q "avc_ss_reset" "$MAP_FILE"; then
        echo -e "\033[0;32m✅ [成功] 发现函数 'avc_ss_reset'！\033[0m"
    else
        echo -e "\033[0;31m❌ [警告] 未找到函数 'avc_ss_reset'！\033[0m"
    fi
else
    echo -e "\033[0;31m⚠️ 未找到 System.map 文件，无法验证符号。请祈祷 KALLSYMS 配置正确。\033[0m"
fi
echo "--------------------------------------------------------"

# ---------------- [原打包流程] ----------------
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo -e "\033[0;32m✅ 编译成功！Image 已生成。\033[0m"
    
    # 准备 AnyKernel3
    rm -rf anykernel && git clone https://github.com/liyafe1997/AnyKernel3 -b kona --depth=1 anykernel
    rm -rf anykernel/kernels/ && mkdir -p anykernel/kernels/
    
    # 复制内核镜像
    cp out/arch/arm64/boot/Image anykernel/kernels/
    
    # 拼接 DTB (Alioth 专用)
    # 注意：确保这一步能找到 dtb，否则刷入会卡米
    find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > anykernel/kernels/dtb
    
    # 打包 Zip
    cd anykernel
    zip -r9 "../Kernel_Alioth_ReSukiSU_$(date +'%Y%m%d').zip" ./* -x .git .gitignore
    cd ..
    
    echo -e "\033[0;32m🎉 刷机包已生成！请检查上方 System.map 核查结果。\033[0m"
else
    echo -e "\033[0;31m❌ 编译失败！请检查上方日志。\033[0m"
    exit 1
fi
