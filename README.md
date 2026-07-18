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

## Community Applications (possible future)

The plugin installs fine from the `.plg` URL above and doesn't need
[Community Applications](https://ca.unraid.net/submit) to work — CA is a
discovery channel, not an install requirement. Listing it there is a
possibility once the plugin has been validated on real hardware.

Requirements, if it's ever pursued: an OSI-approved license (satisfied — MIT),
2FA on the GitHub account, a `ca_profile.xml` and a `plugins/*.xml` wrapper at
the repo root whose `<PluginURL>` matches the plg's `pluginURL` exactly, and
ideally an Unraid forum support topic. CA policy also discourages
proof-of-concept submissions and holds plugins to a stricter bar than Docker
apps, since plugins run as root — so hardware validation should come first.

## License

This project is licensed under the [MIT License](LICENSE) — fork and modify
it freely, but keep the copyright notice in copies you distribute.

The plugin also redistributes the `asterctl` / `aster-sysinfo` binaries from
[aoostar-rs](https://github.com/zehnm/aoostar-rs), which are covered by their
own upstream license, not this one. See
[`unraid-plugin/THIRD-PARTY-NOTICES.md`](unraid-plugin/THIRD-PARTY-NOTICES.md).
