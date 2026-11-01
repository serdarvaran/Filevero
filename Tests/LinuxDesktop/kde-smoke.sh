#!/bin/sh
# Runs "Filevero --smoke-test" inside a virtual KDE Plasma (KWin Wayland) session, so the KWin bridge is exercised.
# Usage: kde-smoke.sh FILEVERO_COMMAND SMOKE_DIRECTORY. Needs kwin_wayland (with CAP_SYS_NICE), Xwayland, dbus-daemon.
set -eu
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/filevero-runtime} FILEVERO_COMMAND="$1" FILEVERO_SMOKE_DIRECTORY="$2"
mkdir -p -m 700 "$XDG_RUNTIME_DIR"
mkdir -p -m 1777 /tmp/.X11-unix
exec dbus-run-session -- kwin_wayland --virtual --xwayland --width 1600 --height 1000 --exit-with-session \
  "sh -c 'XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland timeout 300 \"\$FILEVERO_COMMAND\" --smoke-test'"
