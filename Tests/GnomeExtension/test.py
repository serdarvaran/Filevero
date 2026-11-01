"""Plays Filevero against the real extension in a headless GNOME Shell: owns the app's bus name, calls every
Shell method, opens a window to move and pin, changes the clipboard and checks a stranger is refused."""
import sys, time
import gi
from gi.repository import Gio, GLib

APP, APP_PATH, APP_IFACE = 'io.github.serdarvaran.Filevero', '/io/github/serdarvaran/Filevero', 'io.github.serdarvaran.Filevero.Bridge'
SHELL, SHELL_PATH = 'io.github.serdarvaran.Filevero.Shell', '/io/github/serdarvaran/Filevero/Shell'
failures, events = [], []

def check(ok, message):
    print(('PASS ' if ok else 'FAIL ') + message, flush=True)
    if not ok: failures.append(message)

def pump(seconds, until=lambda: False):
    end = time.time() + seconds
    while time.time() < end and not until():
        GLib.MainContext.default().iteration(False); time.sleep(0.01)
    return until()

bus = Gio.bus_get_sync(Gio.BusType.SESSION)
def has_owner(name):
    return bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'NameHasOwner',
                         GLib.Variant('(s)', (name,)), None, 0, -1, None).unpack()[0]
check(pump(25, lambda: has_owner(SHELL)), 'extension owns its bus name in GNOME Shell')
if failures: sys.exit(1)

def event(_c, _s, _p, _i, _m, params, invocation):
    events.append(tuple(params.unpack())); invocation.return_value(None)
xml = f'<node><interface name="{APP_IFACE}"><method name="Event"><arg type="s" direction="in"/><arg type="s" direction="in"/></method></interface></node>'
bus.register_object(APP_PATH, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], event, None, None)

def shell(method, args=None, connection=None):
    return (connection or bus).call_sync(SHELL, SHELL_PATH, SHELL, method, args, None, 0, 5000, None).unpack()

# A stranger is refused before Filevero runs and while it runs.
stranger = Gio.DBusConnection.new_for_address_sync(Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None),
    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
def refused(connection):
    try: shell('Pointer', connection=connection); return False
    except GLib.Error as error: return 'AccessDenied' in error.message
check(refused(bus), 'calls are refused while Filevero is not running')

Gio.bus_own_name_on_connection(bus, APP, Gio.BusNameOwnerFlags.NONE, None, None)
check(pump(10, lambda: ('hello', '') in events), 'extension says hello when Filevero appears')
check(refused(stranger), 'another process is refused while Filevero runs')

x, y, mask = shell('Pointer')
check(isinstance(x, int) and isinstance(mask, int), f'Pointer returns position and modifier mask ({x},{y},{mask})')
area = shell('WorkArea', GLib.Variant('(ii)', (10, 10)))
check(area[2] >= 1000 and area[3] >= 600, f'WorkArea returns the virtual monitor ({area})')
check(shell('BindShortcut', GLib.Variant('(ss)', ('download-link', '<Control><Shift>d')))[0], 'BindShortcut grabs Ctrl+Shift+D')
shell('UnbindShortcut', GLib.Variant('(s)', ('download-link',)))
check(shell('BindShortcut', GLib.Variant('(ss)', ('clipboard', '<Control><Shift>v')))[0], 'BindShortcut grabs again after unbinding')

# A window owned by this process: activation, moving and pinning as Filevero does with its shelf and wheels.
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk  # Initializes against the shell's Wayland display, which exists only now.
window = Gtk.Window(title='Filevero probe'); window.set_default_size(420, 300); window.present()
check(pump(10, lambda: shell('ActiveWindow')[0] != ''), 'ActiveWindow reports the focused window')
active = shell('ActiveWindow')[0]
check(shell('MoveWindow', GLib.Variant('(siiii)', (active, 120, 140, 500, 360)))[0], 'MoveWindow places a window')
check(shell('Pin', GLib.Variant('(siib)', ('Filevero probe', 200, 220, True)))[0], 'Pin keeps a Filevero window above at a position')
check(shell('Pin', GLib.Variant('(siib)', ('No such window', 0, 0, True)))[0] is False, 'Pin refuses an unknown window')
check(shell('MoveWindow', GLib.Variant('(siiii)', ('0', 0, 0, 10, 10)))[0] is False, 'MoveWindow refuses an unknown window')

# The clipboard owner changing (as any app copying) reaches Filevero.
before = len([e for e in events if e[0] == 'clipboard'])
window.get_display().get_clipboard().set('Filevero İğüş')
check(pump(10, lambda: len([e for e in events if e[0] == 'clipboard']) > before), 'clipboard change is reported')
check(shell('Paste', GLib.Variant('(s)', (active,)))[0], 'Paste types Ctrl+V through the virtual keyboard')
pump(1)

# Filevero leaving drops its shortcuts; the extension stays loaded for its return.
bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'ReleaseName', GLib.Variant('(s)', (APP,)), None, 0, -1, None)
pump(2)
check(refused(bus), 'calls are refused again after Filevero quits')
check(has_owner(SHELL), 'extension keeps running after Filevero quits')
print('RESULT', 'FAIL' if failures else 'PASS', len(failures))
sys.exit(1 if failures else 0)
