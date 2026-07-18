#!/bin/bash
# aoostar-lcd plugin post-install script (runs at every install, incl. each boot)
PLUGIN="aoostar-lcd"
FLASH="/boot/config/plugins/$PLUGIN"
CFG="$FLASH/$PLUGIN.cfg"

mkdir -p "$FLASH/packages"

# create default settings once; never overwrite user settings
if [ ! -f "$CFG" ]; then
  cat > "$CFG" <<'CFGEOF'
SERVICE="enabled"
NETIF="br0"
REFRESH="3"
DISKREFRESH="1800"
SMARTCTL="no"
CPU_TEMP_WARN="70"
CPU_TEMP_HOT="85"
HDD_HOT="45"
SSD_HOT="60"
CPU_TEMP_SENSOR="auto"
CFGEOF
fi

# plugin page icon
mkdir -p /usr/local/emhttp/plugins/$PLUGIN/images
base64 -d > /usr/local/emhttp/plugins/$PLUGIN/images/aoostar-lcd.png <<'ICONEOF'
@ICON_B64@
ICONEOF

# install the asterctl package (from flash cache, or GitHub on first install)
# and start the service; failures are non-fatal - the user can retry from
# the settings page once network/package is available
/usr/local/emhttp/plugins/$PLUGIN/scripts/rc.aoostar-lcd start

echo ""
echo "----------------------------------------------------"
echo " aoostar-lcd plugin installed."
echo ""
echo " Settings page: Settings -> Utilities -> AOOSTAR LCD"
echo " Panel config:  $FLASH/cfg/monitor.json"
if ! ls "$FLASH"/packages/asterctl-*.tar.gz >/dev/null 2>&1; then
  echo ""
  echo " NOTE: asterctl package not cached yet. If the download"
  echo " failed (no internet), copy an asterctl release tarball to:"
  echo "   $FLASH/packages/"
  echo " from https://github.com/zehnm/aoostar-rs/releases"
  echo " then click Start on the settings page."
fi
echo "----------------------------------------------------"
