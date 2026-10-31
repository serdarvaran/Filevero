# dmgbuild settings; scripts/build-dmg.sh passes the paths through -D defines.
# Icon positions are icon centres in points and match scripts/make-dmg-background.swift.
import os.path

application = defines['app']
format = 'ULFO'
files = [application]
symlinks = {'Applications': '/Applications'}
icon = defines['icon']
background = defines['background']
window_rect = ((200, 120), (640, 500))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
label_pos = 'bottom'
icon_locations = {
    os.path.basename(application): (170, 206),
    'Applications': (470, 206),
}
