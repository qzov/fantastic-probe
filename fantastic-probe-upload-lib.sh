#!/bin/bash
export LC_ALL=C.UTF-8

#==============================================================================
# Fantastic-Probe Upload Library
# Provides automatic JSON upload to network storage functionality
# Author: Fantastic-Probe Team
#==============================================================================

set -euo pipefail

#==============================================================================
# Configuration
#==============================================================================

# Upload database path
UPLOAD_CACHE_DB="${UPLOAD_CACHE_DB:-/var/lib/fantastic-probe/upload_cache.db}"

# Upload lock file (ensure serial uploads)
UPLOAD_LOCK_FILE="${UPLOAD_LOCK_FILE:-/tmp/fantastic-probe-upload.lock}"

# Upload interval (seconds between directory batches, default 10s)
UPLOAD_INTERVAL="${UPLOAD_INTERVAL:-10}"

# Log file path (inherit from main config if available)
LOG_FILE="${LOG_FILE:-/var/log/fantastic_probe.log}"
ERROR_LOG_FILE="${ERROR_LOG_FILE:-/var/log/fantastic_probe_errors.log}"

# Ensure upload cache directory exists
CACHE_DIR=$(dirname "$UPLOAD_CACHE_DB")
mkdir -p "$CACHE_DIR"

#==============================================================================
# Logging functions (compatible with existing log system)
#==============================================================================

upload_log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [UPLOAD] $1" >> "$LOG_FILE"
}

upload_log_info() {
    upload_log "ℹ  INFO: $1"
}

upload_log_warn() {
    upload_log "  WARN: $1"
}

upload_log_error() {
    upload_log " ERROR: $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [UPLOAD] $1" >> "$ERROR_LOG_FILE"
}

upload_log_success() {
    upload_log " SUCCESS: $1"
}

upload_log_debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        upload_log " DEBUG: $1"
    fi
}

#==============================================================================
#==============================================================================

upload_console() {
    echo "$1"
}

upload_console_info() {
    local msg="ℹ  INFO: $1"
    upload_console "$msg"
    upload_log "$msg"
}

upload_console_warn() {
    local msg="  WARN: $1"
    upload_console "$msg"
    upload_log "$msg"
}

upload_console_error() {
    local msg=" ERROR: $1"
    upload_console "$msg"
    upload_log "$msg"
    echo "[$( date '+%Y-%m-%d %H:%M:%S')] [UPLOAD] $1" >> "$ERROR_LOG_FILE"
}

upload_console_success() {
    local msg=" SUCCESS: $1"
    upload_console "$msg"
    upload_log "$msg"
}

#==============================================================================
# Database initialization
#==============================================================================

init_upload_cache_db() {
    # Initialize SQLite database for upload tracking
    sqlite3 "$UPLOAD_CACHE_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS upload_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    json_file TEXT NOT NULL UNIQUE,
    target_path TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    upload_count INTEGER DEFAULT 0,
    last_upload_time INTEGER,
    last_error_message TEXT,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_status ON upload_cache(status);
CREATE INDEX IF NOT EXISTS idx_json_file ON upload_cache(json_file);
CREATE INDEX IF NOT EXISTS idx_last_upload_time ON upload_cache(last_upload_time);
SQL

    upload_log_debug "上传缓存数据库已初始化: $UPLOAD_CACHE_DB"
}

#==============================================================================
# Path mapping function
#==============================================================================

# Legacy function for backward compatibility
calculate_target_path() {
    local json_file="$1"
    calculate_target_path_universal "$json_file" "json"
}

# Universal path mapping function
# Supports: multiple file types, TV shows structure, arbitrary nesting
calculate_target_path_universal() {
    local source_file="$1"
    local file_type="${2:-auto}"  # auto, json, nfo, srt, ass, ssa, png, jpg

    # Validate source file exists
    if [ ! -f "$source_file" ]; then
        upload_log_error "源文件不存在: $source_file"
        return 1
    fi

    local source_dir=$(dirname "$source_file")
    local source_name=$(basename "$source_file")
    local source_ext="${source_name##*.}"

    # Auto-detect file type if needed
    if [ "$file_type" = "auto" ]; then
        case "$source_ext" in
            json) file_type="json" ;;
            nfo)  file_type="nfo" ;;
            srt)  file_type="srt" ;;
            ass)  file_type="ass" ;;
            ssa)  file_type="ssa" ;;
            png)  file_type="png" ;;
            jpg|jpeg) file_type="jpg" ;;
            *)
                upload_log_error "不支持的文件类型: $source_ext"
                return 1
                ;;
        esac
    fi

    upload_log_debug "处理文件: $source_name (类型: $file_type)"

    # Step 1: Find corresponding STRM file (same directory first, then subdirectories)
    local base_name strm_file

    case "$file_type" in
        json)
            # movie.iso-mediainfo.json -> movie.iso.strm
            base_name="${source_name%.iso-mediainfo.json}.iso"
            strm_file="${source_dir}/${base_name}.strm"
            ;;
        nfo|png|jpg)
            # movie.iso.nfo -> movie.iso.strm
            base_name="${source_name%.*}"
            if [[ "$base_name" == *.iso ]]; then
                strm_file="${source_dir}/${base_name}.strm"
            else
                strm_file=$(find "$source_dir" -maxdepth 1 -name "*.iso.strm" 2>/dev/null | head -n 1)
            fi
            ;;
        srt|ass|ssa)
            # movie.iso.en.srt -> movie.iso.strm
            # movie.iso.zh.ass -> movie.iso.strm
            base_name="$source_name"
            base_name=$(echo "$base_name" | sed -E 's/\.(srt|ass|ssa)$//')
            base_name=$(echo "$base_name" | sed -E 's/\.(en|zh|ja|ko|fr|de|es|zh-CN|zh-TW|pt-BR)$//')
            strm_file="${source_dir}/${base_name}.strm"
            ;;
    esac

    # If STRM not found in same directory, search subdirectories (Show-level files)
    if [ ! -f "$strm_file" ] || [ -z "$strm_file" ]; then
        upload_log_debug "同目录无 STRM，查找子目录..."
        strm_file=$(find "$source_dir" -maxdepth 2 -name "*.iso.strm" 2>/dev/null | head -n 1)
    fi

    # Validate STRM file exists
    if [ ! -f "$strm_file" ]; then
        upload_log_error "找不到对应的 STRM 文件"
        upload_log_debug "  源文件: $source_file"
        upload_log_debug "  源目录: $source_dir"
        return 1
    fi

    local strm_dir=$(dirname "$strm_file")
    upload_log_debug "使用 STRM: $strm_file"

    # Step 2: Read STRM content (network storage ISO path)
    local iso_path
    iso_path=$(head -n 1 "$strm_file" | tr -d '\r\n')

    if [ -z "$iso_path" ]; then
        upload_log_error "STRM 文件内容为空: $strm_file"
        return 1
    fi

    upload_log_debug "STRM 内容: $iso_path"

    # Step 3: Calculate target path
    local target_path

    if [ "$source_dir" = "$strm_dir" ]; then
        # Episode-level file: same directory as STRM
        # source_dir: /STRM/tv/Show/Season 01
        # strm_dir:   /STRM/tv/Show/Season 01
        # iso_path:   /storage/tv/Show/Season 01/episode.iso
        # target:     /storage/tv/Show/Season 01/episode.iso.nfo
        local storage_dir="${iso_path%/*}"
        target_path="${storage_dir}/${source_name}"
        upload_log_debug "Episode-level 文件: $source_name"
    else
        # Show-level file: parent directory of STRM
        # source_dir: /STRM/tv/Show
        # strm_dir:   /STRM/tv/Show/Season 01
        # iso_path:   /storage/tv/Show/Season 01/episode.iso
        # target:     /storage/tv/Show/tvshow.nfo
        local show_storage_dir
        show_storage_dir=$(dirname "$(dirname "$iso_path")")
        target_path="${show_storage_dir}/${source_name}"
        upload_log_debug "Show-level 文件: $source_name"
    fi

    upload_log_debug "路径映射: $(basename "$source_file") -> $target_path"
    echo "$target_path"
    return 0
}

#==============================================================================
# Database record functions
#==============================================================================

record_upload_pending() {
    local json_file="$1"
    local target_path="$2"
    local now
    now=$(date +%s)

    sqlite3 "$UPLOAD_CACHE_DB" <<SQL
INSERT OR REPLACE INTO upload_cache (json_file, target_path, status, created_at, updated_at)
VALUES ('$json_file', '$target_path', 'pending', $now, $now);
SQL

    upload_log_debug "记录待上传: $json_file"
}

record_upload_success() {
    local json_file="$1"
    local now
    now=$(date +%s)

    sqlite3 "$UPLOAD_CACHE_DB" <<SQL
UPDATE upload_cache
SET status = 'success',
    upload_count = upload_count + 1,
    last_upload_time = $now,
    last_error_message = NULL,
    updated_at = $now
WHERE json_file = '$json_file';
SQL

    upload_log_success "上传成功: $json_file"
}

record_upload_failure() {
    local json_file="$1"
    local error_message="$2"
    local now
    now=$(date +%s)

    # Escape single quotes in error message
    error_message="${error_message//\'/\'\'}"

    sqlite3 "$UPLOAD_CACHE_DB" <<SQL
UPDATE upload_cache
SET status = 'failed',
    upload_count = upload_count + 1,
    last_upload_time = $now,
    last_error_message = '$error_message',
    updated_at = $now
WHERE json_file = '$json_file';
SQL

    upload_log_error "上传失败: $json_file - $error_message"
}

#==============================================================================
# Core upload function (with flock for serial execution)
#==============================================================================

upload_json_single() {
    local json_file="$1"
    local target_path="$2"  # Optional: pre-calculated target path

    # Validate JSON file exists
    if [ ! -f "$json_file" ]; then
        upload_log_error "文件不存在，跳过上传: $json_file"
        return 1
    fi

    # Calculate target path if not provided
    if [ -z "$target_path" ]; then
        if ! target_path=$(calculate_target_path "$json_file"); then
            record_upload_failure "$json_file" "路径映射失败"
            upload_console_error "路径映射失败: $(basename "$json_file")"
            return 1
        fi
    fi

    # Record pending status
    record_upload_pending "$json_file" "$target_path"

    # Acquire upload lock (ensure serial uploads)
    upload_log_info "等待上传锁: $(basename "$json_file")"

    (
        # Use flock to ensure only one upload at a time
        flock -x 201

        upload_log_info "开始上传: $(basename "$json_file")"
        upload_log_debug "  源文件: $json_file"
        upload_log_debug "  目标路径: $target_path"

        # Check if target file already exists with same size
        if [ -f "$target_path" ]; then
            upload_log_debug "  目标文件已存在，检查文件大小..."

            # Get file sizes (compatible with both macOS and Linux)
            local source_size target_size
            source_size=$(stat -f%z "$json_file" 2>/dev/null || stat -c%s "$json_file" 2>/dev/null)
            target_size=$(stat -f%z "$target_path" 2>/dev/null || stat -c%s "$target_path" 2>/dev/null)

            if [ "$source_size" = "$target_size" ]; then
                # File already exists with same size, skip upload
                record_upload_success "$json_file"
                upload_console_success "$(basename "$json_file") (已存在，跳过上传)"
                upload_log_success "文件已存在且大小相同，跳过上传: $(basename "$json_file") (${source_size} 字节)"
                return 0
            else
                upload_log_debug "  文件大小不同（源: ${source_size}, 目标: ${target_size}），继续上传"
            fi
        fi

        # Ensure target directory exists
        local target_dir
        target_dir=$(dirname "$target_path")

        if [ ! -d "$target_dir" ]; then
            upload_log_info "  创建目标目录: $target_dir"
            if ! mkdir -p "$target_dir" 2>/dev/null; then
                record_upload_failure "$json_file" "无法创建目标目录: $target_dir"
                upload_console_error "无法创建目标目录: $target_dir"
                return 1
            fi
        fi

        # Perform upload (copy JSON to target path)
        local start_time
        start_time=$(date +%s)

        if cp "$json_file" "$target_path" 2>/dev/null; then
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))

            # Record success
            record_upload_success "$json_file"
            upload_console_success "$(basename "$json_file") (耗时: ${duration}秒)"
            upload_log_success "上传完成: $(basename "$json_file") (耗时: ${duration}秒)"

            return 0
        else
            # Record failure
            local error_msg="复制文件失败"
            record_upload_failure "$json_file" "$error_msg"
            upload_console_error "$(basename "$json_file"): $error_msg"
            return 1
        fi

    ) 201>"$UPLOAD_LOCK_FILE"

    return $?
}

#==============================================================================
# Async upload wrapper (non-blocking)
#==============================================================================

upload_json_async() {
    local json_file="$1"

    # Launch upload in background
    upload_log_debug "异步上传任务启动: $(basename "$json_file")"

    (
        upload_json_single "$json_file"
    ) &

    # Detach from parent process
    disown
}

#==============================================================================
# Auto upload function (for single directory)
#==============================================================================

# Upload all configured file types in a single directory (sync)
# Called by process_iso_strm_full() after JSON generation
upload_directory_files() {
    local strm_dir="$1"
    local file_types="${2:-$UPLOAD_FILE_TYPES}"

    # Skip if directory doesn't exist
    if [ ! -d "$strm_dir" ]; then
        upload_log_error "目录不存在: $strm_dir"
        return 1
    fi

    upload_log_info "开始自动上传: $strm_dir (类型: $file_types)"

    # Parse file types and build find patterns (reuse logic from upload_all_pending)
    IFS=',' read -ra types_array <<< "$file_types"
    local find_patterns=()
    local first=true

    for type in "${types_array[@]}"; do
        type=$(echo "$type" | tr -d ' ')  # Remove spaces
        case "$type" in
            json)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.iso-mediainfo.json")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.iso-mediainfo.json")
                fi
                ;;
            nfo)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.nfo")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.nfo")
                fi
                ;;
            srt)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.srt")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.srt")
                fi
                ;;
            ass)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.ass")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.ass")
                fi
                ;;
            ssa)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.ssa")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.ssa")
                fi
                ;;
            png)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.png")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.png")
                fi
                ;;
            jpg)
                if [ "$first" = true ]; then
                    find_patterns+=("(" "-name" "*.jpg" "-o" "-name" "*.jpeg" ")")
                    first=false
                else
                    find_patterns+=("-o" "(" "-name" "*.jpg" "-o" "-name" "*.jpeg" ")")
                fi
                ;;
        esac
    done

    if [ ${#find_patterns[@]} -eq 0 ]; then
        upload_log_error "没有配置有效的上传文件类型"
        return 1
    fi

    # Find all matching files in this directory (maxdepth 1)
    local -a dir_files=()
    while IFS= read -r file; do
        dir_files+=("$file")
    done < <(find "$strm_dir" -maxdepth 1 -type f \( "${find_patterns[@]}" \) 2>/dev/null || true)

    # Skip if no matching files
    if [ ${#dir_files[@]} -eq 0 ]; then
        upload_log_debug "未找到匹配的文件: $strm_dir"
        return 0
    fi

    upload_log_info "找到 ${#dir_files[@]} 个待上传文件"

    # Statistics
    local success_count=0
    local failure_count=0
    local skipped_count=0

    # Process files in this directory
    for file in "${dir_files[@]}"; do
        # Check if file exists in database with success status
        local db_status
        db_status=$(sqlite3 "$UPLOAD_CACHE_DB" \
            "SELECT status FROM upload_cache WHERE json_file='$file';" 2>/dev/null || echo "")

        if [ "$db_status" = "success" ]; then
            upload_log_debug "跳过已上传: $(basename "$file")"
            skipped_count=$((skipped_count + 1))
            continue
        fi

        upload_log_info "上传文件: $(basename "$file")"

        # Upload file (serial, blocking)
        if upload_file_single "$file"; then
            success_count=$((success_count + 1))
        else
            failure_count=$((failure_count + 1))
        fi
    done

    upload_log_info "自动上传完成: 成功 $success_count, 失败 $failure_count, 跳过 $skipped_count"
    return 0
}

# Upload all configured file types in a single directory (async)
# Wrapper for background execution
upload_directory_files_async() {
    local strm_dir="$1"
    local file_types="${2:-$UPLOAD_FILE_TYPES}"

    # Run in background
    (
        upload_directory_files "$strm_dir" "$file_types"
    ) &
    disown
}

#==============================================================================
# Bulk upload function (for existing JSON files)
#==============================================================================

upload_all_pending() {
    local strm_root="${1:-$STRM_ROOT}"
    local file_types="${UPLOAD_FILE_TYPES:-json}"

    upload_log_info "开始批量上传扫描: $strm_root (类型: $file_types)"
    upload_console_info "扫描目录: $strm_root"
    upload_console_info "上传类型: $file_types"

    # Parse file types and build find patterns
    IFS=',' read -ra types_array <<< "$file_types"
    local find_patterns=()
    local first=true

    for type in "${types_array[@]}"; do
        type=$(echo "$type" | tr -d ' ')  # Remove spaces
        case "$type" in
            json)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.iso-mediainfo.json")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.iso-mediainfo.json")
                fi
                ;;
            nfo)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.nfo")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.nfo")
                fi
                ;;
            srt)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.srt")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.srt")
                fi
                ;;
            ass)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.ass")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.ass")
                fi
                ;;
            ssa)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.ssa")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.ssa")
                fi
                ;;
            png)
                if [ "$first" = true ]; then
                    find_patterns+=("-name" "*.png")
                    first=false
                else
                    find_patterns+=("-o" "-name" "*.png")
                fi
                ;;
            jpg)
                if [ "$first" = true ]; then
                    find_patterns+=("(" "-name" "*.jpg" "-o" "-name" "*.jpeg" ")")
                    first=false
                else
                    find_patterns+=("-o" "(" "-name" "*.jpg" "-o" "-name" "*.jpeg" ")")
                fi
                ;;
        esac
    done

    if [ ${#find_patterns[@]} -eq 0 ]; then
        upload_console_error "没有配置有效的上传文件类型"
        return 1
    fi

    # Step 1: Find all directories containing .iso.strm files (grouped by directory)
    upload_console_info "扫描 ISO 目录..."
    local -a strm_dirs=()
    while IFS= read -r strm_file; do
        local strm_dir=$(dirname "$strm_file")
        strm_dirs+=("$strm_dir")
    done < <(find "$strm_root" -type f -name "*.iso.strm" 2>/dev/null || true)

    # Remove duplicates and sort
    if [ ${#strm_dirs[@]} -eq 0 ]; then
        upload_console_warn "未找到任何 .iso.strm 文件"
        return 0
    fi

    # Use mapfile to preserve spaces in directory names
    local -a unique_dirs=()
    while IFS= read -r dir; do
        unique_dirs+=("$dir")
    done < <(printf '%s\n' "${strm_dirs[@]}" | sort -u)
    strm_dirs=("${unique_dirs[@]}")
    upload_console_info "找到 ${#strm_dirs[@]} 个 ISO 目录"
    upload_console ""

    # Statistics
    local total_dirs=0
    local total_files=0
    local success_count=0
    local failure_count=0
    local skipped_count=0

    # Step 2: Process each directory
    for strm_dir in "${strm_dirs[@]}"; do
        # Find all matching files in this directory (maxdepth 1)
        local -a dir_files=()
        while IFS= read -r file; do
            dir_files+=("$file")
        done < <(find "$strm_dir" -maxdepth 1 -type f \( "${find_patterns[@]}" \) 2>/dev/null || true)

        # Skip if no matching files
        if [ ${#dir_files[@]} -eq 0 ]; then
            continue
        fi

        # Only count directories with matching files
        total_dirs=$((total_dirs + 1))

        # Display directory header
        local dir_name=$(basename "$strm_dir")
        upload_console "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        upload_console_info "[$total_dirs/${#strm_dirs[@]}] 目录: $dir_name"
        upload_console "  找到 ${#dir_files[@]} 个文件"
        upload_log_info "处理目录 $total_dirs: $strm_dir (${#dir_files[@]} 个文件)"

        # Process files in this directory
        for file in "${dir_files[@]}"; do
            total_files=$((total_files + 1))

            # Check if file exists in database with success status
            local db_status
            db_status=$(sqlite3 "$UPLOAD_CACHE_DB" \
                "SELECT status FROM upload_cache WHERE json_file='$file';" 2>/dev/null || echo "")

            if [ "$db_status" = "success" ]; then
                upload_console "  [$(basename "$file")]   已上传"
                upload_log_debug "跳过已上传: $(basename "$file")"
                skipped_count=$((skipped_count + 1))
                continue
            fi

            # Display file progress
            upload_console "  [$(basename "$file")]..."
            upload_log_info "  上传文件: $(basename "$file")"

            # Upload file (serial, blocking)
            if upload_file_single "$file"; then
                success_count=$((success_count + 1))
            else
                failure_count=$((failure_count + 1))
            fi
        done

        # Wait for batch interval (rate limiting between directories)
        # Only wait if this is not the last directory
        if [ $total_dirs -lt ${#strm_dirs[@]} ] && [ "$UPLOAD_INTERVAL" -gt 0 ]; then
            upload_console "    等待 ${UPLOAD_INTERVAL} 秒（批次间隔）..."
            upload_log_debug "等待 ${UPLOAD_INTERVAL} 秒（批次间隔）"
            sleep "$UPLOAD_INTERVAL"
        fi

        upload_console ""
    done

    # Summary
    upload_console "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    upload_console_info "批量上传统计"
    upload_console "  处理目录数: $total_dirs"
    upload_console "  总计文件数: $total_files"
    upload_console "   成功: $success_count"
    upload_console "   失败: $failure_count"
    upload_console "    跳过(已上传): $skipped_count"
    upload_console "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    upload_log_info "批量上传完成: 处理 $total_dirs 个目录, 总计 $total_files 个文件, 成功 $success_count 个, 失败 $failure_count 个, 跳过 $skipped_count 个"
}

# Upload single file (universal wrapper)
upload_file_single() {
    local file="$1"

    # Use universal path mapping for all files
    local target_path
    target_path=$(calculate_target_path_universal "$file" "auto")
    if [ $? -ne 0 ]; then
        upload_console_error "路径映射失败: $(basename "$file")"
        record_upload_failure "$file" "路径映射失败"
        return 1
    fi

    # Execute upload with calculated target path
    upload_json_single "$file" "$target_path"
}

#==============================================================================
# Retry failed uploads
#==============================================================================

retry_failed_uploads() {
    upload_log_info "开始重试失败的上传任务"
    upload_console_info "查询失败的上传任务..."

    local success_count=0
    local failure_count=0

    # Query all failed uploads from database
    local failed_files
    failed_files=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "SELECT json_file FROM upload_cache WHERE status='failed' ORDER BY updated_at;" 2>/dev/null || echo "")

    if [ -z "$failed_files" ]; then
        upload_console_info "没有失败的上传任务"
        upload_log_info "没有失败的上传任务"
        return 0
    fi

    # Count total failed files
    local total_failed=0
    while IFS= read -r json_file; do
        if [ -n "$json_file" ]; then
            total_failed=$((total_failed + 1))
        fi
    done <<< "$failed_files"

    upload_console_info "找到 $total_failed 个失败的上传任务，开始重试..."
    upload_console ""

    local current_index=0
    # Retry each failed file
    while IFS= read -r json_file; do
        if [ -z "$json_file" ]; then
            continue
        fi

        current_index=$((current_index + 1))
        upload_console "[$current_index/$total_failed] $(basename "$json_file")..."
        upload_log_info "重试上传: $(basename "$json_file")"

        # Upload file (serial, blocking)
        if upload_json_single "$json_file"; then
            success_count=$((success_count + 1))
        else
            failure_count=$((failure_count + 1))
        fi

    done <<< "$failed_files"

    # Summary
    upload_console ""
    upload_console "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    upload_console_info "重试完成"
    upload_console "   重试成功: $success_count 个"
    upload_console "   仍然失败: $failure_count 个"
    upload_console "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    upload_log_info "重试完成: 成功 $success_count 个, 仍失败 $failure_count 个"
}

#==============================================================================
# Cleanup and maintenance
#==============================================================================

cleanup_upload_cache() {
    local days_to_keep="${1:-30}"

    upload_log_info "清理 $days_to_keep 天前的上传记录"

    local cutoff_time
    cutoff_time=$(date -d "$days_to_keep days ago" +%s 2>/dev/null || date -v-${days_to_keep}d +%s)

    local deleted_count
    deleted_count=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "DELETE FROM upload_cache WHERE status='success' AND updated_at < $cutoff_time; SELECT changes();" 2>/dev/null || echo "0")

    upload_log_info "已清理 $deleted_count 条旧记录"
}

get_upload_stats() {
    upload_log_info "上传统计信息:"
    upload_console_info "查询上传统计信息..."

    local total_count
    total_count=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "SELECT COUNT(*) FROM upload_cache;" 2>/dev/null || echo "0")

    local success_count
    success_count=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "SELECT COUNT(*) FROM upload_cache WHERE status='success';" 2>/dev/null || echo "0")

    local failed_count
    failed_count=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "SELECT COUNT(*) FROM upload_cache WHERE status='failed';" 2>/dev/null || echo "0")

    local pending_count
    pending_count=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "SELECT COUNT(*) FROM upload_cache WHERE status='pending';" 2>/dev/null || echo "0")

    upload_console ""
    upload_console "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    upload_console_info "上传统计信息"
    upload_console "  总计: $total_count 个文件"
    upload_console "   成功: $success_count 个"
    upload_console "   失败: $failed_count 个"
    upload_console "   待上传: $pending_count 个"
    upload_console "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    upload_console ""

    upload_log_info "  总计: $total_count"
    upload_log_info "  成功: $success_count"
    upload_log_info "  失败: $failed_count"
    upload_log_info "  待上传: $pending_count"
}

#==============================================================================
# Initialization on library load
#==============================================================================

# Initialize database when library is sourced
init_upload_cache_db
