#!/bin/bash
# aoostar-lcd plugin removal script
PLUGIN="aoostar-lcd"
FLASH="/boot/config/plugins/$PLUGIN"

/usr/local/emhttp/plugins/$PLUGIN/scripts/rc.aoostar-lcd stop 2>/dev/null

rm -rf /usr/local/emhttp/plugins/$PLUGIN
rm -rf /usr/local/aoostar-lcd
rm -rf /run/aoostar-lcd /var/log/aoostar-lcd
rm -f /var/run/$PLUGIN-sysinfo.pid /var/run/$PLUGIN-asterctl.pid

# drop the daily on/off schedule and rebuild root's crontab without it
rm -f /etc/cron.d/$PLUGIN
[ -x /usr/local/sbin/update_cron ] && /usr/local/sbin/update_cron 2>/dev/null

# remove settings and cached packages, but keep the user's panel
# configuration (cfg/) in case they reinstall
rm -f "$FLASH/$PLUGIN.cfg"
rm -rf "$FLASH/packages"
rmdir "$FLASH" 2>/dev/null

echo "aoostar-lcd plugin removed."
echo "Note: your panel configuration in $FLASH/cfg (if any) was kept -"
echo "delete it manually if you no longer want it."
