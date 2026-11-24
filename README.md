# mainsail-kiln

> **Parts:** the printers, boards, readers and other gear that go with this project are listed at [projects.die-hard.net/gear](https://projects.die-hard.net/gear) (Amazon affiliate links).

A [Kiln OS](https://github.com/djvalic/kiln-os) plugin for the Flashforge
AD5X that runs [Mainsail](https://github.com/mainsail-crew/mainsail) next
to Fluidd:

| Port | Web interface |
|---|---|
| 80 (`http://<printer>/`) | Mainsail |
| 81 (`http://<printer>:81/`) | Fluidd |

> **Needs Kiln OS 1.0 or later (plugin API 1.6).** Version 2.0 uses
> Kiln's own root scripts, boot hooks and extra nginx servers for
> plugins. On Kiln v0.0.x, use the `kiln-v0` branch (1.x, the
> `screen.conf` hook).
> Coming from 1.x? See "Moving from 1.x" below.

Both talk to the same Moonraker and Klipper and show the same cameras
(`/webcam/`, ...) and touch screen view (`/screen/`). Settings are kept
separately: each UI has its own.

Mainsail is updated from the web UI (Software Updates, `mainsail`), like
Kiln's own Fluidd.

## Swapping the ports: `WEB`

Run `WEB` in the console to swap the two: Fluidd on port 80, Mainsail on
port 81. Run it again to swap back. nginx reloads with the new order
within about 3 seconds, so reload the page. The choice is kept across
reboots (`web_port80` in `variables.cfg`).

## Install

The plugin has a root part (`root/`) that switches nginx; Kiln asks
before it runs anything as root. It isn't in Kiln's plugin catalog yet,
so clone it over SSH (Kiln's default password is `root`):

```sh
cd /data/ad5x/plugins
su klipper -s /bin/sh -c 'git clone https://github.com/DIEHARDave/mainsail-kiln.git mainsail'
```

Then in the console (Fluidd or HelixScreen):

```
ENABLE_PLUGIN NAME=mainsail ROOT=1
```

`ROOT=1` is your consent to run `root/install.sh` as root; read `root/`
first if you like. It downloads the latest Mainsail release (about 3 MB)
into `/data/ad5x/web/mainsail` and switches nginx over: Mainsail is on
port 80 as soon as it finishes. Kiln then enables the plugin and
restarts Klipper. After a Moonraker restart (or the next boot), Software
Updates lists `mainsail` (the UI) and `mainsail-kiln` (this plugin). The
plugin also adds pass-through `PAUSE` / `RESUME` macros, because
Mainsail warns without them.

## Updates

- **Mainsail:** Software Updates > `mainsail`.
- **This plugin:** Software Updates > `mainsail-kiln`, then `RESTART`
  Klipper: when `root/` changed, Kiln runs `root/update.sh` by itself
  (you agreed to that with `ROOT=1`).

On the `kiln-v1` branch from the Kiln 1.0 test builds? Switch the clone
to `main`, or Software Updates marks it invalid:
`su klipper -s /bin/sh -c 'git -C /data/ad5x/plugins/mainsail checkout main'`.

## Moving from 1.x

1.x installed its root part by hand (`sh install.sh` over SSH, a line in
`/data/ad5x/screen.conf`) and ran nginx from its own copy of Kiln's
config. After updating to 2.0 Kiln warns that the plugin "got root
scripts": run

```
DISABLE_PLUGIN NAME=mainsail
ENABLE_PLUGIN NAME=mainsail ROOT=1
```

`root/install.sh` removes the old `screen.conf` line,
`/data/ad5x/mainsail-hook.sh` and the old watcher, and moves nginx back
to Kiln's own config with the second UI added. The `WEB` choice stays.

## Renamed for Kiln OS 1.0

This repository was `KILN_Mainsail` until 2026-11-15; old links and clones keep
working (GitHub redirects them), and Moonraker switches an installed
copy to the new address by itself at its next update check.

Kiln OS 1.0 keeps names that start with `kiln` for itself, so the
Software Updates entry is now `mainsail-kiln` (was `kiln-mainsail`). Nothing else
changes. It shows under the new name after the next update and
Moonraker restart.

## How it works

Kiln's `nginx.conf` sits on the read-only system partition and serves
port 80 from the folder named in `/run/nginx/fluidd-root.conf` (written
at boot). It also reads root-owned extra servers from
`/data/ad5x/nginx/*.conf`. Kiln's plugin API 1.6 copies the plugin's
`root/` to `/data/ad5x/plugins-root/mainsail` (root-owned, so root never
runs code from the clone user `klipper` can change) and runs it from
there:

- `install.sh` (at `ENABLE_PLUGIN ... ROOT=1`) and `update.sh` (after an
  update that changed `root/`) put the boot script `S50mainsail` into
  `/data/ad5x/plugins-root/init.d` and start it.
- `S50mainsail` runs at every boot, a minute or so after the touch
  screen (`S69ad5x-plugin-boot`). Until then Fluidd is on both ports.
- `uninstall.sh` (at `DISABLE_PLUGIN` / `REMOVE_PLUGIN`) puts Kiln's own
  setup back: Fluidd on port 80, nothing on 81.

`mainsail-hook.sh start`:

1. writes `/data/ad5x/nginx/mainsail.conf`: Kiln's port 80 server block
   copied, on port 81, with the other UI's folder. Every location
   (Moonraker API, websocket, webcams, screen) comes from Kiln's file, so
   a Kiln update that changes it is picked up at the next boot. It also
   includes `/data/ad5x/nginx/port81.d/*.conf`, so other plugins can add
   pages to port 81 ([diehard-pushraker](https://github.com/DIEHARDave/diehard-pushraker)'s
   settings page).
2. points `fluidd-root.conf` at Mainsail (Kiln's own Fluidd line is kept
   for port 81 and for `off`).
3. checks the result with `nginx -t` and reloads Kiln's nginx. If the
   check fails, both files go back as they were.

When `WEB` has saved `web_port80 = 'fluidd'`, the two are swapped: port
80 keeps Kiln's Fluidd line, port 81 gets Mainsail. The macro runs as
user `klipper` and can't touch nginx, so the hook also starts a small
root watcher (`mainsail-hook.sh watch`) that checks `variables.cfg`
every 3 seconds and rebuilds the files when the value changes. The file
is only parsed, never run.

**Kiln OS updates in Mainsail.** Kiln lists its own updates (`Kiln OS`,
`klipper`, `moonraker`) under types Mainsail doesn't know, so plain
Mainsail hides them; Fluidd shows them. The hook patches Mainsail's
bundle in place so it lists them like any web client: version, Update
button, release link. The watcher patches again after a Mainsail update.
The service worker gets a new revision for the patched file, and on
port 81 Mainsail's `/assets/` are revalidated instead of cached for 30
days, so browsers load the patched file. If a Mainsail release changes
that code, the patch is skipped and `/var/log/messages` says so.

If Kiln's nginx.conf ever changes shape, or the check fails, nothing is
switched: Fluidd stays on port 80, and `/var/log/messages` has a
`kiln-mainsail` line saying why. The root scripts log to
`/data/ad5x/kiln-log/plugins-root.log`.

## Uninstall

```
REMOVE_PLUGIN NAME=mainsail
```

(or `DISABLE_PLUGIN NAME=mainsail` to keep the clone). Kiln runs
`root/uninstall.sh` first: Fluidd is back on port 80 right away.
Mainsail's files stay in `/data/ad5x/web/mainsail`; delete them as root
if you like.

## License

GPLv3, like Klipper and Kiln OS. Mainsail itself is GPLv3, by the
Mainsail crew.
