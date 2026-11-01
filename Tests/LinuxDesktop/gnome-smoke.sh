#!/bin/sh
# Runs "Filevero --smoke-test" inside a headless GNOME Shell with Filevero's extension, so the GNOME bridge is exercised.
# Usage: gnome-smoke.sh FILEVERO_COMMAND SMOKE_DIRECTORY. Needs what Tests/GnomeExtension/run.sh needs.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/filevero-runtime} FILEVERO_COMMAND="$1" FILEVERO_SMOKE_DIRECTORY="$2"
mkdir -p -m 700 "$XDG_RUNTIME_DIR"
mkdir -p -m 1777 /tmp/.X11-unix
extensions=$HOME/.local/share/gnome-shell/extensions
mkdir -p "$extensions/filevero@serdarvaran.github.io" "$extensions/test-helper@filevero.test"
cp "$here"/../../windows/Filevero.Linux/gnome-extension/* "$extensions/filevero@serdarvaran.github.io/"
cp "$here"/../GnomeExtension/helper/* "$extensions/test-helper@filevero.test/"
mkdir -p /run/dbus
dbus-daemon --system --fork
python3 "$here/../GnomeExtension/logind.py" &
sleep 1
exec dbus-run-session -- sh -c '
  gsettings set org.gnome.shell disable-user-extensions false
  gsettings set org.gnome.shell enabled-extensions "[\"filevero@serdarvaran.github.io\", \"test-helper@filevero.test\"]"
  gnome-shell --headless --wayland --virtual-monitor 1600x1000 > /tmp/gnome-shell.log 2>&1 &
  for attempt in $(seq 1 120); do
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.NameHasOwner io.github.serdarvaran.Filevero.Shell 2>/dev/null | grep -q true && break
    sleep 0.5
  done
  # Mutter authorizes Xwayland clients through a file it names at startup.
  export XAUTHORITY=$(ls "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* | head -n1)
  XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 timeout 300 "$FILEVERO_COMMAND" --smoke-test'
