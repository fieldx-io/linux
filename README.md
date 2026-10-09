# FieldX Linux

FieldX Linux agent for Debian/Ubuntu.

## Install (amd64 / x86_64)

```bash
curl -fsSL https://raw.githubusercontent.com/fieldx-io/linux/main/install.sh | sudo bash -s -- --org ORG_CODE --access ACCESS_CODE
```

Get org and access codes from the FieldX admin portal (same enrol as iOS).

The installer downloads `fieldx_amd64.deb` (SHA256 verified), installs the package, enrols, and starts `fieldx.service`. No 7z / p7zip.

ARM64 package is not published yet.

Reach out to support@fieldx.io for further queries.
