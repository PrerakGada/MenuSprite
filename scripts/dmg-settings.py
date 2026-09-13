"""Finder layout for MenuSprite's drag-to-Applications disk image."""
from pathlib import Path

application = Path(defines["app"])
format = "UDZO"
compression_level = 9
files = [str(application)]
symlinks = {"Applications": "/Applications"}
icon = str(application / "Contents/Resources/AppIcon.icns")
background = defines["background"]
window_rect = ((160, 140), (760, 604))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
grid_offset = (0, 0)
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 15
icon_size = 128
icon_locations = {application.name: (184, 280), "Applications": (576, 280)}
# Keep the already-signed app's Finder attributes and sealed resources untouched.
# The .app suffix is harmless and avoids changing its extended attributes here.
