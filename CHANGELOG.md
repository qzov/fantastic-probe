# Changelog

All notable changes to Fantastic-Probe are documented here.

---

## [1.3.0] - 2026-06-20

### Breaking Changes

- ffprobe prebuilt source switched to **BtbN/FFmpeg-Builds** (GPL build with libbluray + libdvdread)
- Self-hosted `ffprobe-prebuilt-v1.0` release deprecated; BtbN provides daily auto-builds, more reliable
- Default branch migrated from `master` to `main`

### New Features

- **systemd timer support**: added `fantastic-probe.service` + `fantastic-probe.timer`, check status via `systemctl status`
- **Update backup/rollback**: `update.sh` auto-backs up to `/var/backups/fantastic-probe/` before upgrading, one-key rollback on failure
- **ffprobe download fallback**: when BtbN download fails, auto-guides to system ffprobe or manual config instead of silent failure
- **Daily failure stats**: cron and systemd timer now output a daily failure summary at 2 AM

### Improvements

- Removed ~250 lines of duplicated ffprobe install code in `fantastic-probe-install.sh`
- `fp-config.sh` `reconfigure_ffprobe` now uses BtbN download source
- Uninstall script additions: ffprobe cleanup, upload library cleanup, systemd service cleanup, data directory cleanup
- Default `STRM_ROOT` changed from `/mnt/sata1/media/媒体库/strm` to `/mnt/media/strm`
- Unified `set -euo pipefail` across all scripts
- crontab template fixes: added `root` user field, unified log path, added daily stats line
- `fp-config.sh` added `logs-clear` subcommand, fixed orphaned `clear_logs` function
- `update.sh` repo URL now configurable via `GITHUB_REPO` variable
- logrotate postrotate comment fixed to correct service name

### Fixed

- cron-scanner version fallback `4.2.2` -> `1.2.2`
- README branch references `master` -> `main`
- config.template STRM_ROOT default no longer uses Chinese path

---

## [1.2.2] - 2026-02-06

### New Features

- Automatic upload to cloud storage with configurable file types
- Directory-grouped upload with batch interval optimization
- Show-level file support for TV series metadata
- Real-time console feedback and progress display
- SQLite database for persistent upload status
- Config panel for upload management

---

## [1.2.1] - 2026-02-02

### Initial Release

- **Blu-ray ISO support**: Direct processing via ffprobe-libbluray
- **Dolby Vision detection**: Accurate Profile 7 recognition for BDMV dual-layer
- **Smart metadata extraction**: Duration, chapters, audio/subtitle languages via bd_list_titles
- **Emby integration**: Auto-refresh after processing
- **Cron scanner**: Periodic scanning mode for network mounts
- **Failure retry**: SQLite-based retry with configurable limits
- **Cloud-friendly**: Optimized for rclone mounts (115 Cloud, etc.)

### Technical Features

- ffprobe + libbluray for Blu-ray structure parsing
- bd_list_titles for main title and language tag extraction
- jq for efficient JSON processing
- FUSE mount detection with adaptive retry intervals
- Automatic mount point cleanup and error recovery

---
