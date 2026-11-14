# Layout of Maxwell.dmg, read by dmgbuild (https://dmgbuild.readthedocs.io).
#   uvx dmgbuild -s packaging/dmg/settings.py -D app=build/release/Maxwell.app Maxwell build/release/Maxwell.dmg
# Run from the repo root. background.tiff holds 1x and 2x renders of background.html (660×400).
app = defines.get("app", "build/release/Maxwell.app")  # noqa: F821 (defines comes from dmgbuild)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines.get("background", "packaging/dmg/background.tiff")  # noqa: F821, relative to the repo root
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {"Maxwell.app": (140, 190), "Applications": (525, 190)}
hide_extensions = ["Maxwell.app"]
