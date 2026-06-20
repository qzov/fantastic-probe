#!/bin/bash

#==============================================================================
#==============================================================================

set -e

echo "=========================================="
echo "ISO 媒体信息提取服务 - 卸载程序"
echo "=========================================="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo " 请使用 root 权限运行此脚本"
    echo "   sudo bash $0"
    exit 1
fi

echo "1⃣  删除脚本和工具..."
FILES_REMOVED=0

if [ -f "/usr/local/bin/fantastic-probe-cron-scanner" ]; then
    rm -f /usr/local/bin/fantastic-probe-cron-scanner
    echo "    Cron 扫描器已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

if [ -f "/usr/local/lib/fantastic-probe-process-lib.sh" ]; then
    rm -f /usr/local/lib/fantastic-probe-process-lib.sh
    echo "    处理库已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

if [ -f "/usr/local/lib/fantastic-probe-upload-lib.sh" ]; then
    rm -f /usr/local/lib/fantastic-probe-upload-lib.sh
    echo "    上传库已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

if [ -f "/usr/local/bin/fantastic-probe-auto-update" ]; then
    rm -f /usr/local/bin/fantastic-probe-auto-update
    echo "    自动更新助手已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

if [ -f "/usr/local/bin/fp-config" ]; then
    rm -f /usr/local/bin/fp-config
    echo "    配置工具已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

if [ -L "/usr/local/bin/fantastic-probe-config" ] || [ -f "/usr/local/bin/fantastic-probe-config" ]; then
    rm -f /usr/local/bin/fantastic-probe-config
    echo "    兼容链接已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

if [ -f "/usr/local/bin/get-version.sh" ]; then
    rm -f /usr/local/bin/get-version.sh
    echo "    版本号获取脚本已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

# 删除由 fantastic-probe 安装的预编译 ffprobe
if [ -f "/usr/local/bin/ffprobe" ]; then
    read -p "   是否删除由 fantastic-probe 安装的 ffprobe (/usr/local/bin/ffprobe)？(y/N): " -n 1 -r del_ffprobe
    echo ""
    if [[ $del_ffprobe =~ ^[Yy]$ ]]; then
        rm -f /usr/local/bin/ffprobe
        echo "    ffprobe 已删除"
        FILES_REMOVED=$((FILES_REMOVED + 1))
    else
        echo "   ℹ  ffprobe 已保留"
    fi
else
    echo "    ffprobe 不存在（无需删除）"
fi

if [ -d "/usr/share/fantastic-probe" ]; then
    rm -rf /usr/share/fantastic-probe
    echo "    预编译包缓存已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

if [ $FILES_REMOVED -eq 0 ]; then
    echo "    所有脚本均不存在"
fi
echo ""

echo "2⃣  清理临时文件和锁文件..."
TEMP_FILES_REMOVED=0

if [ -p "/tmp/fantastic_probe_queue.fifo" ]; then
    rm -f /tmp/fantastic_probe_queue.fifo
    echo "    队列文件已删除"
    TEMP_FILES_REMOVED=$((TEMP_FILES_REMOVED + 1))
fi

if [ -f "/tmp/fantastic-probe-update-marker" ]; then
    rm -f /tmp/fantastic-probe-update-marker
    echo "    更新标记文件已删除"
    TEMP_FILES_REMOVED=$((TEMP_FILES_REMOVED + 1))
fi

if [ -f "/tmp/fantastic-probe-auto-update.lock" ]; then
    rm -f /tmp/fantastic-probe-auto-update.lock
    echo "    更新锁文件已删除"
    TEMP_FILES_REMOVED=$((TEMP_FILES_REMOVED + 1))
fi

if [ -f "/tmp/fantastic_probe_cron_scanner.lock" ]; then
    rm -f /tmp/fantastic_probe_cron_scanner.lock
    echo "    Cron 扫描器锁文件已删除"
    TEMP_FILES_REMOVED=$((TEMP_FILES_REMOVED + 1))
fi

if [ -d "/tmp/fantastic-probe-install-"* ]; then
    rm -rf /tmp/fantastic-probe-install-*
    echo "    临时安装目录已删除"
    TEMP_FILES_REMOVED=$((TEMP_FILES_REMOVED + 1))
fi

if [ $TEMP_FILES_REMOVED -eq 0 ]; then
    echo "    无临时文件需要清理"
fi
echo ""

echo "3⃣  删除 Cron 任务和 systemd 服务..."
if [ -f "/etc/cron.d/fantastic-probe" ]; then
    rm -f /etc/cron.d/fantastic-probe
    echo "    Cron 任务已删除"
else
    echo "    Cron 任务不存在"
fi

if [ -f "/etc/systemd/system/fantastic-probe.service" ]; then
    systemctl stop fantastic-probe.service 2>/dev/null || true
    systemctl disable fantastic-probe.service 2>/dev/null || true
    rm -f /etc/systemd/system/fantastic-probe.service
    systemctl daemon-reload 2>/dev/null || true
    echo "    systemd 服务已删除"
else
    echo "    systemd 服务不存在"
fi
echo ""

echo "4⃣  数据目录处理..."
DATA_DIR="/var/lib/fantastic-probe"
if [ -d "$DATA_DIR" ]; then
    read -p "   是否删除数据目录（含失败缓存、上传记录）？ (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$DATA_DIR"
        echo "    数据目录已删除: $DATA_DIR"
    else
        echo "   ℹ  数据目录保留在: $DATA_DIR"
    fi
else
    echo "    数据目录不存在"
fi
echo ""

echo "5⃣  清理 logrotate 配置..."
if [ -f "/etc/logrotate.d/fantastic-probe" ]; then
    rm -f /etc/logrotate.d/fantastic-probe
    echo "    logrotate 配置已删除"
else
    echo "    logrotate 配置不存在"
fi
echo ""

echo "6⃣  配置文件处理..."
if [ -d "/etc/fantastic-probe" ]; then
    read -p "   是否删除配置文件？ (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf /etc/fantastic-probe
        echo "    配置目录已删除"
    else
        echo "   ℹ  配置文件保留在: /etc/fantastic-probe/"
        echo "      如需重新安装，配置将被保留"
    fi
else
    echo "    配置目录不存在"
fi
echo ""

echo "7⃣  日志文件处理..."
read -p "   是否删除日志文件？ (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f /var/log/fantastic_probe.log
    rm -f /var/log/fantastic_probe_errors.log
    rm -f /var/log/fantastic_probe_upload.log
    echo "    日志文件已删除"
else
    echo "   ℹ  日志文件保留在:"
    echo "      /var/log/fantastic_probe.log"
    echo "      /var/log/fantastic_probe_errors.log"
    echo "      /var/log/fantastic_probe_upload.log"
fi
echo ""

echo "8⃣  生成的 JSON 文件处理..."
echo "   ℹ  JSON 文件已被保留（包含宝贵的媒体信息扫描结果）"
echo "   ℹ  如需手动清理，请运行："
echo "      find <STRM_ROOT> -type f -name '*-mediainfo.json' -delete"
echo ""

#
# echo ""
# if [[ $REPLY =~ ^[Yy]$ ]]; then
#     if [ -f "/etc/fantastic-probe/config" ]; then
#         # shellcheck source=/dev/null
#         source "/etc/fantastic-probe/config"
#     fi
#
#     if [ -d "$STRM_ROOT" ]; then
#         JSON_COUNT=$(find "$STRM_ROOT" -type f -name "*.iso-mediainfo.json" 2>/dev/null | wc -l)
#         if [ "$JSON_COUNT" -gt 0 ]; then
#             find "$STRM_ROOT" -type f -name "*.iso-mediainfo.json" -delete
#         else
#         fi
#     else
#     fi
# else
# fi
# echo ""

echo "=========================================="
echo " 卸载完成！"
echo "=========================================="
echo ""
echo "ℹ  以下内容已保留（需手动清理）："
echo "  - JSON 媒体信息文件（位置取决于 STRM_ROOT 配置）"
echo "  - 备份文件: /var/backups/fantastic-probe/（如存在）"
echo ""
