# dmgbuild settings for Marshmallow's drag-to-install DMG.
# Invoked by scripts/make-dmg.sh with -D app=<path> -D background=<path>
import os.path

app = defines.get("app", "build/app.noindex/Marshmallow.app")  # noqa: F821 (provided by dmgbuild)
appname = os.path.basename(app)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = [appname]

background = defines.get("background", "Resources/dmg/background.png")  # noqa: F821
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 120), (660, 420))
default_view = "icon-view"
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {
    appname: (170, 205),
    "Applications": (490, 205),
}
