#!/bin/sh
# mainsail-kiln: root's part, Kiln OS plugin API 1.6. Kiln runs it as
# root from /data/ad5x/plugins-root/mainsail (root's copy of root/) at
#   ENABLE_PLUGIN NAME=mainsail ROOT=1
# and, as update.sh, after each update that changes root/.
#  1. downloads the latest Mainsail release into /data/ad5x/web/mainsail
#     (only when missing; Moonraker updates it after that, Software
#     Updates in Fluidd or Mainsail)
#  2. removes what mainsail-kiln before 2.0 installed by hand: the line
#     in /data/ad5x/screen.conf, /data/ad5x/mainsail-hook.sh, the old
#     watcher (nginx moves from the old hook's config copy to Kiln's own)
#  3. puts the boot script S50mainsail in place and runs it: Mainsail on
#     port 80, Fluidd on port 81 (or swapped, if WEB swapped them)
set -e
ROOTDIR=/data/ad5x/plugins-root
OLD_HOOK=/data/ad5x/mainsail-hook.sh
SCREEN=/data/ad5x/screen.conf
OLD_CONF=/data/ad5x/camera.conf
WEB=/data/ad5x/web/mainsail
URL=https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip

grep -qs 'include /data/ad5x/nginx/\*\.conf;' /etc/nginx/nginx.conf &&
	grep -qs fluidd-root.conf /etc/nginx/nginx.conf || {
	echo "install.sh: not the Kiln OS this was written for"
	echo "  (nginx.conf must include fluidd-root.conf and /data/ad5x/nginx/*.conf)"
	exit 1
}

if [ ! -f $WEB/index.html ]; then
	echo "downloading Mainsail ..."
	rm -rf $WEB.new
	python3 -I - "$URL" "$WEB.new" <<'EOF'
import io, sys, urllib.request, zipfile
data = urllib.request.urlopen(sys.argv[1], timeout=60).read()
zipfile.ZipFile(io.BytesIO(data)).extractall(sys.argv[2])
EOF
	[ -f $WEB.new/index.html ] || { echo "install.sh: download failed"; exit 1; }
	chown -R klipper:klipper $WEB.new
	mv $WEB.new $WEB
	echo "Mainsail $(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' $WEB/release_info.json) in $WEB"
fi
chmod -R a+rX $WEB

# the watcher (old or new) runs the old code: stop it, the hook starts
# the new one
start-stop-daemon -K -q -p /run/kiln-mainsail-watch.pid 2>/dev/null || true
rm -f /run/kiln-mainsail-watch.pid

for CONF in $SCREEN $OLD_CONF; do
	grep -qxF ". $OLD_HOOK" $CONF 2>/dev/null || continue
	sed -i -e '/^# KILN_Mainsail plugin/d' -e "\\|^\\. $OLD_HOOK\$|d" $CONF
	echo "removed the old hook line from $CONF"
	# nothing left but comments and blank lines: it was ours
	grep -qv '^[[:space:]]*\(#.*\)\{0,1\}$' $CONF || rm -f $CONF
done
rm -f $OLD_HOOK

mkdir -p $ROOTDIR/init.d
cp S50mainsail $ROOTDIR/init.d/S50mainsail.new
chmod 755 $ROOTDIR/init.d/S50mainsail.new
mv $ROOTDIR/init.d/S50mainsail.new $ROOTDIR/init.d/S50mainsail
$ROOTDIR/init.d/S50mainsail start
if [ -f /data/ad5x/nginx/mainsail.conf ]; then
	if grep -qs "^web_port80 = .fluidd" /home/klipper/printer_data/config/variables.cfg; then
		echo "Fluidd on port 80, Mainsail on port 81 (WEB swaps them)"
	else
		echo "Mainsail on port 80, Fluidd on port 81 (WEB swaps them)"
	fi
else
	echo "nginx not switched, Fluidd stays on port 80: see /var/log/messages (kiln-mainsail)"
fi
