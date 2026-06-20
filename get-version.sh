#!/bin/bash
export LC_ALL=C.UTF-8

#==============================================================================
# Dynamic Version Number Script
# Gets version from local Git tags or hardcoded default
# Usage:
#   source ./get-version.sh
#   echo "Current version: $VERSION"
#
# Note: This script only gets "local version", not from GitHub API
#==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default version (fallback)
VERSION="1.2.2"

#==============================================================================
# Method 1: Get from local Git tags
#==============================================================================

get_version_from_git_tag() {
    if command -v git &> /dev/null && [ -d "$SCRIPT_DIR/.git" ]; then
        # Get latest project version tag (exclude ffprobe-related)
        # Only match tags starting with 'v'
        local tag=$(git -C "$SCRIPT_DIR" tag -l "v*" | sort -V | tail -1)
        if [ -n "$tag" ]; then
            # Remove 'v' prefix
            echo "${tag#v}"
            return 0
        fi
    fi
    return 1
}

#==============================================================================
# Method 2: Read from script comment (fallback)
#==============================================================================

get_version_from_script_comment() {
    local calling_script="${1:-}"

    if [ -f "$calling_script" ]; then
        local version=$(grep -E "版本:|VERSION=" "$calling_script" | head -1 | grep -oP '\d+\.\d+\.\d+')
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    fi

    return 1
}

#==============================================================================
# Main: Get local version
#==============================================================================

# Get version (by priority)
# Note: Does not fetch from GitHub API (that's "remote version", handled by caller)
VERSION=$(get_version_from_git_tag) || \
VERSION=$(get_version_from_script_comment "$1") || \
VERSION="1.2.2"  # Final fallback to hardcoded default

#==============================================================================
# Export variable
#==============================================================================

export VERSION

# If script is executed directly, output version info
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Support --version flag for script parsing
    if [ "$1" = "--version" ]; then
        echo "$VERSION"
    else
        # Human-friendly output format (keep Chinese for users)
        echo "=========================================="
        echo "Fantastic-Probe 版本信息"
        echo "=========================================="
        echo ""
        echo "当前版本：$VERSION"
        echo ""

        # Show source
        if command -v git &> /dev/null && [ -d "$SCRIPT_DIR/.git" ]; then
            git_tag=$(git -C "$SCRIPT_DIR" tag -l "v*" | sort -V | tail -1)
            if [ -n "$git_tag" ]; then
                echo "来源：本地 Git tags ($git_tag)"
            else
                echo "来源：硬编码默认值"
            fi
        else
            echo "来源：硬编码默认值（非 Git 仓库）"
        fi
    fi
fi
