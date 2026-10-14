# dmgbuild settings for Heed-arm64.dmg: heed.app on the left, a link to /Applications on the right, over
# background.tiff (660x400 points, 1x and 2x). scripts/dmg.sh passes both paths: -D app=<path> -D background=<path>
# (dmgbuild runs this file without __file__).
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)

format = "ULFO"  # lzfse: smaller and faster than zlib; any supported macOS opens it
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/heed.icns")
badge_icon = None

background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (180, 210),
    "Applications": (480, 210),
}
