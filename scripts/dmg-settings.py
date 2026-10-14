# Layout of the House Control disk image, for dmgbuild (scripts/release-mac.sh runs it).
# The positions match the arrow drawn by scripts/make-dmg-background.swift.
import os

app = defines["app"]  # noqa: F821 (dmgbuild passes -D app=… -D root=…)
root = defines["root"]  # noqa: F821

format = "ULFO"  # LZFSE: smallest, opens on macOS 10.11 and later
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(root, "macos", "AppIcon.icns")
background = os.path.join(root, "macos", "dmg-background.tiff")

window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 200),
    "Applications": (470, 200),
}
