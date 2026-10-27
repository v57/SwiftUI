#!/usr/bin/env python3
"""Generates Sources/SwiftUIAndroid/SymbolNames.swift: SF Symbol name -> Material Symbols ligature.

Only names are mapped (no SF Symbols artwork is used). Targets are validated against the
Material Symbols codepoints file: python3 symbol_map.py <codepoints.txt> > SymbolNames.swift
Entries whose SF name ends in .fill only need listing when the Material glyph differs; others
resolve through the base name with the FILL axis set.
"""
import sys

M = {
    # Arrows
    "arrow.backward": "arrow_back", "arrow.forward": "arrow_forward", "arrow.left": "arrow_back",
    "arrow.right": "arrow_forward", "arrow.up": "arrow_upward", "arrow.down": "arrow_downward",
    "arrow.clockwise": "refresh", "arrow.counterclockwise": "history", "arrow.clockwise.circle": "refresh",
    "arrow.down.app": "download", "arrow.down.circle": "arrow_circle_down", "arrow.up.circle": "arrow_circle_up",
    "arrow.down.to.line": "vertical_align_bottom", "arrow.up.to.line": "vertical_align_top",
    "arrow.left.and.right": "swap_horiz", "arrow.left.arrow.right": "swap_horiz", "arrow.up.and.down": "swap_vert",
    "arrow.left.and.right.righttriangle.left.righttriangle.right": "width",
    "arrow.triangle.2.circlepath": "sync", "arrow.2.circlepath": "sync",
    "arrow.triangle.turn.up.right.circle": "turn_right", "arrow.trianglehead.2.clockwise.rotate.90": "sync",
    "arrow.up.folder": "drive_folder_upload", "arrow.up.forward.app": "open_in_new", "arrow.up.right.square": "open_in_new",
    "arrow.up.right": "north_east", "arrow.down.left": "south_west", "arrow.uturn.backward": "undo", "arrow.uturn.forward": "redo",
    "arrowshape.turn.up.left": "reply", "arrowshape.turn.up.right": "forward",
    "arrow.up.arrow.down": "swap_vert", "arrow.down.doc": "file_download", "arrow.up.doc": "upload_file",
    "chevron.backward": "arrow_back_ios_new", "chevron.forward": "arrow_forward_ios", "chevron.left": "chevron_left",
    "chevron.right": "chevron_right", "chevron.up": "expand_less", "chevron.down": "expand_more",
    "chevron.up.chevron.down": "unfold_more", "chevron.down.circle": "expand_circle_down",
    "chevron.left.forwardslash.chevron.right": "code",
    # Apps & devices
    "app": "crop_square", "app.badge": "app_badging", "app.dashed": "select", "apple.logo": "phone_iphone",
    "apple.intelligence": "auto_awesome", "apple.terminal": "terminal", "terminal": "terminal",
    "display": "desktop_windows", "desktopcomputer": "desktop_windows", "laptopcomputer": "laptop_mac",
    "iphone": "smartphone", "ipad": "tablet", "applewatch": "watch", "tv": "tv", "vision.pro": "view_in_ar",
    "server.rack": "dns", "externaldrive": "hard_drive", "internaldrive": "hard_drive", "cpu": "memory",
    "memorychip": "memory", "printer": "print", "keyboard": "keyboard", "headphones": "headphones",
    "camera": "photo_camera", "video": "videocam", "video.circle": "videocam", "mic": "mic", "mic.slash": "mic_off",
    "speaker": "volume_mute", "speaker.wave.1": "volume_down", "speaker.wave.2": "volume_up", "speaker.wave.3": "volume_up",
    "speaker.slash": "volume_off", "battery.0percent": "battery_0_bar", "battery.25percent": "battery_2_bar",
    "battery.50percent": "battery_4_bar", "battery.75percent": "battery_5_bar", "battery.100percent": "battery_full",
    "battery.100percent.bolt": "battery_charging_full", "bolt": "bolt", "bolt.badge.clock": "schedule",
    "bolt.horizontal": "electrical_services", "bolt.horizontal.circle": "electrical_services", "bolt.slash": "flash_off",
    "power": "power_settings_new", "wifi": "wifi", "wifi.slash": "wifi_off", "network": "lan", "antenna.radiowaves.left.and.right": "cell_tower",
    "globe": "public", "icloud": "cloud", "cloud": "cloud", "cloud.sun.rain": "rainy", "sun.max": "light_mode",
    "moon": "dark_mode", "sparkles": "auto_awesome", "wand.and.stars": "auto_fix_high", "brain": "psychology",
    "command": "keyboard_command_key", "option": "keyboard_option_key", "shift": "shift", "delete.left": "backspace",
    # Status
    "checkmark": "check", "checkmark.circle": "check_circle", "checkmark.seal": "verified", "checkmark.square": "check_box",
    "checkmark.shield": "verified_user", "xmark": "close", "xmark.circle": "cancel", "xmark.seal": "new_releases",
    "xmark.square": "disabled_by_default", "xmark.octagon": "dangerous", "exclamationmark.circle": "error",
    "exclamationmark.triangle": "warning", "exclamationmark.octagon": "report", "exclamationmark.magnifyingglass": "search_off",
    "exclamationmark.bubble": "feedback", "questionmark.circle": "help", "questionmark.circle.dashed": "help",
    "questionmark.square": "help_center", "questionmark": "question_mark", "info.circle": "info", "info": "info_i",
    "nosign": "block", "minus.circle": "remove_circle", "plus.circle": "add_circle", "plus": "add", "minus": "remove",
    "plus.square": "add_box", "minus.square": "indeterminate_check_box", "multiply": "close", "equal": "equal",
    "number": "tag", "circle": "radio_button_unchecked", "circle.dashed": "circle", "circle.dotted": "circle",
    "circle.fill": "circle", "largecircle.fill.circle": "radio_button_checked", "smallcircle.filled.circle": "radio_button_checked",
    "circle.hexagongrid": "hive", "circle.hexagonpath": "hexagon", "hexagon": "hexagon", "square": "square",
    "rectangle": "rectangle", "triangle": "change_history", "diamond": "diamond", "seal": "verified",
    "1.circle": "counter_1", "2.circle": "counter_2", "3.circle": "counter_3",
    "rectangle.dashed": "select", "rectangle.portrait.on.rectangle.portrait": "filter_none", "square.on.square": "content_copy",
    "square.grid.2x2": "grid_view", "square.grid.3x3": "apps", "square.grid.3x1.below.line.grid.1x2": "dashboard",
    "rectangle.grid.1x2": "view_agenda", "rectangle.stack": "stacks", "square.stack": "stacks", "square.stack.3d.up": "stacks",
    "sidebar.left": "side_navigation", "sidebar.right": "right_panel_open", "interface.window.on.rectangle.dashed": "web_asset",
    "macwindow": "web_asset", "uiwindow.split.2x1": "splitscreen_left", "tablecells": "table", "list.bullet": "format_list_bulleted",
    "list.number": "format_list_numbered", "list.dash": "list", "line.3.horizontal": "menu",
    "line.3.horizontal.decrease": "filter_list", "line.3.horizontal.decrease.circle": "filter_list",
    "slider.horizontal.3": "tune", "switch.2": "toggle_on", "togglepower": "power_settings_new",
    # ComponentKit catalog
    "appletv": "tv", "filemenu.and.selection": "menu_open", "swatchpalette": "palette", "wind": "air", "checklist": "checklist", "trophy": "trophy", "puzzlepiece": "extension", "arrow.uturn.down": "u_turn_left", "menubar.dock.rectangle": "dock_to_bottom", "hand.wave": "waving_hand",
    # Documents & files
    "doc": "description", "doc.text": "description", "doc.badge.plus": "note_add", "doc.on.doc": "content_copy",
    "doc.on.clipboard": "content_paste", "clipboard": "content_paste", "doc.text.magnifyingglass": "plagiarism",
    "doc.richtext": "article", "doc.plaintext": "article", "doc.zipper": "folder_zip", "note.text": "sticky_note_2",
    "note": "sticky_note_2", "folder": "folder", "folder.badge.plus": "create_new_folder", "folder.badge.questionmark": "folder_off",
    "folder.badge.minus": "folder_delete", "archivebox": "archive", "tray": "inbox", "tray.full": "inbox",
    "tray.and.arrow.down": "move_to_inbox", "tray.and.arrow.up": "outbox", "shippingbox": "package_2", "cylinder.split.1x2": "database",
    "book": "menu_book", "book.closed": "book", "books.vertical": "library_books", "text.book.closed": "book",
    "newspaper": "newspaper", "magazine": "auto_stories", "bookmark": "bookmark", "paperclip": "attach_file",
    "link": "link", "pencil": "edit", "square.and.pencil": "edit_square", "pencil.and.outline": "edit_note",
    "highlighter": "ink_highlighter", "eraser": "ink_eraser", "scissors": "content_cut", "ruler": "straighten",
    "paintbrush": "brush", "paintpalette": "palette", "eyedropper": "colorize", "photo": "image", "photo.badge.magnifyingglass": "image_search",
    "photo.stack": "photo_library", "photo.on.rectangle": "photo_library", "camera.viewfinder": "center_focus_strong",
    "film": "movie", "music.note": "music_note", "waveform": "graphic_eq", "waveform.path.ecg": "monitor_heart",
    "waveform.path.ecg.text.clipboard": "lab_profile", "text.bubble": "chat", "bubble.left": "chat_bubble",
    "bubble.right": "chat_bubble", "bubble.left.and.bubble.right": "forum", "message": "chat", "quote.bubble": "format_quote",
    "text.badge.xmark": "format_clear", "text.magnifyingglass": "find_in_page", "textformat": "text_fields",
    "textformat.size": "format_size", "bold": "format_bold", "italic": "format_italic", "underline": "format_underlined",
    "strikethrough": "format_strikethrough", "text.alignleft": "format_align_left", "text.aligncenter": "format_align_center",
    "text.alignright": "format_align_right", "curlybraces": "data_object", "curlybraces.square": "data_object",
    "ellipsis.curlybraces": "data_object", "chevron.left.slash.chevron.right": "code", "translate": "translate",
    "character.bubble": "translate", "globe.americas": "public",
    # Actions
    "magnifyingglass": "search", "magnifyingglass.circle": "search", "plus.magnifyingglass": "zoom_in",
    "minus.magnifyingglass": "zoom_out", "trash": "delete", "trash.circle": "delete", "trash.slash": "delete_forever",
    "square.and.arrow.up": "ios_share", "square.and.arrow.down": "download", "square.and.arrow.up.circle": "ios_share",
    "square.and.arrow.down.on.square": "save_alt", "arrow.down.circle.dotted": "downloading", "gear": "settings",
    "gearshape": "settings", "gearshape.2": "settings_applications", "wrench": "build", "wrench.and.screwdriver": "construction",
    "hammer": "construction", "screwdriver": "handyman", "scope": "my_location", "target": "target", "location": "near_me",
    "mappin": "location_on", "mappin.and.ellipse": "location_on", "map": "map", "house": "home", "building.2": "apartment",
    "storefront": "storefront", "cart": "shopping_cart", "bag": "shopping_bag", "creditcard": "credit_card",
    "dollarsign.circle": "paid", "gift": "redeem", "tag": "sell", "ticket": "confirmation_number", "greetingcard": "featured_seasonal_and_gifts",
    "flag": "flag", "bell": "notifications", "bell.slash": "notifications_off", "bell.badge": "notifications_active",
    "envelope": "mail", "envelope.open": "drafts", "paperplane": "send", "phone": "call", "video.fill": "videocam",
    "calendar": "calendar_today", "calendar.badge.plus": "calendar_add_on", "clock": "schedule", "clock.arrow.circlepath": "history",
    "clock.arrow.2.circlepath": "history", "clock.arrow.trianglehead.clockwise.rotate.90.path.dotted": "history",
    "alarm": "alarm", "timer": "timer", "stopwatch": "timer", "hourglass": "hourglass_empty",
    "play": "play_arrow", "play.circle": "play_circle", "play.diamond": "play_arrow", "pause": "pause",
    "pause.circle": "pause_circle", "stop": "stop", "stop.circle": "stop_circle", "forward": "fast_forward",
    "backward": "fast_rewind", "forward.end": "skip_next", "backward.end": "skip_previous", "record.circle": "radio_button_checked",
    "repeat": "repeat", "shuffle": "shuffle", "eye": "visibility", "eye.slash": "visibility_off", "hand.raised": "pan_tool",
    "hand.thumbsup": "thumb_up", "hand.thumbsdown": "thumb_down", "hand.draw": "draw", "hand.tap": "touch_app",
    "heart": "favorite", "star": "star", "star.leadinghalf.filled": "star_half", "bolt.heart": "favorite",
    "person": "person", "person.circle": "account_circle", "person.crop.circle": "account_circle",
    "person.crop.circle.badge.plus": "person_add", "person.badge.plus": "person_add", "person.2": "group",
    "person.3": "groups", "person.crop.square": "account_box", "figure.walk": "directions_walk",
    "lock": "lock", "lock.open": "lock_open", "lock.badge.checkmark": "lock_person", "lock.shield": "admin_panel_settings",
    "key": "key", "key.horizontal": "key", "key.2.on.ring": "key", "key.shield": "shield_lock", "shield": "shield",
    "shield.lefthalf.filled": "shield", "shield.lefthalf.filled.badge.checkmark": "verified_user", "checkmark.shield.fill": "verified_user",
    "faceid": "face", "touchid": "fingerprint", "qrcode": "qr_code", "barcode": "barcode",
    "leaf": "eco", "tree": "park", "drop": "water_drop", "flame": "local_fire_department", "snowflake": "ac_unit",
    "pawprint": "pets", "fork.knife": "restaurant", "cup.and.saucer": "coffee", "car": "directions_car",
    "airplane": "flight", "bicycle": "pedal_bike", "tram": "tram", "bus": "directions_bus",
    "chart.bar": "bar_chart", "chart.pie": "pie_chart", "chart.line.uptrend.xyaxis": "trending_up",
    "ellipsis": "more_horiz", "ellipsis.circle": "more_horiz", "ellipsis.vertical": "more_vert",
    "square.and.line.vertical.and.square": "compare", "rectangle.and.pencil.and.ellipsis": "edit_note",
    "rectangle.portrait.and.arrow.right": "logout", "rectangle.portrait.and.arrow.forward": "logout",
    "arrow.right.square": "logout", "person.crop.circle.badge.checkmark": "how_to_reg",
    "arrow.triangle.branch": "call_split", "arrow.triangle.merge": "merge", "arrow.uturn.left": "undo", "character.cursor.ibeam": "text_fields", "cylinder": "database", "exclamationmark": "priority_high",
    "exclamationmark.arrow.triangle.2.circlepath": "sync_problem", "gauge.medium": "speed", "swift": "code", "testtube.2": "science", "text.quote": "format_quote", "button.horizontal": "smart_button", "menubar.rectangle": "menu", "plusminus": "exposure",
    "gauge.with.dots.needle.33percent": "speed",
    # The v57 apps on Linux (Code, Git, Shell, Database, Markdown, Get, Player, Dev, Remote, Hub, Component)
    "text.cursor": "insert_text", "sidebar.trailing": "right_panel_open", "sidebar.leading": "left_panel_open",
    "powerplug": "power", "point.3.connected.trianglepath.dotted": "hub", "point.3.filled.connected.trianglepath.dotted": "hub",
    "arrow.turn.down.left": "subdirectory_arrow_left", "arrow.turn.down.right": "subdirectory_arrow_right",
    "arrowtriangle.right": "play_arrow", "arrowtriangle.down": "arrow_drop_down", "arrowtriangle.up": "arrow_drop_up",
    "arrowtriangle.left": "arrow_left", "aspectratio": "aspect_ratio", "asterisk": "asterisk",
    "captions.bubble": "subtitles", "computermouse": "mouse", "cursorarrow.click": "ads_click", "cursorarrow.click.2": "ads_click",
    "dot.radiowaves.left.and.right": "sensors", "eject": "eject", "graduationcap": "school", "images": "photo_library",
    "increase.indent": "format_indent_increase", "decrease.indent": "format_indent_decrease", "opticaldisc": "album",
    "pin": "push_pin", "pip.enter": "pip", "pip.exit": "pip_exit", "pip": "picture_in_picture", "safari": "explore",
    "speedometer": "speed", "text.badge.checkmark": "spellcheck", "text.badge.plus": "playlist_add",
    "text.word.spacing": "space_bar", "arrow.down.right.and.arrow.up.left": "close_fullscreen",
    "arrow.up.left.and.arrow.down.right": "open_in_full", "arrow.right.circle": "arrow_circle_right",
    "arrow.right.to.line": "keyboard_tab", "arrow.up.left": "north_west", "checkmark.icloud": "cloud_done",
    "icloud.slash": "cloud_off", "icloud.and.arrow.up": "cloud_upload", "circle.lefthalf.filled": "contrast",
    "doc.questionmark": "unknown_document", "exclamationmark.shield": "gpp_maybe", "xmark.shield": "gpp_bad",
    "key.slash": "key_off", "person.badge.minus": "person_remove", "plus.rectangle.on.rectangle": "library_add",
    "plus.square.on.square": "library_add", "rectangle.on.rectangle": "filter_none", "rectangle.split.2x1": "vertical_split",
    "laptopcomputer.and.iphone": "devices", "textformat.size.larger": "text_increase", "textformat.size.smaller": "text_decrease",
    "qrcode.viewfinder": "qr_code_scanner", "film.stack": "video_library", "keyboard.chevron.compact.down": "keyboard_hide",
    "list.bullet.indent": "format_indent_increase", "list.bullet.rectangle": "list_alt",
    "exclamationmark.arrow.circlepath": "sync_problem", "battery.100.bolt": "battery_charging_full", "battery.75": "battery_5_bar",
    "cube": "deployed_code", "cube.box": "package_2", "hand.point.up.left": "touch_app", "macbook.and.iphone": "devices",
    "text.and.command.macwindow": "terminal",
}

def main():
    codepoints = {line.split()[0] for line in open(sys.argv[1]) if line.strip()}
    missing = sorted((k, v) for k, v in M.items() if v not in codepoints)
    if missing:
        sys.stderr.write("Unknown Material names: %s\n" % missing)
        sys.exit(1)
    print("#if os(Android) || os(Linux) || os(Windows)")
    print("// Generated by Android/tools/symbol_map.py — edit the table there. Shared with SwiftUIGtk (symlink).")
    print("/// SF Symbol name → Material Symbols ligature. Only names are mapped (no SF Symbols artwork is")
    print("/// used or shipped); `.fill` and other variants resolve through their base names.")
    print("enum SymbolNames {")
    print("    private static func g(_ text: String) -> SymbolFont.Glyph { SymbolFont.Glyph(text: text, filled: false) }")
    print()
    print("    static let table: [String: SymbolFont.Glyph] = [")
    for k in sorted(M):
        print('        "%s": g("%s"),' % (k, M[k]))
    print("    ]")
    print("}")
    print("#endif")

main()
