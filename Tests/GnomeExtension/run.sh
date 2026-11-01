#!/bin/sh
# Runs Filevero's GNOME Shell extension in a headless GNOME Shell and drives it as the app would (test.py).
# Needs: gnome-shell, python3-gi with GTK 4, dbus-daemon. Run as the only user of a disposable container.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
extension=$(cd "$here/../../windows/Filevero.Linux/gnome-extension" && pwd)
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/filevero-runtime}
mkdir -p -m 700 "$XDG_RUNTIME_DIR"
extensions=$HOME/.local/share/gnome-shell/extensions
mkdir -p "$extensions/filevero@serdarvaran.github.io" "$extensions/test-helper@filevero.test"
cp "$extension"/* "$extensions/filevero@serdarvaran.github.io/"
cp "$here"/helper/* "$extensions/test-helper@filevero.test/"
# GNOME Shell needs a system bus with logind and Xwayland's socket folder; containers have none of them.
mkdir -p -m 1777 /tmp/.X11-unix
mkdir -p /run/dbus
dbus-daemon --system --fork
python3 "$here/logind.py" &
sleep 1
export FILEVERO_TEST="$here/test.py"
exec dbus-run-session -- sh -c '
  gsettings set org.gnome.shell disable-user-extensions false
  gsettings set org.gnome.shell enabled-extensions "[\"filevero@serdarvaran.github.io\", \"test-helper@filevero.test\"]"
  gnome-shell --headless --wayland --virtual-monitor 1280x800 > /tmp/gnome-shell.log 2>&1 &
  WAYLAND_DISPLAY=wayland-0 GDK_BACKEND=wayland python3 "$FILEVERO_TEST"; code=$?
  [ "$code" -eq 0 ] || grep -E "JS ERROR|filevero" -A8 /tmp/gnome-shell.log | head -60
  exit $code'
