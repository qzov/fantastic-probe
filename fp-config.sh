#!/bin/bash
export LC_ALL=C.UTF-8

#==============================================================================
#==============================================================================

set -euo pipefail

#==============================================================================
#==============================================================================

TEMP_DIR=""

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

#==============================================================================
#==============================================================================

CONFIG_FILE="/etc/fantastic-probe/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATIC_DIR="/usr/share/fantastic-probe/static"  # 预编译包本地缓存路径
FFPROBE_SOURCE="BtbN/FFmpeg-Builds (GPL 构建，含 libbluray/libdvdread)"  # FFprobe 预编译包来源

#==============================================================================
#==============================================================================

load_process_library() {
    local lib_paths=(
        "/usr/local/lib/fantastic-probe-process-lib.sh"
        "$SCRIPT_DIR/fantastic-probe-process-lib.sh"
        "/usr/local/bin/fantastic-probe-process-lib.sh"
    )

    for lib_path in "${lib_paths[@]}"; do
        if [ -f "$lib_path" ]; then
            # shellcheck source=/dev/null
            source "$lib_path"

            # Load upload library after process library
            local upload_lib_paths=(
                "/usr/local/lib/fantastic-probe-upload-lib.sh"
                "$SCRIPT_DIR/fantastic-probe-upload-lib.sh"
                "/usr/local/bin/fantastic-probe-upload-lib.sh"
            )

            for upload_lib_path in "${upload_lib_paths[@]}"; do
                if [ -f "$upload_lib_path" ]; then
                    # shellcheck source=/dev/null
                    source "$upload_lib_path"
                    break
                fi
            done

            return 0
        fi
    done

    show_dependency_status() {
        echo " 依赖状态"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        local deps=(
            "python3:bd_list_titles 输出解析"
            "jq:JSON 处理"
            "sqlite3:失败记录数据库"
            "bd_list_titles:蓝光语言标签提取"
            "ffprobe:媒体信息提取"
        )

        for dep in "${deps[@]}"; do
            local cmd="${dep%%:*}"
            local desc="${dep#*:}"

            if command -v "$cmd" &> /dev/null; then
                echo "    $cmd - $desc"
            else
                echo "    $cmd - $desc (未安装)"
            fi
        done

        echo ""
    }

    return 0
}

load_process_library

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo " 错误: 此工具需要 root 权限"
        echo "   请使用: sudo fantastic-probe-config"
        exit 1
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        echo " 错误: 配置文件不存在: $CONFIG_FILE"
        echo "   请先安装 Fantastic-Probe"
        exit 1
    fi
}

validate_config() {
    local missing_keys=()

    local required_keys=(
        "EMBY_ENABLED"
        "EMBY_URL"
        "EMBY_API_KEY"
        "EMBY_NOTIFY_TIMEOUT"
    )

    for key in "${required_keys[@]}"; do
        if ! grep -q "^${key}=" "$CONFIG_FILE"; then
            missing_keys+=("$key")
        fi
    done

    if [ ${#missing_keys[@]} -gt 0 ]; then
        echo ""
        echo "  检测到缺失的配置项，正在自动修复..."

        for key in "${missing_keys[@]}"; do
            case "$key" in
                EMBY_ENABLED)
                    echo "EMBY_ENABLED=false" >> "$CONFIG_FILE"
                    ;;
                EMBY_URL)
                    echo "EMBY_URL=\"\"" >> "$CONFIG_FILE"
                    ;;
                EMBY_API_KEY)
                    echo "EMBY_API_KEY=\"\"" >> "$CONFIG_FILE"
                    ;;
                EMBY_NOTIFY_TIMEOUT)
                    echo "EMBY_NOTIFY_TIMEOUT=5" >> "$CONFIG_FILE"
                    ;;
            esac
            echo "    已添加: $key"
        done

        echo ""
        echo " 配置文件已修复，缺失的配置项已自动添加"

        source "$CONFIG_FILE"
    fi
}

show_current_config() {
    echo ""
    echo " 当前配置："
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   STRM 根目录: $STRM_ROOT"
    echo "   FFprobe 路径: $FFPROBE"
    echo "   日志文件: $LOG_FILE"
    echo "    FFprobe 超时: ${FFPROBE_TIMEOUT}秒"
    echo "    最大处理时间: ${MAX_FILE_PROCESSING_TIME}秒"
    echo "    防抖时间: ${DEBOUNCE_TIME}秒"
    echo ""
    echo "   Emby 集成:"
    echo "    启用状态: ${EMBY_ENABLED:-false}"
    echo "    Emby URL: ${EMBY_URL:-(未配置)}"
    echo "    API Key: ${EMBY_API_KEY:+(已配置)}"
    echo "    通知超时: ${EMBY_NOTIFY_TIMEOUT:-5}秒"
    echo ""
    echo "   目录上传:"
    echo "    启用状态: ${AUTO_UPLOAD_ENABLED:-false}"
    echo "    上传类型: ${UPLOAD_FILE_TYPES:-json}"
    echo "    批次间隔: ${UPLOAD_INTERVAL:-10}秒（目录之间）"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

restart_service() {
    echo ""
    echo " 重启服务（清理状态 + 重新启动）..."
    echo ""

    echo "    清理旧状态..."

    local killed_count=0
    for proc_name in "fantastic-probe-cron-scanner"; do
        while IFS= read -r pid; do
            if [ -n "$pid" ] && [ "$pid" != "$$" ]; then
                kill -9 "$pid" 2>/dev/null && killed_count=$((killed_count + 1))
            fi
        done < <(pgrep -f "$proc_name" 2>/dev/null || true)
    done
    [ $killed_count -gt 0 ] && echo "    已终止 $killed_count 个旧进程"

    rm -f /tmp/fantastic_probe_monitor.lock \
          /tmp/fantastic_probe_cron_scanner.lock \
          /tmp/fantastic-probe.lock \
          /var/lock/fantastic-probe.lock \
          /tmp/fantastic_probe_queue.fifo \
          /tmp/fantastic-probe-queue 2>/dev/null || true
    echo "    已清理锁文件和队列"

    if [ -f "/var/lib/fantastic-probe/failure_cache.db" ]; then
        rm -f "/var/lib/fantastic-probe/failure_cache.db"
        echo "    已清理失败缓存数据库"
    fi

    echo ""
    if [ -f "/etc/cron.d/fantastic-probe.disabled" ]; then
        echo "    重新启用 Cron 定时任务..."
        mv /etc/cron.d/fantastic-probe.disabled /etc/cron.d/fantastic-probe 2>/dev/null || true
        echo "    Cron 任务已启用，将在 1 分钟内开始运行"
    elif [ -f "/etc/cron.d/fantastic-probe" ]; then
        echo "    Cron 模式已运行，配置将在下次扫描时生效（最多 1 分钟）"
    else
        echo "     未检测到 Cron 任务配置"
        echo "   ℹ  配置文件已更新，请运行安装脚本配置 Cron 任务"
    fi

    echo ""
    echo "    重启完成！所有旧状态已清理"
    echo ""
}

update_config_line() {
    local key="$1"
    local value="$2"

    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

        if grep -q "^${key}=" "$CONFIG_FILE"; then
            sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CONFIG_FILE"
        else
            echo "${key}=\"${value}\"" >> "$CONFIG_FILE"
        fi

        rm -f "$CONFIG_FILE.bak"

        echo "    配置已更新: $key=\"$value\""
    else
        echo "    配置文件不存在"
        return 1
    fi
}

#==============================================================================
#==============================================================================

change_strm_root() {
    echo ""
    echo " 修改 STRM 根目录"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   当前目录: $STRM_ROOT"
    echo ""
    read -p "   请输入新的 STRM 根目录路径: " new_strm_root

    if [ -z "$new_strm_root" ]; then
        echo "     未输入路径，取消修改"
        return 1
    fi

    if [ ! -d "$new_strm_root" ]; then
        echo "     警告: 目录不存在: $new_strm_root"
        read -p "   是否创建该目录？[Y/n]: " create_dir
        create_dir="${create_dir:-Y}"

        if [[ "$create_dir" =~ ^[Yy]$ ]]; then
            mkdir -p "$new_strm_root"
            echo "    目录已创建"
        else
            echo "     目录不存在，配置可能无法正常工作"
        fi
    fi

    update_config_line "STRM_ROOT" "$new_strm_root"
    STRM_ROOT="$new_strm_root"

    read -p "   是否立即重启服务以应用配置？[Y/n]: " do_restart
    do_restart="${do_restart:-Y}"

    if [[ "$do_restart" =~ ^[Yy]$ ]]; then
        restart_service
    else
        echo "     配置已更新，但需要应用后才能生效"
        if [ -f "/etc/cron.d/fantastic-probe" ]; then
            echo "   ℹ  Cron 模式：配置将在下次扫描时自动应用（最多等待 1 分钟）"
        else
            echo "   手动重启: sudo fp-config restart"
        fi
    fi
}

reconfigure_ffprobe() {
    echo ""
    echo " 重新配置 FFprobe"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   当前路径: $FFPROBE"
    echo "   说明：ffprobe 用于提取蓝光/DVD 媒体信息"
    echo ""

    ARCH=$(uname -m)
    PREBUILT_AVAILABLE=false
    PREBUILT_SOURCE=""
    PREBUILT_URL=""
    ARCH_NAME=""
    EXTRACT_DIR_NAME=""

    # BtbN/FFmpeg-Builds GPL 构建（含 libbluray/libdvdread）
    FFPROBE_DL_BASE="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest"

    if [ "$ARCH" = "x86_64" ]; then
        ARCH_NAME="x86_64"
        EXTRACT_DIR_NAME="ffmpeg-master-latest-linux64-gpl"
        if [ -f "$STATIC_DIR/ffmpeg-master-latest-linux64-gpl.tar.xz" ]; then
            PREBUILT_AVAILABLE=true
            PREBUILT_SOURCE="$STATIC_DIR/ffmpeg-master-latest-linux64-gpl.tar.xz"
        fi
        PREBUILT_URL="${FFPROBE_DL_BASE}/ffmpeg-master-latest-linux64-gpl.tar.xz"
    elif [ "$ARCH" = "aarch64" ]; then
        ARCH_NAME="ARM64"
        EXTRACT_DIR_NAME="ffmpeg-master-latest-linuxarm64-gpl"
        if [ -f "$STATIC_DIR/ffmpeg-master-latest-linuxarm64-gpl.tar.xz" ]; then
            PREBUILT_AVAILABLE=true
            PREBUILT_SOURCE="$STATIC_DIR/ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
        fi
        PREBUILT_URL="${FFPROBE_DL_BASE}/ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
    fi

    local new_ffprobe=""

    if [ "$PREBUILT_AVAILABLE" = true ]; then
        echo "    检测到架构: $ARCH_NAME"
        echo "    找到本地缓存的预编译 ffprobe (BtbN GPL 构建)"
        echo ""
        read -p "   是否使用本地缓存的 ffprobe？[Y/n]: " auto_install
        auto_install="${auto_install:-Y}"

        if [[ "$auto_install" =~ ^[Yy]$ ]]; then
            echo ""

            TEMP_DIR="/tmp/ffprobe-config-$$"
            mkdir -p "$TEMP_DIR"

            echo "    使用本地缓存..."
            PREBUILT_ARCHIVE="$PREBUILT_SOURCE"

            echo "    正在安装..."
            if tar -xf "$PREBUILT_ARCHIVE" -C "$TEMP_DIR" 2>/dev/null; then
                if [ -f "$TEMP_DIR/$EXTRACT_DIR_NAME/bin/ffprobe" ]; then
                    cp "$TEMP_DIR/$EXTRACT_DIR_NAME/bin/ffprobe" /usr/local/bin/ffprobe
                    chmod +x /usr/local/bin/ffprobe
                    new_ffprobe="/usr/local/bin/ffprobe"

                    if /usr/local/bin/ffprobe -version &> /dev/null; then
                        echo "    ffprobe 已安装到: /usr/local/bin/ffprobe"
                        echo "    安装成功！"
                    else
                        echo "    安装失败: ffprobe 无法执行（可能缺少运行时库）"
                        new_ffprobe=""
                    fi
                else
                    echo "    错误: 解压后未找到 ffprobe (路径: $TEMP_DIR/$EXTRACT_DIR_NAME/bin/ffprobe)"
                    new_ffprobe=""
                fi
            else
                echo "    解压失败"
                new_ffprobe=""
            fi

            rm -rf "$TEMP_DIR"
        else
            echo "   ℹ  跳过本地缓存，进入其他配置选项..."
        fi

    elif [ -n "$PREBUILT_URL" ]; then
        echo "    检测到架构: $ARCH_NAME"
        echo "   ℹ  本地缓存不存在，可从 BtbN/FFmpeg-Builds 下载预编译 ffprobe"
        echo "      来源: $FFPROBE_SOURCE"
        echo ""
        read -p "   是否下载并安装预编译 ffprobe？[Y/n]: " download_choice
        download_choice="${download_choice:-Y}"

        if [[ "$download_choice" =~ ^[Yy]$ ]]; then
            echo ""
            echo "    正在下载预编译 ffprobe..."
            echo "    下载地址: $PREBUILT_URL"

            TEMP_DIR="/tmp/ffprobe-config-$$"
            mkdir -p "$TEMP_DIR"
            mkdir -p "$STATIC_DIR"

            DOWNLOAD_SUCCESS=false
            if command -v curl &> /dev/null; then
                if curl -fL "$PREBUILT_URL" -o "$TEMP_DIR/ffprobe.tar.xz" --progress-bar; then
                    DOWNLOAD_SUCCESS=true
                    echo "    下载完成"
                else
                    echo "    下载失败（网络错误或 GitHub 不可达）"
                fi
            elif command -v wget &> /dev/null; then
                if wget --show-progress "$PREBUILT_URL" -O "$TEMP_DIR/ffprobe.tar.xz" 2>&1; then
                    DOWNLOAD_SUCCESS=true
                    echo "    下载完成"
                else
                    echo "    下载失败（网络错误或 GitHub 不可达）"
                fi
            else
                echo "    错误: 需要 curl 或 wget"
            fi

            if [ "$DOWNLOAD_SUCCESS" = true ] && [ -f "$TEMP_DIR/ffprobe.tar.xz" ]; then
                echo "    正在安装..."

                if tar -xf "$TEMP_DIR/ffprobe.tar.xz" -C "$TEMP_DIR" 2>/dev/null; then
                    if [ -f "$TEMP_DIR/$EXTRACT_DIR_NAME/bin/ffprobe" ]; then
                        cp "$TEMP_DIR/$EXTRACT_DIR_NAME/bin/ffprobe" /usr/local/bin/ffprobe
                        chmod +x /usr/local/bin/ffprobe
                        new_ffprobe="/usr/local/bin/ffprobe"

                        if /usr/local/bin/ffprobe -version &> /dev/null; then
                            echo "    ffprobe 已安装到: /usr/local/bin/ffprobe"
                            echo "    安装成功！"

                            # 缓存预编译包
                            cp "$TEMP_DIR/ffprobe.tar.xz" "$STATIC_DIR/${EXTRACT_DIR_NAME}.tar.xz"
                            echo "   ℹ  已保存到本地缓存: $STATIC_DIR/${EXTRACT_DIR_NAME}.tar.xz"
                        else
                            echo "    安装失败: ffprobe 无法执行（可能缺少运行时库）"
                            new_ffprobe=""
                        fi
                    else
                        echo "    错误: 解压后未找到 ffprobe"
                        new_ffprobe=""
                    fi
                else
                    echo "    解压失败（文件可能损坏）"
                    new_ffprobe=""
                fi
            fi

            rm -rf "$TEMP_DIR"

            if [ -z "$new_ffprobe" ]; then
                echo "   ℹ  下载失败，进入手动配置..."
            fi
        else
            echo "   ℹ  跳过下载，进入手动配置..."
        fi
    fi

    if [ -z "$new_ffprobe" ]; then
        echo ""
        echo "    手动配置 FFprobe"
        echo ""
        echo "   选项："
        echo "     1) 使用系统已安装的 ffprobe（需先安装 ffmpeg）"
        echo "     2) 手动指定 ffprobe 路径"
        echo "     3) 保持原配置不变"
        echo ""
        read -p "   请选择 [1/2/3，默认: 1]: " manual_choice
        manual_choice="${manual_choice:-1}"

        case "$manual_choice" in
            1)
                if command -v ffprobe &> /dev/null; then
                    detected_ffprobe=$(command -v ffprobe)
                    echo "    检测到: $detected_ffprobe"
                    new_ffprobe="$detected_ffprobe"
                else
                    echo "    系统中未检测到 ffprobe"
                    echo ""
                    echo "   请先安装 ffmpeg："
                    echo "      Debian/Ubuntu: apt-get install -y ffmpeg"
                    echo "      RHEL/CentOS:   dnf install -y ffmpeg"
                    echo "      Arch Linux:    pacman -S ffmpeg"
                    echo ""
                    read -p "   现在安装 ffmpeg？[y/N]: " install_now

                    if [[ "$install_now" =~ ^[Yy]$ ]]; then
                        apt-get update && apt-get install -y ffmpeg
                        if command -v ffprobe &> /dev/null; then
                            new_ffprobe=$(command -v ffprobe)
                            echo "    ffmpeg 安装成功: $new_ffprobe"
                        else
                            echo "    安装失败，保持原配置"
                            new_ffprobe="$FFPROBE"
                        fi
                    else
                        echo "   ℹ  保持原配置: $FFPROBE"
                        new_ffprobe="$FFPROBE"
                    fi
                fi
                ;;
            2)
                echo ""
                read -p "   请输入 ffprobe 完整路径: " new_ffprobe

                if [ -z "$new_ffprobe" ]; then
                    echo "     路径为空，保持原配置: $FFPROBE"
                    new_ffprobe="$FFPROBE"
                fi
                ;;
            3)
                echo "   ℹ  保持原配置: $FFPROBE"
                new_ffprobe="$FFPROBE"
                ;;
            *)
                echo "     无效选择，保持原配置: $FFPROBE"
                new_ffprobe="$FFPROBE"
                ;;
        esac
    fi

    if [ -n "$new_ffprobe" ]; then
        update_config_line "FFPROBE" "$new_ffprobe"
        FFPROBE="$new_ffprobe"
        echo ""
        echo "    FFprobe 路径已更新: $new_ffprobe"

        if [ ! -x "$new_ffprobe" ]; then
            echo ""
            echo "     警告: ffprobe 不存在或不可执行: $new_ffprobe"
            echo "     服务可能无法正常启动！"
            echo ""
            echo "   请执行以下操作之一："
            echo "     1) 安装 ffmpeg: apt-get install -y ffmpeg"
            echo "     2) 重新配置: fp-config ffprobe"
            echo "     3) 手动编辑: /etc/fantastic-probe/config"
        fi
    else
        echo "    错误: 无法确定 ffprobe 路径"
        return 1
    fi

    echo ""
    read -p "   是否立即重启服务以应用配置？[Y/n]: " do_restart
    do_restart="${do_restart:-Y}"

    if [[ "$do_restart" =~ ^[Yy]$ ]]; then
        restart_service
    else
        echo "     配置已更新，但需要应用后才能生效"
        if [ -f "/etc/cron.d/fantastic-probe" ]; then
            echo "   ℹ  Cron 模式：配置将在下次扫描时自动应用（最多等待 1 分钟）"
        else
            echo "   手动重启: sudo fp-config restart"
        fi
    fi
}

configure_emby() {
    echo ""
    echo " 配置 Emby 媒体库集成"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   说明："
    echo "   • 启用后，每次生成媒体信息 JSON 文件时自动通知 Emby 刷新媒体库"
    echo "   • 需要提供 Emby 服务器地址和 API 密钥"
    echo "   • API 密钥可在 Emby 控制台 → 高级 → 安全 中生成"
    echo ""
    echo "   当前状态："
    echo "     启用: ${EMBY_ENABLED:-false}"
    echo "     URL: ${EMBY_URL:-(未配置)}"
    echo "     API Key: ${EMBY_API_KEY:+(已配置)}"
    echo ""

    local current_enabled="${EMBY_ENABLED:-false}"
    local enable_prompt="Y/n"
    if [ "$current_enabled" = "true" ]; then
        enable_prompt="Y/n"
    else
        enable_prompt="y/N"
    fi

    read -p "   是否启用 Emby 集成？[$enable_prompt]: " enable_emby

    if [ "$current_enabled" = "true" ]; then
        enable_emby="${enable_emby:-Y}"
    else
        enable_emby="${enable_emby:-N}"
    fi

    if [[ "$enable_emby" =~ ^[Yy]$ ]]; then
        echo ""
        echo "   配置 Emby 连接信息："
        echo ""

        echo "    Emby 服务器地址"
        echo "      示例: http://127.0.0.1:8096 或 http://192.168.1.100:8096"
        read -p "      请输入 Emby URL [默认: ${EMBY_URL:-http://127.0.0.1:8096}]: " new_emby_url
        new_emby_url="${new_emby_url:-${EMBY_URL:-http://127.0.0.1:8096}}"

        new_emby_url="${new_emby_url%/}"

        echo ""
        echo "    API 密钥"
        echo "      获取方式: Emby 控制台 → 高级 → 安全 → API 密钥"
        if [ -n "${EMBY_API_KEY:-}" ]; then
            read -p "      请输入 API Key [留空保持当前]: " new_api_key
            new_api_key="${new_api_key:-$EMBY_API_KEY}"
        else
            read -p "      请输入 API Key: " new_api_key
        fi

        if [ -z "$new_api_key" ]; then
            echo ""
            echo "    API Key 不能为空"
            echo "   ℹ  操作已取消"
            return 1
        fi

        echo ""
        read -p "   是否测试 Emby 连接？[Y/n]: " test_connection
        test_connection="${test_connection:-Y}"

        if [[ "$test_connection" =~ ^[Yy]$ ]]; then
            echo "   正在测试连接..."

            if command -v curl &> /dev/null; then
                local test_response
                test_response=$(curl -s -w "\n%{http_code}" --max-time 5 \
                    -X GET "${new_emby_url}/System/Info" \
                    -H "X-Emby-Token: ${new_api_key}" 2>&1)

                local test_http_code=$(echo "$test_response" | tail -1)

                if [ "$test_http_code" = "200" ]; then
                    echo "    连接成功！"

                    local server_name=$(echo "$test_response" | head -n -1 | grep -o '"ServerName":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
                    if [ -n "$server_name" ]; then
                        echo "   ℹ  服务器名称: $server_name"
                    fi
                else
                    echo "     连接失败（HTTP $test_http_code）"
                    echo "   ℹ  请检查 URL 和 API Key 是否正确"
                    read -p "   是否仍要保存配置？[y/N]: " save_anyway
                    save_anyway="${save_anyway:-N}"

                    if [[ ! "$save_anyway" =~ ^[Yy]$ ]]; then
                        echo "   ℹ  操作已取消"
                        return 1
                    fi
                fi
            else
                echo "     curl 命令不可用，跳过连接测试"
            fi
        fi

        echo ""
        update_config_line "EMBY_ENABLED" "true"
        update_config_line "EMBY_URL" "$new_emby_url"
        update_config_line "EMBY_API_KEY" "$new_api_key"

        EMBY_ENABLED="true"
        EMBY_URL="$new_emby_url"
        EMBY_API_KEY="$new_api_key"

        echo "    Emby 集成已启用"
    else
        update_config_line "EMBY_ENABLED" "false"
        EMBY_ENABLED="false"
        echo "    Emby 集成已禁用"
    fi

    echo ""
    read -p "   是否立即重启服务以应用配置？[Y/n]: " do_restart
    do_restart="${do_restart:-Y}"

    if [[ "$do_restart" =~ ^[Yy]$ ]]; then
        restart_service
    else
        echo "     配置已更新，但需要应用后才能生效"
        if [ -f "/etc/cron.d/fantastic-probe" ]; then
            echo "   ℹ  Cron 模式：配置将在下次扫描时自动应用（最多等待 1 分钟）"
        else
            echo "   手动重启: sudo fp-config restart"
        fi
    fi
}

configure_upload() {
    echo ""
    echo " 配置目录上传到网络存储"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   说明："
    echo "   • 启用后，生成媒体信息文件时按目录上传到网络存储"
    echo "   • 支持多种文件类型：JSON、NFO、字幕、图片"
    echo "   • 同一目录文件连续上传，目录之间批次间隔"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "   当前状态："
    echo "     启用: ${AUTO_UPLOAD_ENABLED:-false}"
    echo "     上传类型: ${UPLOAD_FILE_TYPES:-json}"
    echo "     上传间隔: ${UPLOAD_INTERVAL:-10}秒"
    echo ""

    local current_enabled="${AUTO_UPLOAD_ENABLED:-false}"
    local enable_prompt
    if [ "$current_enabled" = "true" ]; then
        enable_prompt="Y/n"
    else
        enable_prompt="y/N"
    fi

    read -p "   是否启用目录上传？[$enable_prompt]: " enable_upload

    if [ "$current_enabled" = "true" ]; then
        enable_upload="${enable_upload:-Y}"
    else
        enable_upload="${enable_upload:-N}"
    fi

    if [[ "$enable_upload" =~ ^[Yy]$ ]]; then
        echo ""
        echo "   配置上传参数："
        echo ""

        echo "    上传文件类型"
        echo "      支持的类型: json, nfo, srt, ass, ssa, png, jpg"
        echo "      默认: json（仅上传媒体信息 JSON 文件）"
        echo "      示例: json,nfo,srt,ass,png（上传 JSON、NFO、字幕和图片）"
        read -p "      请输入上传类型 [默认: ${UPLOAD_FILE_TYPES:-json}]: " new_upload_types
        new_upload_types="${new_upload_types:-${UPLOAD_FILE_TYPES:-json}}"

        echo ""
        echo "     上传间隔（秒）"
        echo "      说明: 批次间隔（目录之间的等待时间，同一目录内连续上传）"
        echo "      推荐: 10 秒（批次间隔，风控保护）"
        read -p "      请输入上传间隔 [默认: ${UPLOAD_INTERVAL:-10}]: " new_upload_interval
        new_upload_interval="${new_upload_interval:-${UPLOAD_INTERVAL:-10}}"

        update_config_line "AUTO_UPLOAD_ENABLED" "true"
        update_config_line "UPLOAD_FILE_TYPES" "\"$new_upload_types\""
        update_config_line "UPLOAD_INTERVAL" "$new_upload_interval"

        AUTO_UPLOAD_ENABLED="true"
        UPLOAD_FILE_TYPES="$new_upload_types"
        UPLOAD_INTERVAL="$new_upload_interval"

        echo ""
        echo "    目录上传已启用"
        echo "      上传类型: $new_upload_types"
        echo "      批次间隔: ${new_upload_interval}秒"
    else
        update_config_line "AUTO_UPLOAD_ENABLED" "false"
        AUTO_UPLOAD_ENABLED="false"
        echo "    目录上传已禁用"
    fi

    echo ""
    read -p "   是否立即重启服务以应用配置？[Y/n]: " do_restart
    do_restart="${do_restart:-Y}"

    if [[ "$do_restart" =~ ^[Yy]$ ]]; then
        restart_service
    else
        echo "     配置已更新，但需要应用后才能生效"
        if [ -f "/etc/cron.d/fantastic-probe" ]; then
            echo "   ℹ  Cron 模式：配置将在下次扫描时自动应用（最多等待 1 分钟）"
        else
            echo "   手动重启: sudo fp-config restart"
        fi
    fi
}

edit_config_file() {
    echo ""
    echo " 编辑配置文件"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   配置文件: $CONFIG_FILE"
    echo ""

    EDITOR="${EDITOR:-nano}"

    if ! command -v "$EDITOR" &> /dev/null; then
        EDITOR="vi"
    fi

    echo "   使用编辑器: $EDITOR"
    echo "     警告: 请确保配置语法正确（KEY=\"VALUE\" 格式）"
    echo ""
    read -p "   按 Enter 继续，或 Ctrl+C 取消..."

    "$EDITOR" "$CONFIG_FILE"

    echo ""
    echo "    编辑完成"

    read -p "   是否立即重启服务以应用配置？[Y/n]: " do_restart
    do_restart="${do_restart:-Y}"

    if [[ "$do_restart" =~ ^[Yy]$ ]]; then
        restart_service
    else
        echo "     配置已修改，但需要应用后才能生效"
        if [ -f "/etc/cron.d/fantastic-probe" ]; then
            echo "   ℹ  Cron 模式：配置将在下次扫描时自动应用（最多等待 1 分钟）"
        else
            echo "   手动重启: sudo fp-config restart"
        fi
    fi
}

#==============================================================================
#==============================================================================

show_service_status() {
    echo ""
    echo " 服务状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ -f "/etc/cron.d/fantastic-probe" ]; then
        echo "   ℹ  运行模式: Cron 定时任务"
        echo ""
        echo "    Cron 配置:"
        echo "   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        cat /etc/cron.d/fantastic-probe | grep -v '^#' | grep -v '^$' || echo "   无有效配置"
        echo ""
        echo "    最近运行日志（最后 10 行）:"
        echo "   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ -f "/var/log/fantastic_probe.log" ]; then
            tail -10 /var/log/fantastic_probe.log | sed 's/^/   /'
        else
            echo "     日志文件不存在"
        fi
        echo ""
        echo "    提示:"
        echo "      • 查看实时日志: tail -f /var/log/fantastic_probe.log"
        echo "      • 查看错误日志: fp-config logs-error"
        echo "      • Cron 任务每 1 分钟自动执行一次"
    else
        echo "     未检测到 Cron 任务配置"
        echo "   请运行安装脚本配置 Cron 任务"
    fi

    echo ""
}

start_service() {
    echo ""
    echo "▶  启动服务..."

    if [ -f "/etc/cron.d/fantastic-probe" ]; then
        echo "   ℹ  Cron 模式: 任务已自动启用"
        echo "    Cron 任务配置: /etc/cron.d/fantastic-probe"
        echo "   ℹ  任务将每 1 分钟自动执行，无需手动启动"
        echo ""
        echo "    提示: 查看实时日志 tail -f /var/log/fantastic_probe.log"
    else
        echo "    未检测到 Cron 任务文件"
        echo "   请重新运行安装脚本"
        return 1
    fi

    echo ""
}

stop_service() {
    echo ""
    echo "  停止服务并清理状态..."
    echo ""

    if [ -f "/etc/cron.d/fantastic-probe" ]; then
        echo "    禁用 Cron 定时任务..."
        mv /etc/cron.d/fantastic-probe /etc/cron.d/fantastic-probe.disabled 2>/dev/null || true
        echo "    Cron 任务已禁用"
    else
        echo "   ℹ  未检测到 Cron 任务文件"
    fi

    echo "    终止所有相关进程..."
    local killed_count=0

    for proc_name in "fantastic-probe-cron-scanner"; do
        while IFS= read -r pid; do
            if [ -n "$pid" ] && [ "$pid" != "$$" ]; then
                kill -9 "$pid" 2>/dev/null && killed_count=$((killed_count + 1))
            fi
        done < <(pgrep -f "$proc_name" 2>/dev/null || true)
    done

    if [ $killed_count -gt 0 ]; then
        echo "    已终止 $killed_count 个进程"
    else
        echo "   ℹ  没有运行中的进程"
    fi

    echo "    清理锁文件..."
    local lock_files=(
        "/tmp/fantastic_probe_monitor.lock"
        "/tmp/fantastic_probe_cron_scanner.lock"
        "/tmp/fantastic-probe.lock"
        "/var/lock/fantastic-probe.lock"
    )
    local cleaned_locks=0
    for lock_file in "${lock_files[@]}"; do
        if [ -f "$lock_file" ] || [ -L "$lock_file" ]; then
            rm -f "$lock_file" 2>/dev/null && cleaned_locks=$((cleaned_locks + 1))
        fi
    done
    if [ $cleaned_locks -gt 0 ]; then
        echo "    已清理 $cleaned_locks 个锁文件"
    else
        echo "   ℹ  没有残留的锁文件"
    fi

    echo "     清理队列文件..."
    local queue_files=(
        "/tmp/fantastic_probe_queue.fifo"
        "/tmp/fantastic-probe-queue"
    )
    local cleaned_queues=0
    for queue_file in "${queue_files[@]}"; do
        if [ -p "$queue_file" ] || [ -f "$queue_file" ]; then
            rm -f "$queue_file" 2>/dev/null && cleaned_queues=$((cleaned_queues + 1))
        fi
    done
    if [ $cleaned_queues -gt 0 ]; then
        echo "    已清理 $cleaned_queues 个队列文件"
    else
        echo "   ℹ  没有残留的队列文件"
    fi

    echo ""
    read -p "   是否清理失败记录数据库？[y/N]: " clean_db
    if [[ "$clean_db" =~ ^[Yy]$ ]]; then
        if [ -f "/var/lib/fantastic-probe/failure_cache.db" ]; then
            rm -f "/var/lib/fantastic-probe/failure_cache.db"
            echo "    失败记录已清理"
        else
            echo "   ℹ  没有失败记录"
        fi
    fi

    echo ""
    echo "    服务已完全停止，所有状态已清理"
    echo "   ℹ  重新启用: 使用 'sudo fp-config restart'"
    echo ""
}

#==============================================================================
#==============================================================================

check_updates() {
    echo ""
    echo " 检查更新"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "   正在检查 GitHub 仓库..."

    LOCAL_VERSION=""

    if [ -f "/usr/local/bin/get-version.sh" ]; then
        LOCAL_VERSION=$(bash /usr/local/bin/get-version.sh --version 2>/dev/null || echo "")
    fi

    if [ -z "$LOCAL_VERSION" ]; then
        LOCAL_VERSION="unknown"
    fi

    echo "   本地版本: $LOCAL_VERSION"
    echo ""

    REMOTE_VERSION=$(curl -fsSL "https://api.github.com/repos/qzov/fantastic-probe/releases" 2>/dev/null | \
        grep -E '"tag_name":|"draft":|"prerelease":' | \
        paste -d ' ' - - - | \
        grep '"draft": false' | \
        grep '"prerelease": false' | \
        grep -v 'ffprobe' | \
        head -1 | \
        sed -E 's/.*"tag_name": "v?([^"]+)".*/\1/' || echo "")

    if [ -z "$REMOTE_VERSION" ]; then
        echo "   ℹ  仓库中暂无正式版本 Release"
        echo "   正在从主分支获取版本信息..."
        REMOTE_VERSION=$(curl -fsSL "https://raw.githubusercontent.com/qzov/fantastic-probe/main/get-version.sh" 2>/dev/null | \
            grep '^VERSION=' | head -1 | cut -d'"' -f2 || echo "")

        if [ -z "$REMOTE_VERSION" ]; then
            echo "    无法获取远程版本信息"
            echo "   请检查网络连接或访问: https://github.com/qzov/fantastic-probe"
            echo ""
            return 1
        fi
        echo "   主分支版本: $REMOTE_VERSION"
    fi

    echo "   最新版本: $REMOTE_VERSION"
    echo ""

    if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
        echo "    已是最新版本"
    else
        echo "    发现新版本: $LOCAL_VERSION → $REMOTE_VERSION"
        echo ""
        read -p "   是否立即安装更新？[y/N]: " install_now
        if [[ "$install_now" =~ ^[Yy]$ ]]; then
            install_updates
        fi
    fi
    echo ""
}

install_updates() {
    echo ""
    echo " 安装更新"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "     注意："
    echo "      1. 更新过程中服务将暂时停止"
    echo "      2. 配置文件将保留"
    echo "      3. 建议在任务队列空闲时更新"
    echo ""
    read -p "   确认继续？[y/N]: " confirm
    confirm="${confirm:-N}"

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "   ℹ  操作已取消"
        echo ""
        return 1
    fi

    echo ""
    echo "     停止 Cron 任务..."
    if [ -f "/etc/cron.d/fantastic-probe" ]; then
        mv /etc/cron.d/fantastic-probe /etc/cron.d/fantastic-probe.disabled 2>/dev/null || true
        echo "    Cron 任务已暂停"
    fi

    echo ""
    echo "    下载更新..."
    TEMP_DIR="/tmp/fantastic-probe-update-$$"
    mkdir -p "$TEMP_DIR"

    if curl -fsSL "https://raw.githubusercontent.com/qzov/fantastic-probe/main/install.sh" -o "$TEMP_DIR/install.sh"; then
        echo "    下载完成"
        echo ""
        echo "    正在安装..."
        echo ""

        bash "$TEMP_DIR/install.sh"

        rm -rf "$TEMP_DIR"

        echo ""
        echo "    更新完成！"
        echo ""

        echo "    应用配置..."

        if [ -f "/etc/cron.d/fantastic-probe.disabled" ]; then
            mv /etc/cron.d/fantastic-probe.disabled /etc/cron.d/fantastic-probe 2>/dev/null || true
            echo "    Cron 任务已重新启用"
            echo "   ℹ  任务将在下次扫描时自动应用（最多等待 1 分钟）"
            echo ""
            echo "   查看运行日志: tail -f /var/log/fantastic_probe.log"
        else
            echo "     未检测到 Cron 任务配置，请手动检查"
        fi
    else
        echo "    下载失败"
        echo "   请检查网络连接或手动更新"
        rm -rf "$TEMP_DIR"

        echo ""
        echo "    尝试恢复 Cron 任务..."

        if [ -f "/etc/cron.d/fantastic-probe.disabled" ]; then
            mv /etc/cron.d/fantastic-probe.disabled /etc/cron.d/fantastic-probe 2>/dev/null || true
            echo "    Cron 任务已恢复"
        else
            echo "   ℹ  Cron 任务仍在运行，无需恢复"
        fi

        return 1
    fi
    echo ""
}

uninstall_service() {
    echo ""
    echo "  卸载 Fantastic-Probe"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "     警告："
    echo "      此操作将完全卸载 Fantastic-Probe 服务"
    echo "      包括服务、脚本和系统配置"
    echo ""
    echo "   可选择保留："
    echo "      - 配置文件 (/etc/fantastic-probe/)"
    echo "      - 日志文件 (/var/log/fantastic_probe*.log)"
    echo "      - 生成的 JSON 文件 (*.iso-mediainfo.json)"
    echo ""
    read -p "   确认卸载？请输入 YES 确认: " confirm

    if [ "$confirm" != "YES" ]; then
        echo "   ℹ  操作已取消"
        echo ""
        return 1
    fi

    echo ""
    echo "    开始卸载..."
    echo ""

    echo "   1⃣  停止服务和进程..."

    if [ -f "/etc/cron.d/fantastic-probe" ]; then
        mv /etc/cron.d/fantastic-probe /etc/cron.d/fantastic-probe.disabled 2>/dev/null || true
        echo "       Cron 任务已禁用"
    fi

    local killed_count=0
    for proc_name in "fantastic-probe-cron-scanner"; do
        while IFS= read -r pid; do
            if [ -n "$pid" ] && [ "$pid" != "$$" ]; then
                kill -9 "$pid" 2>/dev/null && killed_count=$((killed_count + 1))
            fi
        done < <(pgrep -f "$proc_name" 2>/dev/null || true)
    done

    if [ $killed_count -gt 0 ]; then
        echo "       已终止 $killed_count 个进程"
    else
        echo "       无运行中的进程"
    fi

    echo "   2⃣  删除 Cron 任务文件..."
    if [ -f "/etc/cron.d/fantastic-probe" ]; then
        rm -f /etc/cron.d/fantastic-probe
        echo "       Cron 任务文件已删除"
    elif [ -f "/etc/cron.d/fantastic-probe.disabled" ]; then
        rm -f /etc/cron.d/fantastic-probe.disabled
        echo "       Cron 任务文件已删除"
    else
        echo "       Cron 任务文件不存在"
    fi

    echo "   3⃣  删除脚本和工具..."
    rm -f /usr/local/bin/fantastic-probe-cron-scanner
    rm -f /usr/local/lib/fantastic-probe-process-lib.sh
    rm -f /usr/local/bin/fantastic-probe-auto-update
    rm -f /usr/local/bin/fp-config
    rm -f /usr/local/bin/fantastic-probe-config
    rm -f /usr/local/bin/get-version.sh
    echo "       所有脚本已删除"

    if [ -d "/usr/share/fantastic-probe" ]; then
        rm -rf /usr/share/fantastic-probe
        echo "       预编译包已删除"
    fi

    echo "   4⃣  清理临时文件和锁文件..."
    rm -f /tmp/fantastic_probe_monitor.lock
    rm -f /tmp/fantastic_probe_cron_scanner.lock
    rm -f /tmp/fantastic_probe_queue.fifo
    rm -f /tmp/fantastic-probe.lock
    rm -f /var/lock/fantastic-probe.lock
    rm -f /tmp/fantastic-probe-update-marker
    rm -f /tmp/fantastic-probe-auto-update.lock
    rm -rf /tmp/fantastic-probe-install-* 2>/dev/null || true
    echo "       临时文件已清理"

    echo ""
    echo "   5⃣  失败缓存数据库处理..."
    if [ -f "/var/lib/fantastic-probe/failure_cache.db" ]; then
        read -p "      是否删除失败缓存数据库？[Y/n]: " delete_cache
        delete_cache="${delete_cache:-Y}"

        if [[ "$delete_cache" =~ ^[Yy]$ ]]; then
            rm -f /var/lib/fantastic-probe/failure_cache.db
            rmdir /var/lib/fantastic-probe 2>/dev/null || true
            echo "       失败缓存数据库已删除"
        else
            echo "      ℹ  失败缓存数据库保留在: /var/lib/fantastic-probe/failure_cache.db"
        fi
    else
        echo "       失败缓存数据库不存在"
        rmdir /var/lib/fantastic-probe 2>/dev/null || true
    fi

    echo ""
    echo "   6⃣  清理 logrotate 配置..."
    if [ -f "/etc/logrotate.d/fantastic-probe" ]; then
        rm -f /etc/logrotate.d/fantastic-probe
        echo "       logrotate 配置已删除"
    else
        echo "       logrotate 配置不存在"
    fi

    echo ""
    echo "   7⃣  配置文件处理..."
    if [ -d "/etc/fantastic-probe" ]; then
        read -p "      是否删除配置文件？[y/N]: " delete_config
        if [[ "$delete_config" =~ ^[Yy]$ ]]; then
            rm -rf /etc/fantastic-probe
            echo "       配置目录已删除"
        else
            echo "      ℹ  配置文件保留在: /etc/fantastic-probe/"
        fi
    else
        echo "       配置目录不存在"
    fi

    echo ""
    echo "   8⃣  日志文件处理..."
    read -p "      是否删除日志文件？[y/N]: " delete_logs
    if [[ "$delete_logs" =~ ^[Yy]$ ]]; then
        rm -f /var/log/fantastic_probe.log
        rm -f /var/log/fantastic_probe_errors.log
        echo "       日志文件已删除"
    else
        echo "      ℹ  日志文件保留"
    fi

    echo ""
    echo "   9⃣  生成的 JSON 文件处理..."
    echo "      ℹ  JSON 文件已被保留（包含宝贵的媒体信息扫描结果）"
    echo "      ℹ  如需手动清理，请运行："
    echo "         find <STRM_ROOT> -type f -name '*-mediainfo.json' -delete"

    #
    #
    # if [[ "$delete_json" =~ ^[Yy]$ ]] && [ -d "$STRM_ROOT" ]; then
    #     JSON_COUNT=$(find "$STRM_ROOT" -type f -name "*.iso-mediainfo.json" 2>/dev/null | wc -l)
    #     if [ "$JSON_COUNT" -gt 0 ]; then
    #         find "$STRM_ROOT" -type f -name "*.iso-mediainfo.json" -delete
    #     else
    #     fi
    # else
    # fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "    Fantastic-Probe 卸载完成！"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    exit 0
}

#==============================================================================
#==============================================================================

bulk_upload_json() {
    echo ""
    echo " 目录上传"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if ! command -v upload_all_pending &> /dev/null; then
        echo "    上传库未加载，无法执行目录上传"
        echo "   请确保 fantastic-probe-upload-lib.sh 存在且已正确安装"
        echo ""
        return 1
    fi

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi

    local strm_root="${STRM_ROOT:-/mnt/sata1/media/媒体库/strm}"

    echo "   扫描目录: $strm_root"
    echo ""
    read -p "   确认开始目录上传？[Y/n]: " confirm
    confirm="${confirm:-Y}"

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "   ℹ  操作已取消"
        echo ""
        return 0
    fi

    echo ""
    echo "    开始目录上传..."
    echo ""

    upload_all_pending "$strm_root"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "    目录上传完成"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

retry_failed_uploads_menu() {
    echo ""
    echo " 重试失败上传"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if ! command -v retry_failed_uploads &> /dev/null; then
        echo "    上传库未加载，无法执行重试操作"
        echo "   请确保 fantastic-probe-upload-lib.sh 存在且已正确安装"
        echo ""
        return 1
    fi

    local upload_db="${UPLOAD_CACHE_DB:-/var/lib/fantastic-probe/upload_cache.db}"

    if [ ! -f "$upload_db" ]; then
        echo "   ℹ  上传数据库不存在，无失败记录"
        echo ""
        return 0
    fi

    local failed_count
    failed_count=$(sqlite3 "$upload_db" \
        "SELECT COUNT(*) FROM upload_cache WHERE status='failed';" 2>/dev/null || echo "0")

    if [ "$failed_count" -eq 0 ]; then
        echo "   ℹ  没有失败的上传任务"
        echo ""
        return 0
    fi

    echo "   失败任务数: $failed_count"
    echo ""
    read -p "   确认重试所有失败的上传？[Y/n]: " confirm
    confirm="${confirm:-Y}"

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "   ℹ  操作已取消"
        echo ""
        return 0
    fi

    echo ""
    echo "    开始重试..."
    echo ""

    retry_failed_uploads

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "    重试完成"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

show_upload_stats_menu() {
    echo ""
    echo " 上传统计信息"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if ! command -v get_upload_stats &> /dev/null; then
        echo "    上传库未加载，无法查看统计"
        echo "   请确保 fantastic-probe-upload-lib.sh 存在且已正确安装"
        echo ""
        return 1
    fi

    local upload_db="${UPLOAD_CACHE_DB:-/var/lib/fantastic-probe/upload_cache.db}"

    if [ ! -f "$upload_db" ]; then
        echo "   ℹ  上传数据库不存在"
        echo ""
        return 0
    fi

    local total_count
    total_count=$(sqlite3 "$upload_db" \
        "SELECT COUNT(*) FROM upload_cache;" 2>/dev/null || echo "0")

    local success_count
    success_count=$(sqlite3 "$upload_db" \
        "SELECT COUNT(*) FROM upload_cache WHERE status='success';" 2>/dev/null || echo "0")

    local failed_count
    failed_count=$(sqlite3 "$upload_db" \
        "SELECT COUNT(*) FROM upload_cache WHERE status='failed';" 2>/dev/null || echo "0")

    local pending_count
    pending_count=$(sqlite3 "$upload_db" \
        "SELECT COUNT(*) FROM upload_cache WHERE status='pending';" 2>/dev/null || echo "0")

    echo "   总任务数: $total_count"
    echo "    成功: $success_count"
    echo "    失败: $failed_count"
    echo "    待上传: $pending_count"
    echo ""

    if [ "$failed_count" -gt 0 ]; then
        echo "   最近5条失败记录:"
        echo "   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        sqlite3 "$upload_db" \
            "SELECT json_file, last_error_message FROM upload_cache WHERE status='failed' ORDER BY updated_at DESC LIMIT 5;" 2>/dev/null | \
            while IFS='|' read -r json_file error_msg; do
                echo "    $(basename "$json_file")"
                echo "      错误: $error_msg"
                echo ""
            done
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

#==============================================================================
#==============================================================================

get_log_stats() {
    local log_file="$1"

    if [ ! -f "$log_file" ]; then
        echo "日志文件不存在"
        return
    fi

    local total_lines=$(wc -l < "$log_file" 2>/dev/null || echo "0")
    local file_size=$(du -h "$log_file" 2>/dev/null | cut -f1 || echo "0")
    local last_modified=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$log_file" 2>/dev/null || stat -c "%y" "$log_file" 2>/dev/null | cut -d'.' -f1 || echo "未知")

    local today=$(date '+%Y-%m-%d')
    local today_count=$(grep -c "^\[$today" "$log_file" 2>/dev/null || echo "0")

    local success_count=$(grep -c "\|SUCCESS\|成功" "$log_file" 2>/dev/null || echo "0")
    local error_count=$(grep -c "\|ERROR\|错误\|失败" "$log_file" 2>/dev/null || echo "0")
    local warn_count=$(grep -c "\|WARN\|警告" "$log_file" 2>/dev/null || echo "0")

    echo "   文件路径: $log_file"
    echo "   文件大小: $file_size ($total_lines 行)"
    echo "   最后修改: $last_modified"
    echo "   今日记录: $today_count 条"
    echo "   统计:  成功 $success_count |  错误 $error_count |   警告 $warn_count"
}

view_logs() {
    clear
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║                     实时主日志 - Cron 扫描                          ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo ""

    get_log_stats "$LOG_FILE"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo " 提示："
    echo "   • 按 Ctrl+C 退出实时日志"
    echo "   • 日志每 1 分钟更新一次（Cron 任务）"
    echo "   • 可使用以下命令过滤日志："
    echo "     - grep '成功'：只显示成功的记录"
    echo "     - grep '失败'：只显示失败的记录"
    echo "     - grep '$(date +%Y-%m-%d)'：只显示今天的日志"
    echo ""
    echo " 日志格式说明："
    echo "   [时间戳] [CRON] 消息内容"
    echo "    = 成功 |  = 失败 |   = 警告 | ℹ  = 信息"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo " 开始实时查看日志..."
    echo ""

    if [ -f "$LOG_FILE" ]; then
        tail -20 "$LOG_FILE"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 实时日志 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        tail -f "$LOG_FILE"
    else
        echo " 日志文件不存在: $LOG_FILE"
        echo ""
        echo " 可能原因："
        echo "   1. Cron 任务尚未运行（等待 1 分钟）"
        echo "   2. 日志路径配置错误"
        echo "   3. 权限不足，无法写入日志"
        echo ""
    fi
}

view_error_logs() {
    clear
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║                      错误日志 - 故障排查                            ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo ""

    if [ -f "$ERROR_LOG_FILE" ]; then
        get_log_stats "$ERROR_LOG_FILE"

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        local error_count=$(wc -l < "$ERROR_LOG_FILE" 2>/dev/null || echo "0")

        if [ "$error_count" -eq 0 ]; then
            echo " 太棒了！没有错误记录"
            echo ""
            echo " 这意味着："
            echo "   • 所有文件处理成功"
            echo "   • 没有遇到严重问题"
            echo "   • 系统运行正常"
        else
            echo " 最近 50 条错误记录："
            echo ""
            tail -50 "$ERROR_LOG_FILE" | while IFS= read -r line; do
                if echo "$line" | grep -q "ERROR\|错误\|失败"; then
                    echo "    $line"
                elif echo "$line" | grep -q "WARN\|警告"; then
                    echo "    $line"
                else
                    echo "    $line"
                fi
            done

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo " 常见错误类型及解决方案："
            echo ""
            echo "1⃣  【FUSE 未就绪】"
            echo "   症状: bdmv_parse_header / udfread ERROR"
            echo "   解决: 等待 3-5 分钟后自动重试（FUSE 需要下载文件）"
            echo ""
            echo "2⃣  【文件不存在】"
            echo "   症状: No such file / 找不到文件"
            echo "   解决: 检查 STRM 文件路径是否正确"
            echo ""
            echo "3⃣  【权限不足】"
            echo "   症状: Permission denied"
            echo "   解决: 检查文件和目录权限"
            echo ""
            echo "4⃣  【超时】"
            echo "   症状: timeout / Terminated"
            echo "   解决: 增加 FFPROBE_TIMEOUT 配置值"
            echo ""
            echo "5⃣  【协议不支持】"
            echo "   症状: Protocol not found"
            echo "   解决: 升级 ffmpeg 或检查编译选项"
            echo ""
        fi
    else
        echo " 太棒了！没有错误日志文件"
        echo ""
        echo " 这意味着："
        echo "   • 系统从未遇到严重错误"
        echo "   • 所有任务都成功完成"
        echo ""
    fi

    echo ""
}

clear_logs() {
    echo ""
    echo "  清空日志文件"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "     警告: 此操作将删除所有历史日志"
    echo ""
    read -p "   确定要清空日志吗？[y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        truncate -s 0 "$LOG_FILE" 2>/dev/null && echo "    主日志已清空"
        truncate -s 0 "$ERROR_LOG_FILE" 2>/dev/null && echo "    错误日志已清空"
    else
        echo "   ℹ  操作已取消"
    fi
    echo ""
}

#==============================================================================
#==============================================================================

view_failure_list() {
    echo ""
    echo " Cron 模式失败文件列表"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if ! command -v fantastic-probe-cron-scanner &> /dev/null; then
        echo " 错误: 未找到 Cron 扫描器"
        echo "   请确认已安装 Fantastic-Probe Cron 模式"
        return 1
    fi

    fantastic-probe-cron-scanner stats
    echo ""
}

clear_failure_cache() {
    echo ""
    echo "  清空失败缓存"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "     警告: 此操作将删除所有失败记录"
    echo "     清空后，所有失败文件将重新尝试处理"
    echo ""
    read -p "   确定要清空失败缓存吗？[y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if ! command -v fantastic-probe-cron-scanner &> /dev/null; then
            echo "    错误: 未找到 Cron 扫描器"
            return 1
        fi

        fantastic-probe-cron-scanner clear-cache
        echo "    失败缓存已清空"
    else
        echo "   ℹ  操作已取消"
    fi
    echo ""
}

reset_single_file_failure() {
    echo ""
    echo " 重置单个文件的失败记录"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if ! command -v fantastic-probe-cron-scanner &> /dev/null; then
        echo " 错误: 未找到 Cron 扫描器"
        return 1
    fi

    local db_path="/var/lib/fantastic-probe/failure_cache.db"
    if [ ! -f "$db_path" ]; then
        echo "   ℹ  失败缓存数据库不存在，暂无失败文件"
        return 0
    fi

    local files=()
    local file_info=()

    while IFS='|' read -r file_path failure_count last_failure; do
        files+=("$file_path")
        file_info+=("$(basename "$file_path") (失败 ${failure_count} 次, 最后: ${last_failure})")
    done < <(sqlite3 -separator '|' "$db_path" "SELECT file_path, failure_count, datetime(last_failure_time, 'unixepoch', 'localtime') FROM failure_cache ORDER BY last_failure_time DESC;" 2>/dev/null)

    if [ ${#files[@]} -eq 0 ]; then
        echo "    暂无失败文件记录"
        return 0
    fi

    echo "   失败文件列表（共 ${#files[@]} 个）："
    echo ""

    PS3="   请选择要重置的文件 [1-${#files[@]}，0 取消]: "
    select choice in "${file_info[@]}"; do
        if [ -z "$REPLY" ]; then
            echo "     无效选择，请重试"
            continue
        fi

        if [ "$REPLY" = "0" ]; then
            echo "   ℹ  操作已取消"
            return 0
        fi

        if [ "$REPLY" -lt 1 ] || [ "$REPLY" -gt ${#files[@]} ]; then
            echo "     无效选择，请输入 1-${#files[@]} 或 0 取消"
            continue
        fi

        local selected_index=$((REPLY - 1))
        local file_path="${files[$selected_index]}"

        echo ""
        echo "   选中文件: $file_path"
        read -p "   确定要重置此文件的失败记录吗？[y/N]: " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            fantastic-probe-cron-scanner reset-file "$file_path"
            echo "    文件失败记录已重置: $(basename "$file_path")"
            echo "   ℹ  该文件将在下次 Cron 扫描时重新处理"
        else
            echo "   ℹ  操作已取消"
        fi

        break
    done

    echo ""
}

#==============================================================================
#==============================================================================

failure_menu() {
    while true; do
        echo ""
        echo "【失败文件管理】"
        echo "  1) 查看失败文件列表"
        echo "  2) 清空失败缓存"
        echo "  3) 重置单个文件的失败记录"
        echo "  0) 返回主菜单"
        echo ""
        read -p "请选择 [0-3]: " fail_choice
        echo ""

        case "$fail_choice" in
            1)
                view_failure_list
                read -p "按 Enter 继续..."
                ;;
            2)
                clear_failure_cache
                read -p "按 Enter 继续..."
                ;;
            3)
                reset_single_file_failure
                read -p "按 Enter 继续..."
                ;;
            0)
                return
                ;;
            *)
                echo " 无效选择"
                read -p "按 Enter 继续..."
                ;;
        esac
    done
}

service_menu() {
    while true; do
        echo ""
        echo "【服务管理】"
        echo "  1) 查看服务状态"
        echo "  2) 启动服务"
        echo "  3) 停止服务"
        echo "  4) 重启服务"
        echo "  0) 返回主菜单"
        echo ""
        read -p "请选择 [0-4]: " svc_choice
        echo ""

        case "$svc_choice" in
            1)
                show_service_status
                read -p "按 Enter 继续..."
                ;;
            2)
                start_service
                read -p "按 Enter 继续..."
                ;;
            3)
                stop_service
                read -p "按 Enter 继续..."
                ;;
            4)
                restart_service
                read -p "按 Enter 继续..."
                ;;
            0)
                return
                ;;
            *)
                echo " 无效选择"
                read -p "按 Enter 继续..."
                ;;
        esac
    done
}

logs_menu() {
    while true; do
        echo ""
        echo "【日志管理】"
        echo "  1) 查看实时日志"
        echo "  2) 查看错误日志"
        echo "  3) 清空日志文件"
        echo "  0) 返回主菜单"
        echo ""
        read -p "请选择 [0-3]: " log_choice
        echo ""

        case "$log_choice" in
            1)
                view_logs
                ;;
            2)
                view_error_logs
                read -p "按 Enter 继续..."
                ;;
            3)
                clear_logs
                read -p "按 Enter 继续..."
                ;;
            0)
                return
                ;;
            *)
                echo " 无效选择"
                read -p "按 Enter 继续..."
                ;;
        esac
    done
}

system_menu() {
    while true; do
        echo ""
        echo "【系统管理】"
        echo "  1) 查看服务状态"
        echo "  2) 查看依赖状态"
        echo "  3) 停止服务"
        echo "  4) 重启服务"
        echo "  5) 检查更新"
        echo "  6) 卸载服务"
        echo "  7) 目录上传"
        echo "  8) 重试失败上传"
        echo "  9) 查看上传统计"
        echo "  0) 返回主菜单"
        echo ""
        read -p"请选择 [0-9]: " sys_choice
        echo ""

        case "$sys_choice" in
            1)
                show_service_status
                read -p "按 Enter 继续..."
                ;;
            2)
                show_dependency_status
                read -p "按 Enter 继续..."
                ;;
            3)
                stop_service
                read -p "按 Enter 继续..."
                ;;
            4)
                restart_service
                read -p "按 Enter 继续..."
                ;;
            5)
                check_updates
                read -p "按 Enter 继续..."
                ;;
            6)
                uninstall_service
                ;;
            7)
                bulk_upload_json
                read -p "按 Enter 继续..."
                ;;
            8)
                retry_failed_uploads_menu
                read -p "按 Enter 继续..."
                ;;
            9)
                show_upload_stats_menu
                read -p "按 Enter 继续..."
                ;;
            0)
                return
                ;;
            *)
                echo " 无效选择"
                read -p "按 Enter 继续..."
                ;;
        esac
    done
}

#==============================================================================
#==============================================================================

show_menu() {
    echo ""
    echo "╔════════════════════════════════════════════════╗"
    echo "║    Fantastic-Probe 管理工具                    ║"
    echo "╚════════════════════════════════════════════════╝"
    echo ""
    echo "  1) 查看当前配置"
    echo "  2) 配置向导"
    echo "  3) 日志管理"
    echo "  4) 系统管理"
    echo ""
    echo "  0) 退出"
    echo ""
    read -p "请选择操作 [0-4]: " choice
    echo ""

    case "$choice" in
        1)
            show_current_config
            read -p "按 Enter 返回菜单..."
            ;;
        2)
            while true; do
                echo ""
                echo "【配置向导】"
                echo "  1) 修改 STRM 根目录"
                echo "  2) 重新配置 FFprobe"
                echo "  3) 配置 Emby 集成"
                echo "  4) 配置目录上传"
                echo "  0) 返回主菜单"
                echo ""
                read -p "请选择 [0-4]: " config_choice
                echo ""

                case "$config_choice" in
                    1)
                        change_strm_root
                        read -p "按 Enter 继续..."
                        ;;
                    2)
                        reconfigure_ffprobe
                        read -p "按 Enter 继续..."
                        ;;
                    3)
                        configure_emby
                        read -p "按 Enter 继续..."
                        ;;
                    4)
                        configure_upload
                        read -p "按 Enter 继续..."
                        ;;
                    0)
                        break
                        ;;
                    *)
                        echo " 无效选择"
                        read -p "按 Enter 继续..."
                        ;;
                esac
            done
            ;;
        3)
            logs_menu
            ;;
        4)
            system_menu
            ;;
        0)
            echo " 再见！"
            exit 0
            ;;
        *)
            echo " 无效选择"
            read -p "按 Enter 返回菜单..."
            ;;
    esac
}

#==============================================================================
#==============================================================================

main() {
    check_root
    load_config
    validate_config

    if [ $# -gt 0 ]; then
        case "$1" in
            show|view)
                show_current_config
                ;;
            strm)
                change_strm_root
                ;;
            ffprobe)
                reconfigure_ffprobe
                ;;
            emby)
                configure_emby
                ;;
            edit)
                edit_config_file
                ;;
            restart)
                restart_service
                ;;
            status)
                show_service_status
                ;;
            deps|dependencies)
                show_dependency_status
                ;;
            start)
                start_service
                ;;
            stop)
                stop_service
                ;;
            logs)
                view_logs
                ;;
            logs-error)
                view_error_logs
                ;;
            logs-clear)
                clear_logs
                ;;
            failure-list)
                view_failure_list
                ;;
            failure-clear)
                clear_failure_cache
                ;;
            failure-reset)
                reset_single_file_failure
                ;;
            check-update)
                check_updates
                ;;
            install-update)
                install_updates
                ;;
            uninstall)
                uninstall_service
                ;;
            *)
                echo " 未知命令: $1"
                echo ""
                echo "用法: fp-config [命令]"
                echo ""
                echo "可用命令："
                echo "  配置管理："
                echo "    show            查看当前配置"
                echo "    strm            修改 STRM 根目录"
                echo "    ffprobe         重新配置 FFprobe"
                echo "    emby            配置 Emby 媒体库集成"
                echo "    edit            直接编辑配置文件"
                echo ""
                echo "  Cron 模式管理："
                echo "    failure-list    查看失败文件列表"
                echo "    failure-clear   清空失败缓存"
                echo "    failure-reset   重置单个文件的失败记录"
                echo ""
                echo "  服务管理："
                echo "    restart         重启服务"
                echo "    status          查看服务状态"
                echo "    start           启动服务"
                echo "    stop            停止服务"
                echo ""
                echo "  日志管理："
                echo "    logs            查看实时日志"
                echo "    logs-error      查看错误日志"
                echo "    logs-clear      清空日志文件"
                echo ""
                echo "  系统管理:"
                echo "    status          查看服务状态"
                echo "    deps            查看依赖状态"
                echo "    check-update    检查更新"
                echo "    install-update  安装更新"
                echo "    uninstall       卸载服务"
                echo ""
                exit 1
                ;;
        esac
    else
        while true; do
            show_menu
        done
    fi
}

main "$@"
