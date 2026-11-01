"""Stands in for systemd-logind on the container's system bus so GNOME Shell can start headless; every call fails."""
from gi.repository import Gio, GLib
XML = '''<node><interface name="org.freedesktop.login1.Manager">
<method name="GetSession"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
<method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
<method name="CanSuspend"><arg type="s" direction="out"/></method>
<signal name="PrepareForSleep"><arg type="b"/></signal>
</interface></node>'''
bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)
def call(_c, _s, _p, _i, method, _params, invocation):
    if method == 'CanSuspend': invocation.return_value(GLib.Variant('(s)', ('na',)))
    else: invocation.return_dbus_error('org.freedesktop.login1.NoSuchSession', 'No session in this container')
bus.register_object('/org/freedesktop/login1', Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], call, None, None)
Gio.bus_own_name_on_connection(bus, 'org.freedesktop.login1', Gio.BusNameOwnerFlags.NONE, None, None)
GLib.MainLoop().run()
