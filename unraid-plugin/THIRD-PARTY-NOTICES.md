# Third-party notices

This plugin redistributes third-party software. Those components keep their
own licenses. They are **not** covered by this repository's own
[LICENSE](../LICENSE).

---

## asterctl / aster-sysinfo (aoostar-rs)

- **Bundled as:** `asterctl-v0.2.0-6-g2f4d959-Linux-x64.tar.gz`
- **Upstream:** <https://github.com/zehnm/aoostar-rs>
- **Binaries installed:** `asterctl`, `aster-sysinfo`, plus the `cfg/` defaults
  and systemd units contained in the tarball
- **sha256:** recorded in [`README.md`](README.md)

Upstream is dual-licensed "at your option" under the Apache License 2.0 or the
MIT License. **This distribution elects the MIT License.**

The full license text is in
[`src/plugin-root/LICENSE-asterctl.txt`](src/plugin-root/LICENSE-asterctl.txt)
— that file is the single source of truth, reproduced verbatim from upstream's
[`LICENSE-MIT`](https://github.com/zehnm/aoostar-rs/blob/main/LICENSE-MIT). It
is not duplicated here so the two copies cannot drift apart.

Note: the upstream `LICENSE-MIT` carries no copyright line. It is reproduced
as-published, unmodified. Copyright is held by the aoostar-rs authors.

### How the notice reaches end users

MIT requires its notice to travel with every copy of the software, and the
upstream tarball ships no license file of its own. So:

1. `LICENSE-asterctl.txt` is embedded in `aoostar-lcd.plg` as a payload file
   and installed to `/usr/local/emhttp/plugins/aoostar-lcd/`.
2. `rc.aoostar-lcd` copies it to `/usr/local/aoostar-lcd/` immediately after
   extracting the tarball, so it sits beside the binaries. That directory is
   RAM and is repopulated on every boot, which is why the copy lives with the
   extraction rather than in `install.sh`.
3. `src/build.py` refuses to build if the license payload has lost its MIT
   grant text — an empty or truncated file would otherwise ship silently.

---

## Vendor software (not redistributed)

The AOOSTAR-X vendor package under `../WTR MAX+GEM12+ PRO Screen Software/`
is **not** redistributed by this repository — it is gitignored, and only a
README describing where to download it is tracked. No license is granted to
it here.
