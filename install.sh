#!/bin/bash

#==============================================================================
#==============================================================================

set -e

REPO_URL="https://github.com/qzov/fantastic-probe"
REPO_RAW_URL="https://raw.githubusercontent.com/qzov/fantastic-probe"
VERSION="${1:-main}"  # 默认使用 main 分支，可指定版本标签
INSTALL_DIR="/tmp/fantastic-probe-install-$$"

cleanup() {
    if [ -d "$INSTALL_DIR" ]; then
        echo "清理临时文件..."
        cd /
        rm -rf "$INSTALL_DIR"
    fi
}

trap cleanup EXIT INT TERM

#==============================================================================
#==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

echo "=========================================="
echo "Fantastic-Probe 一键安装"
echo "=========================================="
echo ""

if [ "$EUID" -ne 0 ]; then
    error "请使用 root 权限运行此脚本"
    echo "   curl -fsSL https://raw.githubusercontent.com/qzov/fantastic-probe/main/install.sh | sudo bash"
    exit 1
fi

info "检测系统环境..."
if [ -f /etc/os-release ]; then
    INSTALL_VERSION="$VERSION"
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "   发行版: $NAME"
    VERSION="$INSTALL_VERSION"
else
    warn "无法检测发行版信息"
fi

info "检查必需工具..."
MISSING_TOOLS=()

if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
    MISSING_TOOLS+=("curl 或 wget")
fi

if ! command -v tar &> /dev/null; then
    MISSING_TOOLS+=("tar")
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    error "缺少必需工具: ${MISSING_TOOLS[*]}"
    echo ""
    echo "请先安装这些工具："
    echo "  Debian/Ubuntu: apt-get install curl tar"
    echo "  RHEL/CentOS:   dnf install curl tar"
    echo "  Arch Linux:    pacman -S curl tar"
    exit 1
fi

info "下载 Fantastic-Probe (版本: $VERSION)..."

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [ "$VERSION" = "main" ]; then
    DOWNLOAD_URL="$REPO_URL/archive/refs/heads/main.tar.gz"
else
    DOWNLOAD_URL="$REPO_URL/archive/refs/tags/$VERSION.tar.gz"
fi

echo "   正在下载，请稍候..."
if command -v curl &> /dev/null; then
    curl -fL "$DOWNLOAD_URL" -o fantastic-probe.tar.gz --progress-bar
elif command -v wget &> /dev/null; then
    wget --show-progress "$DOWNLOAD_URL" -O fantastic-probe.tar.gz
fi

if [ ! -f fantastic-probe.tar.gz ]; then
    error "下载失败，请检查网络连接或版本号是否正确"
    echo "   仓库地址: $REPO_URL"
    echo "   版本: $VERSION"
    exit 1
fi

success "下载完成"

info "解压文件..."
tar -xzf fantastic-probe.tar.gz --strip-components=1
success "解压完成"

echo ""
info "开始安装 Fantastic-Probe..."
echo "=========================================="
echo ""

if [ -f "$INSTALL_DIR/fantastic-probe-install.sh" ]; then
    bash "$INSTALL_DIR/fantastic-probe-install.sh"
else
    error "找不到安装脚本: fantastic-probe-install.sh"
    exit 1
fi

echo ""
echo "=========================================="
success "Fantastic-Probe 安装完成！"
echo "=========================================="
echo ""
echo " Cron 任务已配置，每 1 分钟自动扫描一次"
echo ""
echo "常用命令："
echo "  查看 Cron 日志:   tail -f /var/log/fantastic_probe.log"
echo "  查看失败文件:     fp-config failure-list"
echo "  清空失败缓存:     fp-config failure-clear"
echo "  配置管理工具:     fp-config"
echo ""
echo "配置文件位置: /etc/fantastic-probe/config"
echo "修改配置后 Cron 会自动生效"
echo ""
