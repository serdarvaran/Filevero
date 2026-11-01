// Filevero desktop bridge for GNOME Shell. It serves only the running Filevero app (the owner of the
// io.github.serdarvaran.Filevero bus name); calls from any other sender are refused.
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Mtk from 'gi://Mtk';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const APP = 'io.github.serdarvaran.Filevero';
const APP_PATH = '/io/github/serdarvaran/Filevero';
const APP_IFACE = 'io.github.serdarvaran.Filevero.Bridge';
const SHELL = 'io.github.serdarvaran.Filevero.Shell';
const SHELL_PATH = '/io/github/serdarvaran/Filevero/Shell';
const XML = `<node><interface name="${SHELL}">
<method name="Pointer"><arg type="i" direction="out"/><arg type="i" direction="out"/><arg type="u" direction="out"/></method>
<method name="ActiveWindow"><arg type="s" direction="out"/></method>
<method name="Paste"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
<method name="MoveWindow"><arg type="s" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
<method name="WorkArea"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="out"/><arg type="i" direction="out"/><arg type="i" direction="out"/><arg type="i" direction="out"/></method>
<method name="Pin"><arg type="s" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="b" direction="in"/><arg type="b" direction="out"/></method>
<method name="BindShortcut"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
<method name="UnbindShortcut"><arg type="s" direction="in"/></method>
</interface></node>`;
const MOVING = new Set([Meta.GrabOp.MOVING, Meta.GrabOp.KEYBOARD_MOVING].filter(op => op !== undefined));

export default class FileveroExtension extends Extension {
    enable() {
        this._owner = null;
        this._shortcuts = new Map();
        this._signals = [];
        const info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0];
        this._registration = Gio.DBus.session.register_object(SHELL_PATH, info, (...args) => this._call(...args), null, null);
        this._name = Gio.bus_own_name_on_connection(Gio.DBus.session, SHELL, Gio.BusNameOwnerFlags.NONE, null, null);
        this._watch = Gio.bus_watch_name(Gio.BusType.SESSION, APP, Gio.BusNameWatcherFlags.NONE,
            (_c, _n, owner) => { this._owner = owner; this._emit('hello', ''); this._updatePanel(); },
            () => { this._owner = null; this._unbindAll(); this._updatePanel(); });
        const selection = global.display.get_selection();
        this._connect(selection, 'owner-changed', (_s, type) => {
            if (type === Meta.SelectionType.SELECTION_CLIPBOARD) this._emit('clipboard', '');
        });
        this._connect(global.display, 'grab-op-begin', (_d, window, op) => this._dragStarted(window, op));
        this._connect(global.display, 'grab-op-end', (_d, window) => this._dragEnded(window));
        this._connect(global.display, 'accelerator-activated', (_d, action) => {
            for (const [id, bound] of this._shortcuts) if (bound === action) this._emit('shortcut', id);
        });
    }

    disable() {
        this._emit('goodbye', '');
        this._unbindAll();
        this._dragEnded(null);
        for (const [object, id] of this._signals) object.disconnect(id);
        this._signals = [];
        if (this._registration) Gio.DBus.session.unregister_object(this._registration);
        if (this._name) Gio.bus_unown_name(this._name);
        if (this._watch) Gio.bus_unwatch_name(this._watch);
        this._panel?.destroy();
        this._keyboard?.run_dispose?.();
        this._panel = this._keyboard = this._registration = this._name = this._watch = null;
    }

    _connect(object, signal, handler) { this._signals.push([object, object.connect(signal, handler)]); }

    _emit(kind, payload) {
        if (!this._owner) return;
        Gio.DBus.session.call(APP, APP_PATH, APP_IFACE, 'Event', new GLib.Variant('(ss)', [kind, payload]),
            null, Gio.DBusCallFlags.NO_AUTO_START, 2000, null, null);
    }

    _call(_connection, sender, _path, _iface, method, parameters, invocation) {
        if (!this._owner || sender !== this._owner) {
            invocation.return_dbus_error('org.freedesktop.DBus.Error.AccessDenied', 'Only Filevero may use this interface.');
            return;
        }
        try {
            const args = parameters.deepUnpack();
            const result = this[`_${method}`](...args);
            invocation.return_value(result === undefined ? null : result);
        } catch (error) {
            invocation.return_dbus_error('org.freedesktop.DBus.Error.Failed', `${error}`);
        }
    }

    _Pointer() {
        const [x, y, mask] = global.get_pointer();
        return new GLib.Variant('(iiu)', [x, y, mask]);
    }

    _ActiveWindow() {
        return new GLib.Variant('(s)', [global.display.focus_window ? `${global.display.focus_window.get_id()}` : '']);
    }

    _window(id) {
        return global.get_window_actors().map(actor => actor.meta_window).find(window => `${window.get_id()}` === id) ?? null;
    }

    _Paste(id) {
        const target = id ? this._window(id) : null;
        if (target) target.activate(global.get_current_time());
        const seat = Clutter.get_default_backend().get_default_seat();
        this._keyboard ??= seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        // Wait for the focus change before typing, so the paste lands in the app the user came from.
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 80, () => {
            const time = GLib.get_monotonic_time();
            this._keyboard.notify_keyval(time, Clutter.KEY_Control_L, Clutter.KeyState.PRESSED);
            this._keyboard.notify_keyval(time, Clutter.KEY_v, Clutter.KeyState.PRESSED);
            this._keyboard.notify_keyval(time, Clutter.KEY_v, Clutter.KeyState.RELEASED);
            this._keyboard.notify_keyval(time, Clutter.KEY_Control_L, Clutter.KeyState.RELEASED);
            return GLib.SOURCE_REMOVE;
        });
        return new GLib.Variant('(b)', [true]);
    }

    _MoveWindow(id, x, y, width, height) {
        const window = this._window(id);
        if (!window || !window.allows_move()) return new GLib.Variant('(b)', [false]);
        if (window.get_maximized?.()) {
            try { window.unmaximize(Meta.MaximizeFlags.BOTH); } catch { window.unmaximize(); }
        }
        window.move_resize_frame(true, x, y, width, height);
        return new GLib.Variant('(b)', [true]);
    }

    _WorkArea(x, y) {
        const monitor = global.display.get_monitor_index_for_rect(new Mtk.Rectangle({x, y, width: 1, height: 1}));
        const area = global.workspace_manager.get_active_workspace().get_work_area_for_monitor(monitor);
        return new GLib.Variant('(iiii)', [area.x, area.y, area.width, area.height]);
    }

    _Pin(title, x, y, above) {
        const window = global.get_window_actors().map(actor => actor.meta_window).find(w => w.get_title() === title);
        if (!window) return new GLib.Variant('(b)', [false]);
        if (above) window.make_above(); else window.unmake_above();
        window.move_frame(true, x, y);
        return new GLib.Variant('(b)', [true]);
    }

    _BindShortcut(id, accelerator) {
        this._UnbindShortcut(id);
        const action = global.display.grab_accelerator(accelerator, Meta.KeyBindingFlags.NONE);
        if (action === Meta.KeyBindingAction.NONE) return new GLib.Variant('(b)', [false]);
        Main.wm.allowKeybinding(Meta.external_binding_name_for_action(action), Shell.ActionMode.ALL);
        this._shortcuts.set(id, action);
        return new GLib.Variant('(b)', [true]);
    }

    _UnbindShortcut(id) {
        const action = this._shortcuts.get(id);
        if (action === undefined) return;
        global.display.ungrab_accelerator(action);
        Main.wm.allowKeybinding(Meta.external_binding_name_for_action(action), Shell.ActionMode.NONE);
        this._shortcuts.delete(id);
    }

    _unbindAll() { for (const id of [...this._shortcuts.keys()]) this._UnbindShortcut(id); }

    _dragStarted(window, op) {
        this._dragEnded(null);
        if (!window || !MOVING.has(op) || window.get_window_type() !== Meta.WindowType.NORMAL) return;
        this._dragged = window;
        this._moved = window.connect('position-changed', () => this._report('window-drag', window));
    }

    _dragEnded(window) {
        if (this._dragged && this._moved) this._dragged.disconnect(this._moved);
        if (window && window === this._dragged) this._report('window-drop', window);
        this._dragged = this._moved = null;
    }

    _report(kind, window) {
        const frame = window.get_frame_rect();
        const [x, y, mask] = global.get_pointer();
        this._emit(kind, [window.get_id(), frame.x, frame.y, frame.width, frame.height, x, y, mask, 0].join('\t'));
    }

    // Stock GNOME has no tray; while Filevero runs and no StatusNotifier host exists, the panel shows its menu.
    _updatePanel() {
        this._panel?.destroy();
        this._panel = null;
        if (!this._owner) return;
        Gio.DBus.session.call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'NameHasOwner',
            new GLib.Variant('(s)', ['org.kde.StatusNotifierWatcher']), null, Gio.DBusCallFlags.NONE, -1, null, (connection, result) => {
                const [hosted] = connection.call_finish(result).deepUnpack();
                if (hosted || !this._owner || this._panel) return;
                this._panel = new PanelMenu.Button(0.0, 'Filevero');
                this._panel.add_child(new St.Icon({icon_name: 'document-send-symbolic', style_class: 'system-status-icon'}));
                for (const [label, id] of [['Open Filevero', 'open'], ['Library', 'library'], ['Download copied link', 'download-link'],
                    ['Show clipboard history', 'clipboard'], ['Settings', 'settings'], ['Quit Filevero', 'quit']]) {
                    const item = new PopupMenu.PopupMenuItem(label);
                    item.connect('activate', () => this._emit('panel', id));
                    this._panel.menu.addMenuItem(item);
                }
                Main.panel.addToStatusArea(this.uuid, this._panel);
            });
    }
}
