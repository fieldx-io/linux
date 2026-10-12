# FieldX Linux

FieldX Linux agent for Debian/Ubuntu.

## Install (amd64 / ARM64)

```bash
curl -fsSL https://raw.githubusercontent.com/fieldx-io/linux/main/install.sh | sudo bash -s -- --org ORG_CODE --access ACCESS_CODE
```

Get org and access codes from the FieldX admin portal (same enrol as iOS).

The installer detects your CPU (`x86_64` → `fieldx_amd64.deb`, `aarch64` → `fieldx_arm64.deb`), downloads the matching package from `manifest.json` (SHA256 verified), installs it, enrols, and starts `fieldx.service`. No 7z / p7zip.

### Already installed?

Run the same curl command again with new org/access codes to **re-enroll**, update the device token in `/var/lib/fieldx/config.json`, and restart the service (no uninstall needed).

## Uninstall

Removes the agent package, systemd service, config (`/var/lib/fieldx`), and logs (`/var/log/fieldx`). No org/access codes needed.

```bash
curl -fsSL https://raw.githubusercontent.com/fieldx-io/linux/main/install.sh | sudo bash -s -- --uninstall
```

Reach out to support@fieldx.io for further queries.
