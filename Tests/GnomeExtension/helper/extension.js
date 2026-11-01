import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
export default class Helper extends Extension {
    enable() {
        const hide = () => Main.overview.hide();
        if (Main.layoutManager._startingUp) this._id = Main.layoutManager.connect('startup-complete', hide); else hide();
    }
    disable() { if (this._id) Main.layoutManager.disconnect(this._id); }
}
