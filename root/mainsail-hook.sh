#!/bin/sh
#####################################################################
# mainsail-kiln root part: Mainsail on port 80, Fluidd on port 81
# (or the other way round: WEB swaps them). Kiln OS plugin API 1.6 runs
# it as root from root's copy of root/ (/data/ad5x/plugins-root/mainsail),
# never from the clone user klipper owns:
#   mainsail-hook.sh start   boot script S50mainsail (and install.sh)
#   mainsail-hook.sh stop    stops the watcher (nginx keeps its config)
#   mainsail-hook.sh off     Kiln's own setup back: Fluidd on 80 only
#   mainsail-hook.sh watch   the watcher
#
# Kiln's nginx.conf (read-only image) serves port 80 with the root in
# /run/nginx/fluidd-root.conf (S61ad5x-web writes it at boot) and
# includes root-owned extra servers from /data/ad5x/nginx/*.conf. This
# hook:
#   - writes /data/ad5x/nginx/mainsail.conf: Kiln's port 80 server block
#     copied, on port 81, with the other UI's root. All of Kiln's
#     locations (Moonraker API, websocket, webcams, screen) stay.
#   - points fluidd-root.conf at the UI for port 80 (Kiln's own line is
#     kept in /run/kiln-mainsail.fluidd-root for port 81 and "off")
#   - checks the result with "nginx -t" and reloads Kiln's nginx; if the
#     check fails, both files go back as they were.
#
# The WEB macro (plugin.cfg) saves web_port80 = 'mainsail' or 'fluidd' in
# Klipper's variables.cfg. That file is writable by user klipper: it is
# parsed, never sourced. 'fluidd' swaps the two roots (Fluidd on 80,
# Mainsail on 81). The watcher applies a change within about 3 s.
#
# Kiln OS's own update entries ("Kiln OS", klipper, moonraker) have
# configured_type kiln_os / kiln_app. Fluidd lists any type, Mainsail
# drops the ones it doesn't know. ms_patch edits Mainsail's bundle so it
# stores them as web entries (version > version, Update button, release
# link from remote_url). Mainsail's own updates replace the bundle: the
# watcher patches the new one (index.html's inode changes). Mainsail on
# port 81 revalidates /assets/ instead of caching them for 30 days, and
# the service worker gets a new revision for the patched file, so
# browsers pick it up.
#####################################################################

MS_HOOK_VERSION=5

MS_ROOT=/data/ad5x/web/mainsail
MS_KILN_CONF=/etc/nginx/nginx.conf
MS_EXTRA_DIR=/data/ad5x/nginx
MS_EXTRA=$MS_EXTRA_DIR/mainsail.conf
MS_ROOTFILE=/run/nginx/fluidd-root.conf
MS_KILN_ROOT=/run/kiln-mainsail.fluidd-root
MS_OLD_CONF=/run/nginx/kiln-mainsail.conf
MS_PID=/run/nginx/nginx.pid
MS_NGINX=/usr/sbin/nginx
MS_SERVICE=/etc/init.d/S63nginx
MS_VARS=/home/klipper/printer_data/config/variables.cfg
MS_HOOK=/data/ad5x/plugins-root/mainsail/mainsail-hook.sh
MS_WATCH_PID=/run/kiln-mainsail-watch.pid
MS_PATCHED=/run/kiln-mainsail.patched

ms_log() { logger -t kiln-mainsail "$*"; }

# Mainsail's update store: let it keep Kiln's update entries. In the
# minified bundle the line is
#   if([`web`,`web_beta`,`python`,`executable`].includes(o)){await
#   e(`storeWebRepo`,{...a,name:t});continue}
# (names change per build); a kiln_os / kiln_app branch goes in front.
# Files stay owned by klipper (rewritten in place), so Moonraker can
# still update Mainsail. Once per bundle: MS_PATCHED holds index.html's
# inode. A bundle still being unpacked (Mainsail update) gets 10 tries.
ms_tries=0
ms_patch() {
	ms_ino=$(ls -i $MS_ROOT/index.html 2>/dev/null | awk '{print $1}')
	[ -n "$ms_ino" ] || return
	[ "$(cat $MS_PATCHED 2>/dev/null)" = "$ms_ino" ] && return
	ms_js=$(grep -l 'storeWebRepo`,{' $MS_ROOT/assets/*.js 2>/dev/null | head -n 1)
	if [ -z "$ms_js" ]; then
		ms_tries=$((ms_tries + 1))
		[ $ms_tries -lt 10 ] && return
		ms_log "Mainsail's update store not found: Kiln OS updates not listed"
		echo "$ms_ino" > $MS_PATCHED; ms_tries=0; return
	fi
	echo "$ms_ino" > $MS_PATCHED; ms_tries=0
	grep -q '`kiln_os`' "$ms_js" && return
	ms_id='([A-Za-z_$][A-Za-z0-9_$]*)'
	sed -E 's/if\(\[`web`,`web_beta`,`python`,`executable`\]\.includes\('"$ms_id"'\)\)\{await '"$ms_id"'\(`storeWebRepo`,\{\.\.\.'"$ms_id"',name:'"$ms_id"'\}\);continue\}/if([`kiln_os`,`kiln_app`].includes(\1)){let kiln_u=(\3.remote_url||``).split(`\/`);await \2(`storeWebRepo`,{owner:kiln_u[3],repo_name:kiln_u[4],...\3,configured_type:`web`,name:\4});continue}&/' \
		"$ms_js" > "$ms_js.kiln"
	if grep -q '`kiln_os`' "$ms_js.kiln"; then
		cat "$ms_js.kiln" > "$ms_js"
		# the service worker caches the file by name (revision null): a
		# revision makes browsers fetch the patched copy
		ms_f=assets/${ms_js##*/}
		if [ -f $MS_ROOT/sw.js ]; then
			sed "s|url:\"$ms_f\",revision:null|url:\"$ms_f\",revision:\"kiln-$ms_ino\"|" \
				$MS_ROOT/sw.js > $MS_ROOT/sw.js.kiln
			cat $MS_ROOT/sw.js.kiln > $MS_ROOT/sw.js
			rm -f $MS_ROOT/sw.js.kiln
		fi
		ms_log "Mainsail patched: lists Kiln OS updates"
	else
		ms_log "Mainsail's update store changed shape: Kiln OS updates not listed"
	fi
	rm -f "$ms_js.kiln"
}

# nginx runs from the 1.x hook's own copy of the config
ms_old_running() {
	[ -f $MS_PID ] &&
		tr '\0' ' ' < /proc/$(cat $MS_PID)/cmdline 2>/dev/null |
		grep -q -- "-c $MS_OLD_CONF"
}

ms_nginx_running() {
	[ -f $MS_PID ] && kill -0 "$(cat $MS_PID)" 2>/dev/null
}

# The UI that WEB put on port 80: fluidd or mainsail (the default)
ms_port80() {
	ms_v=$(awk -F' = ' '$1 == "web_port80" {
		v = $2; gsub(/^["\047]|["\047]$/, "", v); print v; exit
	}' $MS_VARS 2>/dev/null)
	[ "$ms_v" = fluidd ] && echo fluidd || echo mainsail
}

# Kiln's own root line for port 80 (Fluidd), saved the first time
ms_kiln_root() {
	if [ ! -s $MS_KILN_ROOT ]; then
		if [ -f $MS_ROOTFILE ] && ! grep -q "$MS_ROOT" $MS_ROOTFILE; then
			cp $MS_ROOTFILE $MS_KILN_ROOT
		elif [ -f /data/ad5x/web/fluidd/index.html ]; then
			echo "root /data/ad5x/web/fluidd;" > $MS_KILN_ROOT
		else
			echo "root /usr/share/fluidd;" > $MS_KILN_ROOT
		fi
	fi
	cat $MS_KILN_ROOT
}

# ms_build UI: $MS_EXTRA.new (port 81, the other UI) and
# $MS_ROOTFILE.new (port 80, UI)
ms_build() {
	ms_fluidd=$(ms_kiln_root)
	if [ "$1" = fluidd ]; then
		echo "$ms_fluidd" > $MS_ROOTFILE.new
		ms_r81="root $MS_ROOT;"; ms_m81=1
	else
		echo "root $MS_ROOT;" > $MS_ROOTFILE.new
		ms_r81=$ms_fluidd; ms_m81=0
	fi
	awk -v r81="$ms_r81" -v m81=$ms_m81 '
	BEGIN {
		print "# mainsail-kiln (root): the second web UI on port 81, a copy of"
		print "# Kiln OS port 80 server. The plugin rewrites it: do not edit."
	}
	!done && /^[ \t]*server[ \t]*\{/ { inblk = 1 }
	inblk {
		l = $0
		if (l ~ /include[ \t]+\/run\/nginx\/fluidd-root\.conf;/) {
			sub(/include.*/, r81, l); found_root = 1
		}
		if (sub(/listen[ \t]+80[ \t]+default_server;/, "listen 81;", l))
			found_listen = 1
		# Mainsail assets revalidated (304s), not cached 30 days:
		# browsers get the bundle ms_patch rewrote under the same name
		if (m81 && l ~ /expires[ \t]+30d;/)
			sub(/expires.*/, "add_header Cache-Control \"no-cache\";", l)
		print l
		line = $0; sub(/#.*/, "", line)
		depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
		if (depth == 0) { inblk = 0; done = 1 }
	}
	END { if (!found_root || !found_listen) exit 1 }
	' $MS_KILN_CONF > $MS_EXTRA.new
}

# Kiln's nginx with the current files: reload it, or start it (instead
# of the 1.x hook's copy, or when it doesn't run)
ms_reload() {
	if ms_old_running; then
		start-stop-daemon -K -q -p $MS_PID
		sleep 1
		rm -f $MS_OLD_CONF
		$MS_SERVICE start
	elif ms_nginx_running; then
		$MS_SERVICE reload
	else
		$MS_SERVICE start
	fi
}

# ms_apply: the .new files in place, nginx -t, reload. On failure the
# old files go back.
ms_apply() {
	for ms_f in $MS_EXTRA $MS_ROOTFILE; do
		rm -f $ms_f.old
		[ -f $ms_f ] && cp -p $ms_f $ms_f.old
		chmod 644 $ms_f.new
		mv $ms_f.new $ms_f
	done
	if ! $MS_NGINX -t -q 2>/dev/null; then
		for ms_f in $MS_EXTRA $MS_ROOTFILE; do
			if [ -f $ms_f.old ]; then mv $ms_f.old $ms_f; else rm -f $ms_f; fi
		done
		ms_log "nginx -t failed on the new config: nginx left as it was"
		return 1
	fi
	rm -f $MS_EXTRA.old $MS_ROOTFILE.old
	ms_reload
}

ms_on() {
	[ -f $MS_ROOT/index.html ] || { ms_log "no Mainsail in $MS_ROOT"; return; }
	ms_patch
	mkdir -p /run/nginx $MS_EXTRA_DIR
	chmod 755 $MS_EXTRA_DIR
	ms_ui=$(ms_port80)
	if ! ms_build $ms_ui; then
		ms_log "Kiln's nginx.conf changed shape: Fluidd stays on port 80"
		rm -f $MS_EXTRA.new $MS_ROOTFILE.new; return
	fi
	if ! ms_old_running && ms_nginx_running &&
	   cmp -s $MS_EXTRA.new $MS_EXTRA && cmp -s $MS_ROOTFILE.new $MS_ROOTFILE; then
		rm -f $MS_EXTRA.new $MS_ROOTFILE.new; return
	fi
	ms_apply || return
	if [ $ms_ui = fluidd ]; then
		ms_log "Fluidd on port 80, Mainsail on port 81"
	else
		ms_log "Mainsail on port 80, Fluidd on port 81"
	fi
}

ms_watch() {
	ms_last=$(ms_port80)
	while sleep 3; do
		ms_patch
		ms_now=$(ms_port80)
		[ "$ms_now" = "$ms_last" ] && continue
		ms_last=$ms_now
		ms_on
	done
}

ms_watch_stop() {
	start-stop-daemon -K -q -p $MS_WATCH_PID 2>/dev/null
	rm -f $MS_WATCH_PID
}

ms_off() {
	ms_watch_stop
	rm -f $MS_EXTRA
	[ -s $MS_KILN_ROOT ] && cp $MS_KILN_ROOT $MS_ROOTFILE
	rm -f $MS_KILN_ROOT
	ms_reload
	ms_log "Kiln's nginx back: Fluidd on port 80"
}

case "$1" in
off) ms_off ;;
stop) ms_watch_stop ;;
watch) ms_watch ;;
start)
	ms_on
	ms_nginx_running || $MS_SERVICE start
	if ! { [ -f $MS_WATCH_PID ] && kill -0 "$(cat $MS_WATCH_PID)" 2>/dev/null; }; then
		start-stop-daemon -S -b -m -p $MS_WATCH_PID -x /bin/sh -- $MS_HOOK watch
	fi
	;;
*)
	echo "usage: $0 start|stop|off|watch"
	exit 1
	;;
esac
exit 0
