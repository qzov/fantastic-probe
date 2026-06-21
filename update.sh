#!/bin/bash
export LC_ALL=C.UTF-8

#==============================================================================
# Fantastic-Probe 更新脚本
# 功能：检查更新、备份当前版本、执行更新、支持回滚
#==============================================================================

set -euo pipefail

# 可配置的仓库地址（仓库迁移时只需改这里）
GITHUB_REPO="qzov/fantastic-probe"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh"

# Determine script directory (works for both file and pipe modes)
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR=""
fi
BACKUP_DIR="/var/backups/fantastic-probe"
CURRENT_VERSION="1.3.1"  # 硬编码默认值

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/get-version.sh" ]; then
    source "$SCRIPT_DIR/get-version.sh"
    CURRENT_VERSION="$VERSION"
elif [ -n "$SCRIPT_DIR" ] && command -v git &> /dev/null && [ -d "$SCRIPT_DIR/.git" ]; then
    CURRENT_VERSION=$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "1.3.1")
elif [ -f /usr/local/bin/get-version.sh ]; then
    source /usr/local/bin/get-version.sh
    CURRENT_VERSION="$VERSION"
fi

#==============================================================================
#==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}ℹ  $1${NC}"
}

warn() {
    echo -e "${YELLOW}  $1${NC}"
}

error() {
    echo -e "${RED} $1${NC}"
}

success() {
    echo -e "${GREEN} $1${NC}"
}

#==============================================================================
#==============================================================================

version_gt() {
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

#==============================================================================
# 回滚功能
#==============================================================================

rollback() {
    local backup_path="$1"

    if [ ! -d "$backup_path" ]; then
        error "备份目录不存在: $backup_path"
        return 1
    fi

    local backup_version
    backup_version=$(cat "$backup_path/version.txt" 2>/dev/null || echo "未知")

    echo ""
    echo "=========================================="
    info "回滚到版本: $backup_version"
    echo "=========================================="
    echo ""

    # 恢复脚本文件
    if [ -f "$backup_path/bin/fantastic-probe-cron-scanner" ]; then
        cp "$backup_path/bin/fantastic-probe-cron-scanner" /usr/local/bin/fantastic-probe-cron-scanner
        chmod +x /usr/local/bin/fantastic-probe-cron-scanner
        echo "  ✓ 已恢复 cron 扫描器"
    fi

    if [ -f "$backup_path/bin/fp-config" ]; then
        cp "$backup_path/bin/fp-config" /usr/local/bin/fp-config
        chmod +x /usr/local/bin/fp-config
        echo "  ✓ 已恢复配置工具"
    fi

    if [ -f "$backup_path/bin/get-version.sh" ]; then
        cp "$backup_path/bin/get-version.sh" /usr/local/bin/get-version.sh
        chmod +x /usr/local/bin/get-version.sh
        echo "  ✓ 已恢复版本脚本"
    fi

    if [ -f "$backup_path/lib/fantastic-probe-process-lib.sh" ]; then
        cp "$backup_path/lib/fantastic-probe-process-lib.sh" /usr/local/lib/fantastic-probe-process-lib.sh
        chmod +x /usr/local/lib/fantastic-probe-process-lib.sh
        echo "  ✓ 已恢复处理库"
    fi

    if [ -f "$backup_path/lib/fantastic-probe-upload-lib.sh" ]; then
        cp "$backup_path/lib/fantastic-probe-upload-lib.sh" /usr/local/lib/fantastic-probe-upload-lib.sh
        chmod +x /usr/local/lib/fantastic-probe-upload-lib.sh
        echo "  ✓ 已恢复上传库"
    fi

    if [ -f "$backup_path/bin/ffprobe" ]; then
        cp "$backup_path/bin/ffprobe" /usr/local/bin/ffprobe
        chmod +x /usr/local/bin/ffprobe
        echo "  ✓ 已恢复 ffprobe"
    fi

    # 询问是否恢复配置
    if [ -d "$backup_path/etc/fantastic-probe" ]; then
        read -p "是否恢复配置文件？(y/N): " -n 1 -r restore_config
        echo ""
        if [[ $restore_config =~ ^[Yy]$ ]]; then
            cp -r "$backup_path/etc/fantastic-probe/"* /etc/fantastic-probe/
            echo "  ✓ 已恢复配置文件"
        else
            echo "  ℹ  保持当前配置"
        fi
    fi

    echo ""
    success "回滚完成！已恢复到 v$backup_version"
    return 0
}

#==============================================================================
# 主流程
#==============================================================================

# 支持 --rollback <备份路径> 命令行参数
if [ "${1:-}" = "--rollback" ]; then
    if [ -z "${2:-}" ]; then
        echo "用法: sudo update.sh --rollback <备份路径>"
        echo ""
        echo "可用备份列表："
        if [ -d "$BACKUP_DIR" ]; then
            ls -1d "$BACKUP_DIR"/*/ 2>/dev/null || echo "  (无备份)"
        else
            echo "  (无备份)"
        fi
        exit 1
    fi
    rollback "$2"
    exit $?
fi

echo "=========================================="
echo "Fantastic-Probe 更新检查"
echo "=========================================="
echo ""

if [ "$EUID" -ne 0 ]; then
    error "请使用 root 权限运行此脚本"
    echo "   sudo update.sh"
    exit 1
fi

if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
    error "缺少网络工具（curl 或 wget）"
    exit 1
fi

info "检查最新版本..."

if command -v curl &> /dev/null; then
    VERSION_INFO=$(curl -fsSL "$GITHUB_API_URL" 2>/dev/null)
elif command -v wget &> /dev/null; then
    VERSION_INFO=$(wget -qO- "$GITHUB_API_URL" 2>/dev/null)
fi

if [ -z "$VERSION_INFO" ]; then
    error "无法获取版本信息，请检查网络连接"
    exit 1
fi

if command -v jq &> /dev/null; then
    LATEST_VERSION=$(echo "$VERSION_INFO" | jq -r '.tag_name' | sed 's/^v//')
    RELEASE_DATE=$(echo "$VERSION_INFO" | jq -r '.published_at' | cut -d'T' -f1)
    CHANGELOG=$(echo "$VERSION_INFO" | jq -r '.body' | head -5)
else
    LATEST_VERSION=$(echo "$VERSION_INFO" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1 | sed 's/^v//')
    RELEASE_DATE=$(echo "$VERSION_INFO" | grep -oP '"published_at":\s*"\K[^"]+' | head -1 | cut -d'T' -f1)
    CHANGELOG="查看详情: https://github.com/qzov/fantastic-probe/releases/latest"
fi

if [ -z "$LATEST_VERSION" ]; then
    error "无法解析版本信息"
    exit 1
fi

echo ""
echo "当前版本: $CURRENT_VERSION"
echo "最新版本: $LATEST_VERSION"
echo "发布日期: $RELEASE_DATE"
echo ""

if [ "$LATEST_VERSION" = "$CURRENT_VERSION" ]; then
    success "已是最新版本！"
    exit 0
elif version_gt "$CURRENT_VERSION" "$LATEST_VERSION"; then
    warn "当前版本高于远程版本（可能是开发版本）"
    exit 0
fi

echo -e "${BLUE} 发现新版本！${NC}"
echo ""
echo "更新内容："
echo "  $CHANGELOG"
echo ""

read -p "是否现在更新？[Y/n]: " do_update
do_update="${do_update:-Y}"

if [[ ! "$do_update" =~ ^[Yy]$ ]]; then
    info "已取消更新"
    exit 0
fi

echo ""
info "开始更新 Fantastic-Probe..."
echo "=========================================="
echo ""

# 创建备份
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/${CURRENT_VERSION}_${BACKUP_TIMESTAMP}"

info "创建备份..."
mkdir -p "$BACKUP_DIR"
mkdir -p "$BACKUP_PATH/bin" "$BACKUP_PATH/lib" "$BACKUP_PATH/etc"

# 备份已安装的脚本
for f in fantastic-probe-cron-scanner fp-config get-version.sh; do
    [ -f "/usr/local/bin/$f" ] && cp "/usr/local/bin/$f" "$BACKUP_PATH/bin/"
done

for f in fantastic-probe-process-lib.sh fantastic-probe-upload-lib.sh; do
    [ -f "/usr/local/lib/$f" ] && cp "/usr/local/lib/$f" "$BACKUP_PATH/lib/"
done

[ -f "/usr/local/bin/ffprobe" ] && cp /usr/local/bin/ffprobe "$BACKUP_PATH/bin/"
[ -d "/etc/fantastic-probe" ] && cp -r /etc/fantastic-probe "$BACKUP_PATH/etc/"

echo "$CURRENT_VERSION" > "$BACKUP_PATH/version.txt"
echo "$BACKUP_TIMESTAMP" > "$BACKUP_PATH/timestamp.txt"

success "备份完成: $BACKUP_PATH"
echo ""

# 执行更新
if command -v curl &> /dev/null; then
    curl -fsSL "$INSTALL_SCRIPT_URL" | bash
    UPDATE_EXIT_CODE=$?
elif command -v wget &> /dev/null; then
    wget -qO- "$INSTALL_SCRIPT_URL" | bash
    UPDATE_EXIT_CODE=$?
else
    UPDATE_EXIT_CODE=1
fi

if [ $UPDATE_EXIT_CODE -eq 0 ]; then
    echo ""
    echo "=========================================="
    success "更新完成！(v$CURRENT_VERSION → v$LATEST_VERSION)"
    echo "=========================================="
    echo ""
    echo "备份位置: $BACKUP_PATH"
    echo "回滚命令: sudo update.sh --rollback $BACKUP_PATH"
    echo ""
else
    echo ""
    echo "=========================================="
    error "更新失败（退出码: $UPDATE_EXIT_CODE）"
    echo "=========================================="
    echo ""
    warn "备份已保存: $BACKUP_PATH"
    echo ""
    read -p "是否立即回滚到更新前版本？[Y/n]: " do_rollback
    do_rollback="${do_rollback:-Y}"

    if [[ "$do_rollback" =~ ^[Yy]$ ]]; then
        rollback "$BACKUP_PATH"
    else
        echo "手动回滚命令: sudo update.sh --rollback $BACKUP_PATH"
    fi
    exit 1
fi
