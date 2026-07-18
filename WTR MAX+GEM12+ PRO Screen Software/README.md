# Vendor screen software (not committed)

This folder holds AOOSTAR's official screen software package, which is
git-ignored (large binaries, unclear redistribution rights). The Unraid
plugin in `../unraid-plugin/` does **not** need any of it — it uses the
open-source [aoostar-rs](https://github.com/zehnm/aoostar-rs) driver.
The vendor package is kept locally only as a reference/fallback.

## Where to download

- Official AOOSTAR drivers & systems page:
  <https://aoostar.com/pages/drives-systems>
  (look for the WTR MAX / GEM12+ PRO screen software, "AOOSTAR-X")
- AOOSTAR support's file share (linked from the aoostar-rs docs, hosts
  WTR MAX drivers and theme files): <http://pan.sztbkj.com:5244/>

## Expected contents (as of v1.3.6, January 2026)

- `AOOSTAR-X-Setup V1.3.6.exe` — Windows installer
- `AOOSTAR-X-linux  V1.3.6.zip` — Linux build (182 MB PyInstaller binary,
  systemd service scripts, it87 dkms package)
- `WTR MAX Screen Installation Guide(1).docx` — Windows install guide
- `使用说明.txt` — usage notes (includes the vendor's own Unraid
  User-Scripts workaround, plus default web UI credentials admin/123456
  on port 5123)
