# Fantastic-Probe

Automatic media information extraction service for Emby STRM files. Extracts video/audio/subtitle metadata directly from Blu-ray ISO/BDMV and DVD ISO files, with accurate Dolby Vision and HDR detection.

## How It Works

```text
.iso.strm file  -->  cron/systemd scanner  -->  ffprobe (bluray:/dvd: protocol)  -->  *-mediainfo.json  -->  Emby refresh
```

1. The scanner finds `.iso.strm` files under the configured STRM root directory
2. Each `.iso.strm` file contains a path to a Blu-ray or DVD ISO (one line)
3. ffprobe reads the ISO directly via `bluray:` or `dvd:` protocol, extracting format, streams, chapters, HDR metadata
4. Output is written as `*-mediainfo.json` next to the `.iso.strm` file
5. Emby is notified to refresh the media library (optional, configurable)

## Requirements

- Linux (Debian/Ubuntu, RHEL/CentOS/Fedora, Arch, openSUSE)
- Root access
- Internet access (for initial ffprobe download from BtbN/FFmpeg-Builds)

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/qzov/fantastic-probe/main/install.sh | sudo bash
```

Or with wget:

```bash
wget -qO- https://raw.githubusercontent.com/qzov/fantastic-probe/main/install.sh | sudo bash
```

The installer will:

1. Detect your Linux distribution and package manager
2. Install dependencies (jq, sqlite3, python3, libbluray-bin)
3. Download ffprobe from BtbN/FFmpeg-Builds (GPL build with libbluray + libdvdread)
4. Walk through configuration (STRM directory, Emby integration)
5. Set up the scheduler (systemd timer or cron)

## Manual Install

```bash
git clone https://github.com/qzov/fantastic-probe.git
cd fantastic-probe
sudo bash fantastic-probe-install.sh
```

## STRM File Format

A `.iso.strm` file is a plain text file containing one line: the absolute path to a Blu-ray or DVD ISO file.

Example `/mnt/media/strm/movies/Inception.2010.iso.strm`:

```text
/mnt/cloud/movies/Inception.2010.BluRay.iso
```

The scanner detects the ISO type from the filename:

- Contains `bluray` or `bdmv` -> `bluray:` protocol
- Contains `dvd` -> `dvd:` protocol
- Otherwise defaults to `bluray:` (statistical priority)

## Output Format

After processing, a JSON file is generated alongside the STRM file:

```text
/mnt/media/strm/movies/
  Inception.2010.iso.strm
  Inception.2010.iso-mediainfo.json   <-- generated
```

The JSON format is Emby-compatible and includes:

| Field            | Description                                               |
|------------------|-----------------------------------------------------------|
| `MediaStreams`   | Video, audio, subtitle streams with codec, language, bitrate |
| `Chapters`       | Chapter markers with timestamps                           |
| `VideoRangeType` | SDR, HDR10, HDR10+, DolbyVision, HLG                     |
| `Duration`       | Total runtime in ticks and human-readable format          |
| `Container`      | Blu-ray, DVD                                              |

## Configuration

All settings live in `/etc/fantastic-probe/config`. Manage via:

```bash
sudo fp-config
```

### Interactive Menu

```bash
sudo fp-config          # Interactive menu with all options
sudo fp-config show     # View current configuration
sudo fp-config ffprobe  # Change ffprobe path
sudo fp-config strm     # Change STRM root directory
sudo fp-config emby     # Configure Emby integration
sudo fp-config edit     # Edit config file directly
```

### Key Configuration Variables

| Variable               | Default                       | Description                                 |
|------------------------|-------------------------------|---------------------------------------------|
| `STRM_ROOT`            | `/mnt/media/strm`             | Root directory containing `.iso.strm` files |
| `FFPROBE`              | `/usr/local/bin/ffprobe`      | Path to ffprobe binary                       |
| `FFPROBE_TIMEOUT`      | `300`                         | Seconds before ffprobe command times out     |
| `MAX_FILE_PROCESSING_TIME` | `600`                     | Total seconds allowed per file               |
| `EMBY_ENABLED`         | `false`                       | Enable Emby library refresh                  |
| `EMBY_URL`             | (empty)                       | Emby server URL (e.g. `http://127.0.0.1:8096`) |
| `EMBY_API_KEY`         | (empty)                       | Emby API key                                 |
| `AUTO_UPLOAD_ENABLED`  | `false`                       | Auto-upload JSON to network storage          |
| `UPLOAD_FILE_TYPES`    | `json`                        | File types to upload (comma-separated)       |

### Cron Scanner Tuning

| Variable               | Default | Description                                     |
|------------------------|---------|-------------------------------------------------|
| `CRON_MAX_RETRY_COUNT` | `3`     | Stop retrying after this many failures          |
| `CRON_SCAN_BATCH_SIZE` | `10`    | Max files to process per scan cycle             |

## Service Management

### systemd (recommended)

```bash
systemctl status fantastic-probe.timer    # Check timer status
systemctl start fantastic-probe.service   # Trigger a scan immediately
journalctl -u fantastic-probe.service -f  # Follow logs
```

### Cron

```bash
tail -f /var/log/fantastic_probe.log      # Follow logs
fp-config failure-list                     # View failed files
fp-config failure-clear                    # Clear failure cache
```

### Common Commands

```bash
fp-config restart       # Restart service (clears locks, resets cache)
fp-config status        # Check service status
fp-config deps          # Show dependency status
fp-config logs          # View live logs
fp-config logs-error    # View error logs only
fp-config logs-clear    # Clear log files
fp-config failure-reset '/path/to/file.iso.strm'  # Reset single file
```

## Update

```bash
sudo bash update.sh
```

Updates create a backup at `/var/backups/fantastic-probe/` before applying. If the update fails:

```bash
sudo bash update.sh --rollback /var/backups/fantastic-probe/<version>_<timestamp>
```

To check for updates without installing:

```bash
fp-config check-update
```

## Uninstall

```bash
sudo bash fantastic-probe-uninstall.sh
```

Removes all scripts, cron/systemd entries, cached binaries. Optionally keeps configuration and logs.

## Log Files

| File                                      | Content                                 |
|-------------------------------------------|-----------------------------------------|
| `/var/log/fantastic_probe.log`            | All scanner activity                    |
| `/var/log/fantastic_probe_errors.log`     | Errors only                             |
| `/var/log/fantastic_probe_upload.log`     | Upload operations (if enabled)          |

Logs rotate automatically at 1MB (via logrotate).

## Data Files

| Path                                          | Content                        |
|-----------------------------------------------|--------------------------------|
| `/var/lib/fantastic-probe/failure_cache.db`   | Failed file retry tracking     |
| `/var/lib/fantastic-probe/upload_cache.db`    | Upload status tracking         |
| `/usr/share/fantastic-probe/static/`          | Cached ffprobe binary archive  |

## Troubleshooting

### ffprobe fails to execute

The BtbN ffprobe binary may require additional runtime libraries. Check:

```bash
ldd /usr/local/bin/ffprobe | grep "not found"
```

Install missing libraries with your package manager, or reconfigure to use system ffprobe:

```bash
fp-config ffprobe   # Select option 2 (system ffprobe)
```

### Scanner runs but no JSON is generated

1. Check the STRM file content is a valid ISO path: `cat /path/to/file.iso.strm`
2. Verify the ISO exists and is accessible: `ls -la $(cat /path/to/file.iso.strm)`
3. Check error logs: `fp-config logs-error`
4. Look for "permanently failed" files: `fp-config failure-list`

### STRM root directory not found

The default path (`/mnt/media/strm`) likely does not exist. Set it during install or via:

```bash
fp-config strm
```

### Emby not refreshing after processing

1. Verify `EMBY_ENABLED=true` in `/etc/fantastic-probe/config`
2. Verify `EMBY_URL` and `EMBY_API_KEY` are set correctly
3. Test connectivity: `curl -s "$EMBY_URL/System/Info?api_key=$EMBY_API_KEY"`

### Cloud storage (rclone/FUSE) mount issues

The scanner detects FUSE mounts and applies adaptive retry intervals. If scans are slow:

- Increase `CRON_SCAN_BATCH_SIZE` to process fewer files per cycle (reduces I/O pressure)
- Increase `FFPROBE_TIMEOUT` if ISOs are on high-latency storage

## License

MIT - see [LICENSE](LICENSE) for details.
