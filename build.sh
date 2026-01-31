# ==============================================================================
# [新增] 光速验证环节：只编译驱动，不编译内核其他部分
# ==============================================================================
echo "⚡️ 正在进行光速验证 (SukiSU Driver Check)..."

# 1. 尝试单独编译 drivers/kernelsu 目录
# 这只会花几十秒，而不是半小时
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
    
    # 检查 'ksu_vfs_read_hook' 是否存在 (T=Text段/代码, D/B=Data段/变量)
    # grep -q 用于静默搜索，如果找到了返回 0
    if nm "$KSU_OBJ" | grep -q "ksu_vfs_read_hook"; then
        echo "✅ [验证通过] 恭喜！'ksu_vfs_read_hook' 已成功注入！"
        echo "   (符号类型: $(nm "$KSU_OBJ" | grep "ksu_vfs_read_hook"))"
    else
        echo "❌ [验证失败] 致命错误！ksu.o 生成了，但里面依然没有 'ksu_vfs_read_hook'！"
        echo "   这就意味着等到最后链接时肯定会报错，脚本已自动停止，为你省下30分钟。"
        exit 1
    fi
    
    # 顺便检查一下 execveat
    if nm "$KSU_OBJ" | grep -q "ksu_handle_execveat"; then
        echo "✅ [验证通过] 'ksu_handle_execveat' 也存在。"
    else
        echo "❌ [验证失败] 缺少 'ksu_handle_execveat'。"
        exit 1
    fi

else
    echo "❌ [验证失败] 找不到 $KSU_OBJ 文件，编译路径可能不对。"
    exit 1
fi

echo "🎉 验证通过！现在的驱动是完美的。开始完整编译..."
# ==============================================================================
