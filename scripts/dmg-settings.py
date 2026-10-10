# dmgbuild settings for the JBLControl installer window.
# Used by scripts/build-app.sh --dmg:  dmgbuild -s scripts/dmg-settings.py -D app=... -D background=... ...
# Icon positions must match scripts/make-dmg-background.swift.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "ULFO"  # LZFSE-compressed, read-only
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")  # volume icon

background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (640, 460))  # frame incl. title bar; leaves ~430 pt of content
icon_size = 128
text_size = 13
icon_locations = {app_name: (170, 190), "Applications": (470, 190)}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
