# AOOSTAR WTR MAX display on Unraid

Native Unraid plugin that drives the integrated case LCD of the AOOSTAR
WTR MAX (and GEM12+ PRO) using the open-source
[aoostar-rs](https://github.com/zehnm/aoostar-rs) driver — no vendor
software required.

- **[`unraid-plugin/`](unraid-plugin/)** — the plugin (`aoostar-lcd.plg`),
  its sources, and full install/customization docs. Ships a custom
  "Unraid Dark" panel: CPU/GPU utilization + die temperature with
  green/amber/red thresholds, network speeds with history sparklines, RAM, clock, and a disk
  strip that flips to a red alert when a disk runs hot (temperatures from
  Unraid itself — spun-down disks are never woken).
- **`WTR MAX+GEM12+ PRO Screen Software/`** — AOOSTAR's official software
  (git-ignored; see its README for download links).

## Quick start

```sh
scp unraid-plugin/aoostar-lcd.plg root@<server>:/boot/config/plugins/
ssh root@<server> mkdir -p /boot/config/plugins/aoostar-lcd/packages
scp unraid-plugin/asterctl-*.tar.gz root@<server>:/boot/config/plugins/aoostar-lcd/packages/
ssh root@<server> "plugin install /boot/config/plugins/aoostar-lcd.plg"
```

Then configure at *Settings → Utilities → AOOSTAR LCD*.
