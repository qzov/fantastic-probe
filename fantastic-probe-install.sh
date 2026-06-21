#!/bin/bash
export LC_ALL=C.UTF-8

#==============================================================================
#==============================================================================

set -eo pipefail

#==============================================================================
#==============================================================================

detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    elif command -v zypper &> /dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        echo "$NAME"
    else
        echo "Unknown"
    fi
}

install_package() {
    local pkg_manager="$1"
    shift
    local packages=("$@")

    echo "   使用包管理器: $pkg_manager"
    echo "   安装软件包: ${packages[*]}"

    case "$pkg_manager" in
        apt)
            apt-get update -qq
            apt-get install -y "${packages[@]}"
            ;;
        dnf)
            dnf install -y "${packages[@]}"
            ;;
        yum)
            yum install -y "${packages[@]}"
            ;;
        pacman)
            pacman -Sy --noconfirm "${packages[@]}"
            ;;
        zypper)
            zypper install -y "${packages[@]}"
            ;;
        *)
            echo " 错误: 不支持的包管理器: $pkg_manager"
            return 1
            ;;
    esac
}

get_package_name() {
    local pkg_manager="$1"
    local package_type="$2"

    case "$package_type" in
        jq)
            echo "jq"
            ;;
        sqlite3)
            if [ "$pkg_manager" = "apt" ]; then
                echo "sqlite3"
            elif [ "$pkg_manager" = "pacman" ]; then
                echo "sqlite"
            else
                echo "sqlite3"
            fi
            ;;
        libbluray)
            if [ "$pkg_manager" = "apt" ]; then
                echo "libbluray-bin"
            elif [ "$pkg_manager" = "pacman" ]; then
                echo "libbluray"
            elif [ "$pkg_manager" = "dnf" ] || [ "$pkg_manager" = "yum" ]; then
                echo "libbluray-utils"
            elif [ "$pkg_manager" = "zypper" ]; then
                echo "libbluray-tools"
            else
                echo "libbluray-bin"
            fi
            ;;
        *)
            echo "$package_type"
            ;;
    esac
}

#==============================================================================
# 从 BtbN/FFmpeg-Builds 下载预编译 ffprobe（GPL 构建，含 libbluray/libdvdread）
# BtbN 项目每日自动构建，latest tag 始终指向最新版本，稳定运行超 4 年
#==============================================================================

FFPROBE_DOWNLOAD_BASE="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest"

install_ffprobe_prebuilt() {
    local arch="$1"
    local pkg_manager="$2"
    local download_url=""
    local archive_name=""
    local extract_dir=""

    case "$arch" in
        x86_64)
            archive_name="ffmpeg-master-latest-linux64-gpl.tar.xz"
            extract_dir="ffmpeg-master-latest-linux64-gpl"
            ;;
        aarch64)
            archive_name="ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
            extract_dir="ffmpeg-master-latest-linuxarm64-gpl"
            ;;
        *)
            echo "       当前架构 ($arch) 不支持 BtbN 预编译包"
            echo "       BtbN 仅提供 x86_64 和 aarch64 (ARM64) 构建"
            return 1
            ;;
    esac

    download_url="${FFPROBE_DOWNLOAD_BASE}/${archive_name}"

    # 确保 xz 解压支持
    if ! command -v xz &> /dev/null; then
        echo "        需要安装 xz 解压工具..."
        install_package "$pkg_manager" "xz" 2>/dev/null || \
        install_package "$pkg_manager" "xz-utils" 2>/dev/null || {
            echo "        无法安装 xz 工具，请手动安装后重试"
            return 1
        }
    fi

    local temp_dir
    temp_dir=$(mktemp -d /tmp/ffprobe-install-XXXXXX)

    echo "       从 BtbN/FFmpeg-Builds 下载预编译 ffprobe..."
    echo "       下载地址: $download_url"

    if command -v curl &> /dev/null; then
        if ! curl -fL --progress-bar "$download_url" -o "$temp_dir/$archive_name"; then
            echo "       下载失败（网络错误或 GitHub 不可达）"
            rm -rf "$temp_dir"
            return 1
        fi
    elif command -v wget &> /dev/null; then
        if ! wget --show-progress "$download_url" -O "$temp_dir/$archive_name" 2>&1; then
            echo "       下载失败（网络错误或 GitHub 不可达）"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        echo "       错误: 需要 curl 或 wget"
        rm -rf "$temp_dir"
        return 1
    fi

    echo "       下载完成，正在解压..."

    if ! tar -xf "$temp_dir/$archive_name" -C "$temp_dir" 2>/dev/null; then
        echo "       解压失败（文件可能损坏）"
        rm -rf "$temp_dir"
        return 1
    fi

    local ffprobe_bin="${temp_dir}/${extract_dir}/bin/ffprobe"

    if [ ! -f "$ffprobe_bin" ]; then
        echo "       错误: 解压后未找到 ffprobe"
        echo "       查找路径: $ffprobe_bin"
        rm -rf "$temp_dir"
        return 1
    fi

    # 安装 ffprobe
    cp "$ffprobe_bin" /usr/local/bin/ffprobe
    chmod +x /usr/local/bin/ffprobe

    if ! /usr/local/bin/ffprobe -version &> /dev/null; then
        echo "       安装失败: ffprobe 无法执行（可能缺少运行时库）"
        rm -rf "$temp_dir"
        return 1
    fi

    echo "       ffprobe 已安装到: /usr/local/bin/ffprobe"

    # 缓存预编译包供后续重装使用
    local target_static_dir="/usr/share/fantastic-probe/static"
    mkdir -p "$target_static_dir"
    cp "$temp_dir/$archive_name" "$target_static_dir/$archive_name"
    echo "       预编译包已缓存到: $target_static_dir/$archive_name"

    rm -rf "$temp_dir"
    echo "       安装成功！"
    return 0
}

#==============================================================================
# FFprobe 配置向导（统一处理初次安装和重新配置）
# 参数: $1 = pkg_manager, $2 = 模式 ("install" 或 "reconfigure")
# 输出: 设置全局变量 user_ffprobe
#==============================================================================

configure_ffprobe() {
    local pkg_manager="$1"
    local mode="${2:-install}"  # install 或 reconfigure

    user_ffprobe=""  # 全局变量，由调用方使用

    echo ""
    echo "    FFprobe 路径配置"
    echo "      说明：ffprobe 用于提取蓝光/DVD 媒体信息"
    echo "      来源：BtbN/FFmpeg-Builds GPL 构建（含 libbluray、libdvdread 支持）"
    echo ""

    local arch
    arch=$(uname -m)

    local arch_name=""
    local prebuilt_available=false

    case "$arch" in
        x86_64)
            arch_name="x86_64"
            prebuilt_available=true
            ;;
        aarch64)
            arch_name="ARM64 (aarch64)"
            prebuilt_available=true
            ;;
        *)
            arch_name="$arch (不支持预编译)"
            prebuilt_available=false
            ;;
    esac

    echo "       检测到架构: $arch_name"
    echo ""
    echo "      选项："

    if [ "$prebuilt_available" = true ]; then
        echo "        1) 使用 BtbN 预编译 ffprobe（推荐，含蓝光/DVD 协议支持）"
    else
        echo "        1) 预编译包不支持当前架构 ($arch)"
    fi
    echo "        2) 使用系统已安装的 ffprobe（需先安装 ffmpeg）"
    echo "        3) 手动指定 ffprobe 路径"
    echo ""

    read -p "      请选择 [1/2/3，默认: 1]: " ffprobe_choice
    ffprobe_choice="${ffprobe_choice:-1}"

    case "$ffprobe_choice" in
        1)
            if [ "$prebuilt_available" = false ]; then
                echo "       当前架构不支持 BtbN 预编译包"
                echo "       将自动降级为选项 2（系统 ffprobe）..."
                ffprobe_choice=2
            else
                echo ""
                if install_ffprobe_prebuilt "$arch" "$pkg_manager"; then
                    user_ffprobe="/usr/local/bin/ffprobe"
                else
                    echo ""
                    echo "       预编译包下载失败！"
                    echo ""
                    echo "       可能原因："
                    echo "         - 网络连接问题（无法访问 GitHub）"
                    echo "         - GitHub API 限流"
                    echo "         - BtbN 仓库暂时不可用"
                    echo ""
                    echo "       自动降级提示："
                    echo "       ----------------------------------------"
                    echo "       请选择替代方案："
                    echo "         a) 尝试安装系统 ffmpeg（含 ffprobe）"
                    echo "         b) 手动指定 ffprobe 路径"
                    echo "         c) 跳过（稍后使用 fp-config 配置）"
                    echo "       ----------------------------------------"
                    echo ""
                    read -p "      请选择 [a/b/c，默认: a]: " fallback_choice
                    fallback_choice="${fallback_choice:-a}"

                    case "$fallback_choice" in
                        a)
                            ffprobe_choice=2  # 走系统 ffprobe 逻辑
                            ;;
                        b)
                            ffprobe_choice=3  # 走手动指定逻辑
                            ;;
                        *)
                            user_ffprobe="/usr/bin/ffprobe"
                            echo "        已跳过，使用默认占位路径: $user_ffprobe"
                            echo "        请安装后运行 'sudo fp-config ffprobe' 完成配置"
                            return 0
                            ;;
                    esac
                fi
            fi
            ;;&  # 使用 ;;& 继续匹配后续 case（bash 4.0+）
        2)
            if [ "$user_ffprobe" = "/usr/local/bin/ffprobe" ]; then
                return 0  # 已通过选项1成功安装
            fi

            if command -v ffprobe &> /dev/null; then
                detected_ffprobe=$(command -v ffprobe)
                echo "       检测到: $detected_ffprobe"
                user_ffprobe="$detected_ffprobe"
            else
                echo "       系统中未检测到 ffprobe"
                echo ""
                echo "      请先安装 ffmpeg："
                echo "         Debian/Ubuntu: apt-get install -y ffmpeg"
                echo "         RHEL/CentOS:   dnf install -y ffmpeg"
                echo "         Arch Linux:    pacman -S ffmpeg"
                echo ""
                read -p "      现在安装 ffmpeg？[y/N]: " install_now

                if [[ "$install_now" =~ ^[Yy]$ ]]; then
                    install_package "$pkg_manager" "ffmpeg"
                    if command -v ffprobe &> /dev/null; then
                        user_ffprobe=$(command -v ffprobe)
                        echo "       ffmpeg 安装成功: $user_ffprobe"
                    else
                        echo "       安装失败"
                        user_ffprobe=""
                    fi
                else
                    user_ffprobe=""
                fi
            fi
            ;;
        3)
            echo ""
            read -p "      请输入 ffprobe 完整路径: " user_ffprobe

            if [ -z "$user_ffprobe" ]; then
                echo "        路径为空"
                user_ffprobe=""
            elif [ ! -f "$user_ffprobe" ]; then
                echo "        文件不存在: $user_ffprobe"
                user_ffprobe=""
            elif [ ! -x "$user_ffprobe" ]; then
                echo "        文件不可执行: $user_ffprobe"
                user_ffprobe=""
            else
                echo "       使用指定路径: $user_ffprobe"
            fi
            ;;
        *)
            echo "        无效选择"
            user_ffprobe=""
            ;;
    esac

    # 如果仍未设置 ffprobe，提供兜底手动配置
    if [ -z "$user_ffprobe" ]; then
        echo ""
        echo "       手动配置 FFprobe（兜底）"
        echo ""
        echo "      选项："
        echo "        1) 使用系统已安装的 ffprobe（需先安装 ffmpeg）"
        echo "        2) 手动指定 ffprobe 路径"
        if [ "$mode" = "reconfigure" ]; then
            echo "        3) 保持原配置不变"
        else
            echo "        3) 跳过配置（稍后使用 fp-config 配置）"
        fi
        echo ""
        read -p "      请选择 [1/2/3，默认: 1]: " manual_choice
        manual_choice="${manual_choice:-1}"

        case "$manual_choice" in
            1)
                if command -v ffprobe &> /dev/null; then
                    detected_ffprobe=$(command -v ffprobe)
                    echo "       检测到: $detected_ffprobe"
                    user_ffprobe="$detected_ffprobe"
                else
                    echo "       系统中未检测到 ffprobe"
                    echo ""
                    echo "      请先安装 ffmpeg："
                    echo "         Debian/Ubuntu: apt-get install -y ffmpeg"
                    echo "         RHEL/CentOS:   dnf install -y ffmpeg"
                    echo "         Arch Linux:    pacman -S ffmpeg"
                    echo ""
                    read -p "      现在安装 ffmpeg？[y/N]: " install_now

                    if [[ "$install_now" =~ ^[Yy]$ ]]; then
                        install_package "$pkg_manager" "ffmpeg"
                        if command -v ffprobe &> /dev/null; then
                            user_ffprobe=$(command -v ffprobe)
                            echo "       ffmpeg 安装成功: $user_ffprobe"
                        else
                            echo "       安装失败"
                            user_ffprobe="/usr/bin/ffprobe"  # 占位符
                        fi
                    else
                        user_ffprobe="/usr/bin/ffprobe"  # 占位符
                    fi
                fi
                ;;
            2)
                echo ""
                read -p "      请输入 ffprobe 完整路径: " user_ffprobe

                if [ -z "$user_ffprobe" ]; then
                    user_ffprobe="/usr/bin/ffprobe"  # 占位符
                    echo "        路径为空，使用默认值: $user_ffprobe"
                fi
                ;;
            3)
                if [ "$mode" = "reconfigure" ] && [ -f "$CONFIG_FILE" ]; then
                    user_ffprobe=$(grep "^FFPROBE=" "$CONFIG_FILE" | cut -d'"' -f2)
                    echo "      保持原配置: $user_ffprobe"
                else
                    user_ffprobe="/usr/bin/ffprobe"  # 占位符
                    echo "        已跳过配置，将使用默认路径: $user_ffprobe"
                fi
                ;;
            *)
                user_ffprobe="/usr/bin/ffprobe"  # 占位符
                echo "        无效选择，使用默认值: $user_ffprobe"
                ;;
        esac
    fi
}

#==============================================================================
#==============================================================================

echo "=========================================="
echo "ISO 媒体信息提取服务 - 安装程序"
echo "=========================================="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo " 请使用 root 权限运行此脚本"
    echo "   sudo bash $0"
    exit 1
fi

PKG_MANAGER=$(detect_package_manager)
DISTRO=$(detect_distro)

echo " 系统信息："
echo "   发行版: $DISTRO"
echo "   包管理器: $PKG_MANAGER"
echo ""

if [ "$PKG_MANAGER" = "unknown" ]; then
    echo " 错误: 无法识别的包管理器"
    echo ""
    echo "支持的发行版："
    echo "  - Debian/Ubuntu (apt)"
    echo "  - RHEL/CentOS/Fedora (dnf/yum)"
    echo "  - Arch Linux/Manjaro (pacman)"
    echo "  - openSUSE (zypper)"
    echo ""
    echo "请手动安装以下依赖："
    echo "  - jq"
    echo "  - sqlite3"
    echo "  - libbluray-bin (或 libbluray-utils / libbluray-tools，提供 bd_list_titles)"
    echo ""
    exit 1
fi

# Detect install mode and resolve project directory
REPO_URL="https://github.com/qzov/fantastic-probe"
REPO_ARCHIVE_URL="${REPO_URL}/archive/refs/heads/main.tar.gz"

if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
    # Mode 1: Running from a local file (./install.sh or bash install.sh)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # Mode 2: Running from pipe (curl | bash)
    SCRIPT_DIR=$(mktemp -d)
    trap "rm -rf '$SCRIPT_DIR'" EXIT
    echo "检测到管道安装模式，下载项目文件..."

    download_ok=false

    if command -v git &>/dev/null; then
        echo "  使用 git clone..."
        if git clone --depth 1 "${REPO_URL}.git" "$SCRIPT_DIR" 2>&1 | sed 's/^/  /'; then
            download_ok=true
        else
            echo "  git clone 失败，尝试其它方式..."
        fi
    fi

    if [ "$download_ok" = false ] && command -v curl &>/dev/null; then
        echo "  使用 curl 下载..."
        if curl -fsSL "$REPO_ARCHIVE_URL" | tar xz -C "$SCRIPT_DIR" --strip-components=1 2>/dev/null; then
            download_ok=true
        else
            echo "  curl 下载失败，尝试 wget..."
        fi
    fi

    if [ "$download_ok" = false ] && command -v wget &>/dev/null; then
        echo "  使用 wget 下载..."
        if wget -qO- "$REPO_ARCHIVE_URL" | tar xz -C "$SCRIPT_DIR" --strip-components=1 2>/dev/null; then
            download_ok=true
        fi
    fi

    if [ "$download_ok" = false ]; then
        echo "错误: 无法下载项目文件"
        echo "  请手动克隆: git clone ${REPO_URL}.git"
        exit 1
    fi

    echo "  ✓ 下载完成"
fi

echo " 脚本目录: $SCRIPT_DIR"
echo ""

echo "1⃣  检查并安装依赖..."
echo ""

PACKAGES_TO_INSTALL=()
MISSING_COMMANDS=()

if ! command -v python3 &> /dev/null; then
    pkg_name="python3"
    echo "   需要安装: $pkg_name (bd_list_titles 输出解析必需)"
    PACKAGES_TO_INSTALL+=($pkg_name)
    MISSING_COMMANDS+=("python3")
fi

if ! command -v sqlite3 &> /dev/null; then
    pkg_name=$(get_package_name "$PKG_MANAGER" "sqlite3")
    echo "   需要安装: $pkg_name (失败记录数据库必需)"
    PACKAGES_TO_INSTALL+=($pkg_name)
    MISSING_COMMANDS+=("sqlite3")
fi

if ! command -v jq &> /dev/null; then
    pkg_name=$(get_package_name "$PKG_MANAGER" "jq")
    echo "   需要安装: $pkg_name (JSON 处理必需)"
    PACKAGES_TO_INSTALL+=($pkg_name)
    MISSING_COMMANDS+=("jq")
fi

if ! command -v bd_list_titles &> /dev/null; then
    pkg_name=$(get_package_name "$PKG_MANAGER" "libbluray")
    echo "   需要安装: $pkg_name (蓝光语言标签提取必需)"
    PACKAGES_TO_INSTALL+=($pkg_name)
    MISSING_COMMANDS+=("bd_list_titles")
fi

if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then
    echo ""
    echo "   即将安装 ${#PACKAGES_TO_INSTALL[@]} 个依赖包..."
    install_package "$PKG_MANAGER" "${PACKAGES_TO_INSTALL[@]}"

    echo ""
    echo "   验证安装结果..."
    FAILED_DEPS=()
    for cmd in "${MISSING_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            FAILED_DEPS+=("$cmd")
        fi
    done

    if [ ${#FAILED_DEPS[@]} -gt 0 ]; then
        echo "    以下依赖安装失败："
        printf '      - %s\n' "${FAILED_DEPS[@]}"
        echo ""
        echo "   请手动安装失败的依赖后重新运行安装脚本"
        exit 1
    fi

    echo "    所有依赖安装成功"
else
    echo "    所有依赖已安装"
fi
echo ""

echo "2⃣  安装 Cron 扫描器和处理库..."

VERSION_SCRIPT="$SCRIPT_DIR/get-version.sh"
TARGET_VERSION_SCRIPT="/usr/local/bin/get-version.sh"

if [ -f "$VERSION_SCRIPT" ]; then
    cp "$VERSION_SCRIPT" "$TARGET_VERSION_SCRIPT"
    chmod +x "$TARGET_VERSION_SCRIPT"
    echo "    版本号获取脚本已安装到: $TARGET_VERSION_SCRIPT"
else
    echo "     版本号获取脚本不存在（不影响正常使用，将使用硬编码版本号）"
fi
echo ""

CONFIG_TOOL="$SCRIPT_DIR/fp-config.sh"
TARGET_CONFIG_TOOL="/usr/local/bin/fp-config"
TARGET_CONFIG_TOOL_OLD="/usr/local/bin/fantastic-probe-config"

if [ -f "$CONFIG_TOOL" ]; then
    cp "$CONFIG_TOOL" "$TARGET_CONFIG_TOOL"
    chmod +x "$TARGET_CONFIG_TOOL"
    echo "    配置工具已安装到: $TARGET_CONFIG_TOOL"

    ln -sf "$TARGET_CONFIG_TOOL" "$TARGET_CONFIG_TOOL_OLD"
    echo "    兼容链接已创建: $TARGET_CONFIG_TOOL_OLD"

    echo "      提示：使用 'sudo fp-config' 可随时修改配置"
else
    echo "     未找到配置工具（跳过，不影响正常使用）"
fi
echo ""

echo "    安装 Cron 扫描器和处理库..."

CRON_SCANNER="$SCRIPT_DIR/fantastic-probe-cron-scanner.sh"
PROCESS_LIB="$SCRIPT_DIR/fantastic-probe-process-lib.sh"
UPLOAD_LIB="$SCRIPT_DIR/fantastic-probe-upload-lib.sh"
TARGET_CRON_SCANNER="/usr/local/bin/fantastic-probe-cron-scanner"
TARGET_PROCESS_LIB="/usr/local/lib/fantastic-probe-process-lib.sh"
TARGET_UPLOAD_LIB="/usr/local/lib/fantastic-probe-upload-lib.sh"

if [ -f "$CRON_SCANNER" ]; then
    cp "$CRON_SCANNER" "$TARGET_CRON_SCANNER"
    chmod +x "$TARGET_CRON_SCANNER"
    echo "    Cron 扫描器已安装到: $TARGET_CRON_SCANNER"
else
    echo "     未找到 Cron 扫描器（跳过，不影响正常使用）"
fi

if [ -f "$PROCESS_LIB" ]; then
    mkdir -p /usr/local/lib
    cp "$PROCESS_LIB" "$TARGET_PROCESS_LIB"
    chmod +x "$TARGET_PROCESS_LIB"
    echo "    处理库已安装到: $TARGET_PROCESS_LIB"
else
    echo "     未找到处理库（跳过，不影响正常使用）"
fi

if [ -f "$UPLOAD_LIB" ]; then
    mkdir -p /usr/local/lib
    cp "$UPLOAD_LIB" "$TARGET_UPLOAD_LIB"
    chmod +x "$TARGET_UPLOAD_LIB"
    echo "    上传库已安装到: $TARGET_UPLOAD_LIB"
else
    echo "     未找到上传库文件: $UPLOAD_LIB"
    echo "     警告：目录上传功能将不可用"
    echo "     如需使用上传功能，请确保源码完整后重新安装"
fi

echo "    创建失败缓存目录..."
mkdir -p /var/lib/fantastic-probe
chmod 755 /var/lib/fantastic-probe
echo "    缓存目录已创建: /var/lib/fantastic-probe"

echo ""

echo "4⃣  配置服务..."
CONFIG_DIR="/etc/fantastic-probe"
CONFIG_FILE="$CONFIG_DIR/config"

mkdir -p "$CONFIG_DIR"

RECONFIGURE_FFPROBE=false
if [ -f "$CONFIG_FILE" ]; then
    echo "   发现现有配置文件: $CONFIG_FILE"
    echo ""
    echo "   配置选项："
    echo "     1) 保留现有配置（推荐，快速升级）"
    echo "     2) 仅重新配置 FFprobe 路径（推荐给想使用预编译包的用户）"
    echo "     3) 完全重新配置（重新设置所有配置项）"
    echo ""
    read -p "   请选择 [1/2/3，默认: 1]: " config_choice
    config_choice="${config_choice:-1}"

    case "$config_choice" in
        1)
            echo "    保留现有配置"
            CONFIG_WIZARD_SKIP=true
            ;;
        2)
            echo "   将重新配置 FFprobe 路径..."
            CONFIG_WIZARD_SKIP=true
            RECONFIGURE_FFPROBE=true
            ;;
        3)
            echo "   将完全重新配置..."
            CONFIG_WIZARD_SKIP=false
            ;;
        *)
            echo "     无效选择，默认保留现有配置"
            CONFIG_WIZARD_SKIP=true
            ;;
    esac
    echo ""
fi

if [ "$CONFIG_WIZARD_SKIP" != "true" ]; then
    echo ""
    echo "   配置向导："
    echo "   ----------"

    echo ""
    echo "    STRM 根目录配置"
    echo "      说明：监控的 .iso.strm 文件所在的根目录"
    read -p "      请输入路径 [默认: /mnt/media/strm]: " user_strm_root
    user_strm_root="${user_strm_root:-/mnt/media/strm}"

    if [ ! -d "$user_strm_root" ]; then
        echo "        警告: 目录不存在: $user_strm_root"
        read -p "      是否创建该目录？[Y/n]: " create_dir
        create_dir="${create_dir:-Y}"

        if [[ "$create_dir" =~ ^[Yy]$ ]]; then
            mkdir -p "$user_strm_root"
            echo "       目录已创建: $user_strm_root"

            echo ""
            echo "       权限配置"
            echo "         说明：如果其他用户（如 Emby、Jellyfin 或普通用户）需要向此目录写入文件，"
            echo "              请指定合适的所有者。"
            echo ""
            echo "         选项："
            echo "           1) 保持 root 所有（仅root可写入）"
            echo "           2) 设置为特定用户（如 emby、jellyfin 等）"
            echo "           3) 设置宽松权限（所有用户可写入，chmod 777）"
            echo ""
            read -p "         请选择 [1/2/3，默认: 1]: " owner_choice
            owner_choice="${owner_choice:-1}"

            case "$owner_choice" in
                1)
                    echo "          目录所有者: root:root (仅root可写入)"
                    ;;
                2)
                    read -p "         请输入用户名（如 emby）: " target_user
                    if id "$target_user" &>/dev/null; then
                        chown -R "$target_user:$target_user" "$user_strm_root"
                        chmod 755 "$user_strm_root"
                        echo "          目录所有者已设置为: $target_user:$target_user"
                    else
                        echo "           用户 '$target_user' 不存在，保持root所有"
                        echo "         提示：可在安装后手动设置: sudo chown -R 用户名:用户名 $user_strm_root"
                    fi
                    ;;
                3)
                    chmod 777 "$user_strm_root"
                    echo "          目录权限已设置为777（所有用户可写入）"
                    echo "           注意：这会降低安全性，仅建议用于测试环境"
                    ;;
                *)
                    echo "           无效选择，保持root所有"
                    ;;
            esac
        else
            echo "        请确保在启动服务前创建该目录"
        fi
    fi

    echo ""
    configure_ffprobe "$PKG_MANAGER" "install"

    echo ""
    if [ -n "$user_ffprobe" ] && [ -x "$user_ffprobe" ]; then
        echo "       FFprobe 配置完成: $user_ffprobe"
    else
        echo "        警告: ffprobe 不存在或不可执行: $user_ffprobe"
        echo "        服务可能无法正常启动！"
        echo ""
        echo "      安装后请执行以下操作之一："
        echo "        1) 安装 ffmpeg: apt-get install -y ffmpeg"
        echo "        2) 重新配置: fp-config ffprobe"
        echo "        3) 手动编辑: /etc/fantastic-probe/config"
        echo ""
        read -p "      按回车键继续安装..." dummy
    fi

    echo ""

    if [ -f "$CONFIG_FILE" ]; then
        echo "   检测到现有配置文件，将保留用户配置..."

        cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d_%H%M%S)"
        echo "    已备份现有配置"

        sed -i "s|^STRM_ROOT=.*|STRM_ROOT=\"$user_strm_root\"|" "$CONFIG_FILE"
        sed -i "s|^FFPROBE=.*|FFPROBE=\"$user_ffprobe\"|" "$CONFIG_FILE"
        echo "    已更新 STRM_ROOT 和 FFPROBE 配置"

        if ! grep -q "^EMBY_ENABLED=" "$CONFIG_FILE" 2>/dev/null; then
            echo "" >> "$CONFIG_FILE"
            echo "# Emby 媒体库集成（可选）" >> "$CONFIG_FILE"
            echo "EMBY_ENABLED=false" >> "$CONFIG_FILE"
            echo "EMBY_URL=\"\"" >> "$CONFIG_FILE"
            echo "EMBY_API_KEY=\"\"" >> "$CONFIG_FILE"
            echo "EMBY_NOTIFY_TIMEOUT=5" >> "$CONFIG_FILE"
            echo "    已补充 Emby 配置项（默认关闭）"
        else
            echo "    Emby 配置已保留"
        fi

        if ! grep -q "^AUTO_UPLOAD_ENABLED=" "$CONFIG_FILE" 2>/dev/null; then
            echo "" >> "$CONFIG_FILE"
            echo "# 自动上传配置（可选）" >> "$CONFIG_FILE"
            echo "AUTO_UPLOAD_ENABLED=false" >> "$CONFIG_FILE"
            echo "UPLOAD_FILE_TYPES=\"json\"" >> "$CONFIG_FILE"
            echo "UPLOAD_LOG_FILE=\"/var/log/fantastic_probe_upload.log\"" >> "$CONFIG_FILE"
            echo "UPLOAD_CACHE_DB=\"/var/lib/fantastic-probe/upload_cache.db\"" >> "$CONFIG_FILE"
            echo "UPLOAD_INTERVAL=10" >> "$CONFIG_FILE"
            echo "    已补充自动上传配置项（默认关闭）"
        else
            echo "    自动上传配置已保留"
        fi
    elif [ -f "$SCRIPT_DIR/config/config.template" ]; then
        echo "   生成新配置文件..."
        cp "$SCRIPT_DIR/config/config.template" "$CONFIG_FILE"
        sed -i "s|^STRM_ROOT=.*|STRM_ROOT=\"$user_strm_root\"|" "$CONFIG_FILE"
        sed -i "s|^FFPROBE=.*|FFPROBE=\"$user_ffprobe\"|" "$CONFIG_FILE"
    else
        cat > "$CONFIG_FILE" <<EOF

STRM_ROOT="$user_strm_root"

FFPROBE="$user_ffprobe"

LOG_FILE="/var/log/fantastic_probe.log"
ERROR_LOG_FILE="/var/log/fantastic_probe_errors.log"

LOCK_FILE="/tmp/fantastic_probe_monitor.lock"

QUEUE_FILE="/tmp/fantastic_probe_queue.fifo"

FFPROBE_TIMEOUT=300

MAX_FILE_PROCESSING_TIME=600

DEBOUNCE_TIME=5

EMBY_ENABLED=false
EMBY_URL=""
EMBY_API_KEY=""
EMBY_NOTIFY_TIMEOUT=5
EOF
    fi

    chmod 644 "$CONFIG_FILE"
    echo "    配置文件已生成: $CONFIG_FILE"
    echo ""
    echo "   配置摘要："
    echo "   - STRM 目录: $user_strm_root"
    echo "   - FFprobe 路径: $user_ffprobe"
    echo ""
fi

if [ "$RECONFIGURE_FFPROBE" = "true" ]; then
    echo ""
    echo "4⃣.5⃣  重新配置 FFprobe..."
    configure_ffprobe "$PKG_MANAGER" "reconfigure"

    if [ -n "$user_ffprobe" ] && [ -f "$CONFIG_FILE" ]; then
        sed -i.bak "s|^FFPROBE=.*|FFPROBE=\"$user_ffprobe\"|" "$CONFIG_FILE"
        rm -f "$CONFIG_FILE.bak"
        echo ""
        echo "    FFprobe 路径已更新: $user_ffprobe"

        if [ ! -x "$user_ffprobe" ]; then
            echo ""
            echo "     警告: ffprobe 不存在或不可执行: $user_ffprobe"
            echo "     服务可能无法正常启动！"
            echo ""
            echo "   请执行以下操作之一："
            echo "     1) 安装 ffmpeg: apt-get install -y ffmpeg"
            echo "     2) 重新配置: fp-config ffprobe"
            echo "     3) 手动编辑: /etc/fantastic-probe/config"
            echo ""
            read -p "   按回车键继续..." dummy
        fi
    elif [ -z "$user_ffprobe" ]; then
        echo "    错误: ffprobe 路径为空，无法更新配置"
    elif [ ! -f "$CONFIG_FILE" ]; then
        echo "    错误: 配置文件不存在: $CONFIG_FILE"
    fi
    echo ""
fi

echo "5⃣  创建日志文件..."
touch /var/log/fantastic_probe.log
touch /var/log/fantastic_probe_errors.log
chmod 644 /var/log/fantastic_probe.log
chmod 644 /var/log/fantastic_probe_errors.log
echo "    日志文件已创建"
echo ""

echo "6⃣  配置日志轮转..."
LOGROTATE_FILE="$SCRIPT_DIR/logrotate-fantastic-probe.conf"
TARGET_LOGROTATE="/etc/logrotate.d/fantastic-probe"

if [ -f "$LOGROTATE_FILE" ]; then
    cp "$LOGROTATE_FILE" "$TARGET_LOGROTATE"
    chmod 644 "$TARGET_LOGROTATE"
    echo "    logrotate 配置已安装"
    echo "   ℹ  日志文件达到 1MB 时自动轮转，保留最近 1 个备份（总空间约 2MB）"
else
    echo "     找不到 logrotate 配置文件，跳过（日志将不会自动轮转）"
fi
echo ""

echo "7⃣  配置定时扫描..."

# 检测 systemd 是否可用
SYSTEMD_AVAILABLE=false
if command -v systemctl &> /dev/null && [ -d /run/systemd/system ]; then
    SYSTEMD_AVAILABLE=true
fi

echo ""
echo "   选择扫描调度方式："
echo "     1) systemd timer（推荐，支持 journald 日志、服务状态监控）"
echo "     2) Cron（传统方式，兼容旧系统）"
echo ""

if [ "$SYSTEMD_AVAILABLE" = true ]; then
    read -p "   请选择 [1/2，默认: 1]: " scheduler_choice
else
    echo "   ℹ  未检测到 systemd，将使用 Cron 模式"
    scheduler_choice="2"
fi
scheduler_choice="${scheduler_choice:-1}"

case "$scheduler_choice" in
    1)
        if [ "$SYSTEMD_AVAILABLE" = false ]; then
            echo "   ℹ  systemd 不可用，降级为 Cron 模式"
            scheduler_choice=2
        else
            echo ""
            echo "   安装 systemd timer..."

            # 安装 service 文件
            if [ -f "$SCRIPT_DIR/fantastic-probe.service" ]; then
                cp "$SCRIPT_DIR/fantastic-probe.service" /etc/systemd/system/fantastic-probe.service
                echo "    ✓ service 已安装"
            else
                # 内联生成 service 文件
                cat > /etc/systemd/system/fantastic-probe.service <<'SERVICEOF'
[Unit]
Description=Fantastic-Probe ISO 媒体信息扫描服务
Documentation=https://github.com/qzov/fantastic-probe
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fantastic-probe-cron-scanner scan
StandardOutput=append:/var/log/fantastic_probe.log
StandardError=append:/var/log/fantastic_probe.log
SERVICEOF
                echo "    ✓ service 已生成"
            fi

            # 安装 timer 文件
            if [ -f "$SCRIPT_DIR/fantastic-probe.timer" ]; then
                cp "$SCRIPT_DIR/fantastic-probe.timer" /etc/systemd/system/fantastic-probe.timer
                echo "    ✓ timer 已安装"
            else
                cat > /etc/systemd/system/fantastic-probe.timer <<'TIMEREOF'
[Unit]
Description=Fantastic-Probe 扫描定时器（每分钟触发）
Requires=fantastic-probe.service

[Timer]
OnCalendar=*:0/1
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF
                echo "    ✓ timer 已生成"
            fi

            # 启动 timer
            systemctl daemon-reload
            systemctl enable fantastic-probe.timer --now
            echo "    ✓ systemd timer 已启动（每 1 分钟扫描一次）"
            echo ""

            # 清理旧的 cron 任务
            if [ -f "/etc/cron.d/fantastic-probe" ]; then
                rm -f /etc/cron.d/fantastic-probe
                echo "    ✓ 已清理旧的 Cron 任务"
            fi
        fi
        ;&  # fallthrough to cron only if systemd not available
    2)
        # Cron 模式
        CRON_FILE="/etc/cron.d/fantastic-probe"

        if [ -f "$CRON_FILE" ]; then
            echo "   ℹ  Cron 任务文件已存在，将覆盖"
            rm -f "$CRON_FILE"
        fi

        cat > "$CRON_FILE" <<'CRONEOF'

SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

*/1 * * * * root /usr/local/bin/fantastic-probe-cron-scanner scan >> /var/log/fantastic_probe.log 2>&1

0 * * * * root rm -f /tmp/fantastic_probe_cron_scanner.lock 2>/dev/null || true

0 2 * * * root /usr/local/bin/fantastic-probe-cron-scanner stats >> /var/log/fantastic_probe.log 2>&1
CRONEOF

        chmod 644 "$CRON_FILE"
        echo "    Cron 任务已配置: $CRON_FILE"
        echo "   ℹ  扫描间隔: 每 1 分钟"

        # 停止 systemd timer（如果存在）
        if [ -f "/etc/systemd/system/fantastic-probe.timer" ]; then
            systemctl disable fantastic-probe.timer --now 2>/dev/null || true
            echo "   ℹ  已停止旧的 systemd timer"
        fi
        ;;
    *)
        echo "   无效选择，使用 Cron 模式"
        scheduler_choice=2
        ;&  # fallthrough to cron
esac
echo ""

echo "8⃣  清理旧的 cron 任务..."
if crontab -l 2>/dev/null | grep -q "fantastic-probe"; then
    echo "   检测到旧的 cron 任务（用户级别），建议手动清理:"
    echo "   crontab -e"
    echo "   删除包含 'fantastic-probe' 的行"
else
    echo "    无旧的 cron 任务"
fi
echo ""

echo "=========================================="
echo " 安装完成！"
echo "=========================================="
echo ""

if [ -f "/etc/systemd/system/fantastic-probe.timer" ]; then
    echo "ℹ  Fantastic-Probe 使用 systemd timer 模式（每 1 分钟扫描一次）"
    echo ""
    echo " 常用命令:"
    echo ""
    echo "  查看服务状态:"
    echo "    systemctl status fantastic-probe.timer"
    echo ""
    echo "  查看日志:"
    echo "    journalctl -u fantastic-probe.service -f"
    echo ""
    echo "  手动触发扫描:"
    echo "    sudo systemctl start fantastic-probe.service"
elif [ -f "/etc/cron.d/fantastic-probe" ]; then
    echo "ℹ  Fantastic-Probe 使用 Cron 模式（每 1 分钟扫描一次）"
    echo ""
    echo " 常用命令:"
    echo ""
    echo "  查看 Cron 执行日志:"
echo "    tail -f /var/log/fantastic_probe.log"
echo ""
echo "  查看错误日志:"
echo "    tail -f /var/log/fantastic_probe_errors.log"
echo ""
echo "  查看失败文件列表:"
echo "    fp-config failure-list"
echo ""
echo "  清空失败缓存:"
echo "    fp-config failure-clear"
echo ""
echo "  重置单个文件的失败记录:"
echo "    fp-config failure-reset '/path/to/file.iso.strm'"
echo ""
