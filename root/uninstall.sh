#!/bin/sh
# mainsail-kiln: undo install.sh. Kiln runs it (root's copy) at
# DISABLE_PLUGIN / REMOVE_PLUGIN, then deletes root's copy and the boot
# script. Kiln's own nginx comes back: Fluidd on port 80. Mainsail's
# files stay in /data/ad5x/web/mainsail (delete them by hand if you like).
/bin/sh ./mainsail-hook.sh off
echo "mainsail-kiln: root part removed; Fluidd on port 80"
exit 0
