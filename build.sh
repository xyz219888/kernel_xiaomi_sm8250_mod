#!/usr/bin/env bash
set -euo pipefail

# ==================== 配置区域 ====================
TOOLCHAIN_PATH="${HOME}/zyc-clang/bin"   # 改成你的 clang 工具链路径
TARGET_DEVICE="alioth"

# 补丁文件（放在仓库根目录）
PATCH_FILE="manual_hook_perfect.patch"   # 如果你把它命名为 .diff 或其它，请修改这里

# SUSFS 补丁下载地址（脚本会覆盖同名文件）
SUSFS_URL="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch"
SUSFS_FILE="susfs.patch"

# make 参数（可按需调整）
MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out \
    CC=clang \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
    CLANG_TRIPLE=aarch64-linux-gnu-"

# ==================== 准备函数 ====================
log() { printf '\033[0;32m%s\033[0m\n' "$*"; }
err() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
die() { err "$*"; exit 1; }

cleanup_and_exit() {
    # 可在此添加清理动作
    exit "$1"
}

trap 'cleanup_and_exit $?' EXIT

# ==================== 校验与环境导出 ====================
log "=== 启动构建脚本 ==="
log "工作目录: $(pwd)"

# 检查补丁文件存在
if [ ! -f "$PATCH_FILE" ]; then
    die "补丁文件未找到: $PATCH_FILE (请把补丁放到仓库根目录并确保文件名正确)"
fi

# 检查工具链路径
if [ ! -d "$TOOLCHAIN_PATH" ]; then
    err "警告：TOOLCHAIN_PATH ($TOOLCHAIN_PATH) 不存在。若你在 CI 上运行，请确认已配置工具链。"
else
    export PATH="$TOOLCHAIN_PATH:$PATH"
fi

export CCACHE_DIR="${HOME}/.cache/ccache_mikernel"
export CC="ccache clang"
export CXX="ccache clang++"
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# ==================== 工作树检查 ====================
if [ -n "$(git status --porcelain)" ]; then
    err "检测到未提交/未暂存的改动。建议先 git add/commit 或 git stash。"
    git status --porcelain
    die "请清理工作树后再运行脚本。"
fi

# ==================== 步骤 1: 清理旧残留 ====================
log "🧹 [1/6] 深度清理 / 恢复干净状态..."
# 尝试回滚/应用已知恢复 patch（若失败忽略）
curl -fsSL "https://github.com/ApartTUSITU/kernel_xiaomi_sm8250_mod/commit/a05557c.patch" \
    | git apply -v >/dev/null 2>&1 || true
rm -rf drivers/kernelsu drivers/susfs fs/susfs out/
mkdir -p out

# ==================== 步骤 2: 下载组件 ====================
log "���️ [2/6] 下载 SukiSU & SUSFS..."
# SukiSU 内置安装脚本（使用 builtin 模式）
if ! curl -fsSL "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin; then
    err "警告：下载/执行 SukiSU setup.sh 失败，请检查网络或手动下载。"
fi

# 下载 SUSFS 补丁
if ! curl -fsSL "$SUSFS_URL" -o "$SUSFS_FILE"; then
    err "下载 SUSFS 补丁失败，请检查 URL 或网络: $SUSFS_URL"
fi

# ==================== 步骤 3: 应用补丁 (优先 git am -> fallback git apply) ====================
log "🔧 [3/6] 应用补丁: $PATCH_FILE"

# 清理补丁文件的隐形字符和 CRLF（就地修改）
# 1) 删除 BOM
perl -0777 -pe 's/^\xEF\xBB\xBF//' -i "$PATCH_FILE" || true
# 2) 将 NBSP (\xC2\xA0) 替换为空格
perl -0777 -pe 's/\xC2\xA0/ /g' -i "$PATCH_FILE" || true
# 3) 删除回车符 CR
sed -i 's/\r$//' "$PATCH_FILE"

# 判断是否为 mbox / git format-patch（包含 "From " 或 "Subject:" 行）
if grep -qE '^From [0-9a-f]{8,}' "$PATCH_FILE" || grep -q '^Subject:' "$PATCH_FILE"; then
    log "检测到 git-format-patch/mbox 风格，尝试使用 git am"
    if git am -3 "$PATCH_FILE"; then
        log "git am 应用成功。"
    else
        err "git am 失败，尝试提取纯 diff 并用 git apply 作为回退。"
        git am --abort >/dev/null 2>&1 || true
        # fallthrough to apply-diff below
        APPLY_AS_DIFF=1
    fi
else
    APPLY_AS_DIFF=1
fi

if [ "${APPLY_AS_DIFF:-0}" -eq 1 ]; then
    log "将补丁转换为纯 diff（从第一个 diff --git 行开始）..."
    sed -n '/^diff --git/,$p' "$PATCH_FILE" > manual_hook_perfect.diff
    # 再次清理
    sed -i 's/\r$//' manual_hook_perfect.diff
    perl -0777 -pe 's/\xC2\xA0/ /g' -i manual_hook_perfect.diff || true

    log "执行 git apply --check 进行干跑检查..."
    if ! git apply --check manual_hook_perfect.diff; then
        err "git apply --check 失败：补丁可能与当前源码不匹配或会产生冲突。"
        err "已把清理后的 diff 保存为 manual_hook_perfect.diff，检查并手动修复或贴出日志让我帮你定位。"
        ls -l manual_hook_perfect.diff || true
        die "无法自动应用补丁，终止。"
    fi

    log "git apply 检查通过，开始应用..."
    git apply manual_hook_perfect.diff

    # 在 CI/Actions 环境中���要配置 user
    if ! git config user.name >/dev/null 2>&1; then
        git config user.name "github-actions[bot]" || true
    fi
    if ! git config user.email >/dev/null 2>&1; then
        git config user.email "41898282+github-actions[bot]@users.noreply.github.com" || true
    fi

    git add -A
    git commit -m "Apply SukiSU Built-in Manual Hooks (via git apply)"
    log "补丁已用 git apply 成功应用并提交。"
fi

# ==================== 步骤 4: 应用 SUSFS 补丁 ====================
log "🔧 应用 SUSFS 补丁: $SUSFS_FILE"
# 清理并尝试应用
sed -i 's/\r$//' "$SUSFS_FILE"
if ! patch -p1 --dry-run < "$SUSFS_FILE" >/dev/null 2>&1; then
    err "SUSFS 补丁 dry-run 失败，尝试使用 git apply 检查..."
    if git apply --check "$SUSFS_FILE"; then
        git apply "$SUSFS_FILE"
    else
        err "无法自动应用 SUSFS 补丁，请人工检查 $SUSFS_FILE"
    fi
else
    patch -p1 < "$SUSFS_FILE"
fi

# ==================== 步骤 5: SukiSU 源码适配 ============
log "💉 [4/6] 执行 SukiSU 源码适配 (Makefile / SELinux 修复等)..."
# 覆盖/生成 drivers/kernelsu/Makefile（与原脚本保持一致）
mkdir -p drivers/kernelsu
cat > drivers/kernelsu/Makefile <<'EOF'
# 注入版本号
ccflags-y += -DKSU_VERSION=11999 -DKSU_VERSION_FULL=\"v1.0.0-SUKISU-Custom\"
# 屏蔽 C99 警告
ccflags-y += -Wno-implicit-function-declaration -Wno-strict-prototypes -Wno-int-to-pointer-cast -Wno-unused-function -Wno-unused-variable -Wno-missing-braces -Wno-declaration-after-statement
# 开启 SUSFS
ccflags-y += -I$(src)/include -DCONFIG_KSU_SUSFS -DCONFIG_KSU_SUSFS_SUS_PATH -DCONFIG_KSU_SUSFS_SUS_MOUNT
# 补全头文件路径
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

# SELinux 相关修复（按原脚本）
if [ -f drivers/kernelsu/selinux/rules.c ]; then
    sed -i '1iextern struct selinux_state selinux_state;' drivers/kernelsu/selinux/rules.c || true
    sed -i 's/&policydb/&selinux_state.ss->policydb/g' drivers/kernelsu/selinux/rules.c || true
    sed -i 's/selinux_status_update_policyload(0)/selinux_status_update_policyload(&selinux_state, 0)/g' drivers/kernelsu/selinux/rules.c || true
fi
if [ -f drivers/kernelsu/selinux/selinux_defs.h ]; then
    sed -i '1iextern int selinux_enforcing;' drivers/kernelsu/selinux/selinux_defs.h || true
    sed -i 's/static inline u32 current_sid(void)/static inline u32 __ksu_ignored_current_sid(void)/' drivers/kernelsu/selinux/selinux_defs.h || true
fi

# ==================== 步骤 6: DTS/Config 适配与生成 ================
log "⚙️ [5/6] MIUI DTS 修复 & 生成基础 Config..."
dts_source="arch/arm64/boot/dts/vendor/qcom"
# 仅在目录存在时执行 dts 替换
if [ -d "$dts_source" ]; then
    # 只做关键替换（参照原脚本）
    sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j1s* 2>/dev/null || true
    sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j2* 2>/dev/null || true
    # ... 其余替换可按需补回（为保持脚本简洁，这里只保留最关键的）
fi

log "生成基础 defconfig 并注入配置..."
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

# 注入内核配置（使用 scripts/config 设置 out/.config）
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

# 确保配置生效
make $MAKE_ARGS olddefconfig

# ==================== 步骤 7: 编译 & 打包 ====================
log "🚀 [6/6] 开始编译..."
make $MAKE_ARGS -j"$(nproc)"

if [ -f "out/arch/arm64/boot/Image" ]; then
    log "✅ 编译成功：out/arch/arm64/boot/Image 已生成。"
    # 打包 AnyKernel（按原脚本）
    rm -rf anykernel && git clone https://github.com/liyafe1997/AnyKernel3 -b kona --depth=1 anykernel
    rm -rf anykernel/kernels/ && mkdir -p anykernel/kernels/
    cp out/arch/arm64/boot/Image anykernel/kernels/
    if [ -d out/arch/arm64/boot/dts ]; then
        find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > anykernel/kernels/dtb || true
    fi
    cd anykernel
    zip -r9 "../Kernel_${TARGET_DEVICE}_KSU_SUSFS_MIUI_$(date +'%Y%m%d').zip" ./* -x .git .gitignore
    cd -
    log "🎉 刷机包已生成！"
else
    die "❌ 编译失败：未找到 out/arch/arm64/boot/Image，请检查上方日志。"
fi

# 若能顺利到这一步，正常退出（trap 会调用 cleanup_and_exit）
trap - EXIT
exit 0
