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

## Install from the Unraid web UI (recommended)

No SSH needed. In the Unraid web UI:

1. Go to **Plugins → Install Plugin**.
2. Paste this URL into the box and click **Install**:

   ```
   https://raw.githubusercontent.com/miahyap/aoostar-wtr-max-display/main/unraid-plugin/aoostar-lcd.plg
   ```

3. Wait for the install log to finish, then go to
   **Settings → Utilities → AOOSTAR LCD** to configure and start it.

The `.plg` is self-contained; on first start the plugin downloads the
`asterctl` binary package from the
[aoostar-rs releases](https://github.com/zehnm/aoostar-rs/releases), verifies
its published checksum, and caches it on the flash drive so later reboots
work offline. **Your server needs internet access for that first start** — if
the download fails, the settings page will say so; copy a release tarball to
`/boot/config/plugins/aoostar-lcd/packages/` by hand and click **Start**.

Because the plg carries a `pluginURL`, Unraid's Plugins page will also show
updates for it and can self-update from the same URL.

## Quick start (SSH / fully offline)

```sh
scp unraid-plugin/aoostar-lcd.plg root@<server>:/boot/config/plugins/
ssh root@<server> mkdir -p /boot/config/plugins/aoostar-lcd/packages
scp unraid-plugin/asterctl-*.tar.gz root@<server>:/boot/config/plugins/aoostar-lcd/packages/
ssh root@<server> "plugin install /boot/config/plugins/aoostar-lcd.plg"
```

Staging the tarball first means the install never needs to reach GitHub.
Then configure at *Settings → Utilities → AOOSTAR LCD*.

## Community Applications (possible future)

The plugin installs fine from the `.plg` URL above and doesn't need
[Community Applications](https://ca.unraid.net/submit) to work — CA is a
discovery channel, not an install requirement. Listing it there is a
possibility, not a current goal. The plugin and its panel are confirmed
working on real WTR MAX hardware, so nothing technical blocks it.

Requirements, if it's ever pursued: an OSI-approved license (satisfied — MIT),
2FA on the GitHub account, a `ca_profile.xml` and a `plugins/*.xml` wrapper at
the repo root whose `<PluginURL>` matches the plg's `pluginURL` exactly, and
ideally an Unraid forum support topic. Note that CA holds plugins to a
stricter bar than Docker apps, since plugins run as root.

## License

This project is licensed under the [MIT License](LICENSE) — fork and modify
it freely, but keep the copyright notice in copies you distribute.

The plugin also redistributes the `asterctl` / `aster-sysinfo` binaries from
[aoostar-rs](https://github.com/zehnm/aoostar-rs), which are covered by their
own upstream license, not this one. See
[`unraid-plugin/THIRD-PARTY-NOTICES.md`](unraid-plugin/THIRD-PARTY-NOTICES.md).
