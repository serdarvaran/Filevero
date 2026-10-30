# Filevero showcase images

All images are on-screen captures of Filevero windows, taken with `screencapture` from the app's UI audit mode (`--ui-audit … --hold`). Held windows use the same window chrome as the app. The files shown are samples the audit generates in a temporary folder; no personal files, accounts or other apps appear.

| File | Scene | Appearance |
| --- | --- | --- |
| `mac-home.png` | `home.actions`: Workspace with a folder, an image and a PDF selected, Actions tab open | Light, Aurora |
| `mac-home-dark.png` | `home.selected`: Workspace with one image selected, Convert tab open | Dark, Aurora |
| `mac-wheel.png` | `wheel.pdf-multiple`: tools wheel for two PDFs | Light, Aurora |
| `mac-crop.png` | `editor.crop-image`: crop editor | Light, Aurora |
| `mac-themes.png` | `settings.general`: preferences with the eight color themes | Light, Aurora |
| `mac-welcome.png` | `welcome.1`: first page of the introduction | Light, Aurora |
| `mac-window-management-view.png` | `wheel.window`: window arrangement wheel | Dark, Aurora |

Window captures were scaled to at most 1600 pixels wide and saved without metadata. To refresh them, build the app, run a scene with `--hold`, and capture its window by ID.
