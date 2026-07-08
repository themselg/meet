#!/usr/bin/env python3
"""Genera un directorio de temas de cursor todos transparentes.

Uso: make-hidden-cursor.py /opt/meeting-room/cursors

El directorio resultante se usa como XCURSOR_PATH de la sesion del kiosko:
toda biblioteca de cursores (chromium, wlroots, GTK) busca temas SOLO ahi,
y pida el tema que pida ("Adwaita", "default" o el nuestro, via alias) lo
unico que encuentra es un cursor invisible. Asi el cursor deja de viajar
"horneado" en los frames de wayvnc (el control remoto usa el cursor local
del navegador, sin retraso) y la TV no muestra una flecha moviendose sola.
"""

import struct
import sys
from pathlib import Path

# Nombres de cursor que piden los toolkits/navegadores; todos apuntan al mismo
# archivo transparente. Si faltara alguno, el loader caeria a otro tema (flecha
# visible), por eso la lista es generosa.
CURSOR_NAMES = [
    "default", "left_ptr", "pointer", "hand", "hand1", "hand2",
    "pointing_hand", "text", "xterm", "ibeam", "crosshair", "cross",
    "wait", "watch", "progress", "left_ptr_watch", "help", "question_arrow",
    "move", "grab", "grabbing", "closedhand", "openhand", "dnd-move",
    "dnd-none", "not-allowed", "no-drop", "forbidden", "cell",
    "context-menu", "copy", "alias", "vertical-text", "zoom-in", "zoom-out",
    "up_arrow", "all-scroll", "fleur", "col-resize", "row-resize",
    "e-resize", "n-resize", "ne-resize", "nw-resize", "s-resize",
    "se-resize", "sw-resize", "w-resize", "ew-resize", "ns-resize",
    "nesw-resize", "nwse-resize", "sb_h_double_arrow", "sb_v_double_arrow",
    "top_side", "bottom_side", "left_side", "right_side",
    "top_left_corner", "top_right_corner", "bottom_left_corner",
    "bottom_right_corner",
]

# Nombres de tema con los que responderemos: el propio, mas los que piden los
# clientes que ignoran XCURSOR_THEME (chromium pide el del sistema o "default").
THEME_ALIASES = ["default", "Adwaita"]

NOMINAL_SIZE = 24  # tamano que solicitan los clientes por defecto


def xcursor_transparent() -> bytes:
    """Archivo Xcursor con una sola imagen de 1x1 pixel ARGB transparente."""
    header = struct.pack("<4sIII", b"Xcur", 16, 0x1_0000, 1)
    # TOC: una entrada de tipo imagen; el chunk empieza tras header(16)+toc(12)
    toc = struct.pack("<III", 0xFFFD0002, NOMINAL_SIZE, 28)
    image = struct.pack(
        "<IIIIIIIII",
        36,            # tamano de cabecera del chunk
        0xFFFD0002,    # tipo: imagen
        NOMINAL_SIZE,  # subtipo: tamano nominal
        1,             # version
        1, 1,          # ancho, alto
        0, 0,          # hotspot x, y
        0,             # delay
    ) + struct.pack("<I", 0)  # 1 pixel ARGB = transparente
    return header + toc + image


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"Uso: {sys.argv[0]} <directorio base (XCURSOR_PATH)>")
    base = Path(sys.argv[1])
    theme_dir = base / "meeting-room-hidden"
    cursors = theme_dir / "cursors"
    cursors.mkdir(parents=True, exist_ok=True)

    (theme_dir / "index.theme").write_text(
        "[Icon Theme]\nName=meeting-room-hidden\nComment=Cursor invisible del kiosko\n"
    )
    first = cursors / CURSOR_NAMES[0]
    first.write_bytes(xcursor_transparent())
    for name in CURSOR_NAMES[1:]:
        link = cursors / name
        link.unlink(missing_ok=True)
        link.symlink_to(first.name)

    for alias in THEME_ALIASES:
        link = base / alias
        if link.is_symlink() or link.exists():
            if link.is_symlink():
                link.unlink()
            else:
                continue  # no pisar un directorio real
        link.symlink_to(theme_dir.name)

    print(f"Temas de cursor transparentes en {base} (XCURSOR_PATH)")


if __name__ == "__main__":
    main()
