#!/usr/bin/env python3
"""Genera un tema de cursor Xcursor totalmente transparente.

Uso: make-hidden-cursor.py /usr/share/icons/meeting-room-hidden

Con XCURSOR_THEME=meeting-room-hidden el compositor no dibuja cursor, con lo
que este deja de ir "horneado" en los frames que captura wayvnc (el control
remoto usa entonces el cursor local del navegador, sin retraso) y la TV de la
sala no muestra una flecha moviendose sola.
"""

import struct
import sys
from pathlib import Path

# Nombres de cursor que piden los toolkits/navegadores; todos apuntan al mismo
# archivo transparente. Si faltara alguno, Xcursor cae al tema default (flecha
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
        sys.exit(f"Uso: {sys.argv[0]} <directorio del tema>")
    theme_dir = Path(sys.argv[1])
    cursors = theme_dir / "cursors"
    cursors.mkdir(parents=True, exist_ok=True)

    (theme_dir / "index.theme").write_text(
        "[Icon Theme]\nName=meeting-room-hidden\nComment=Cursor invisible del kiosko\n"
    )
    base = cursors / CURSOR_NAMES[0]
    base.write_bytes(xcursor_transparent())
    for name in CURSOR_NAMES[1:]:
        link = cursors / name
        link.unlink(missing_ok=True)
        link.symlink_to(base.name)

    print(f"Tema de cursor transparente generado en {theme_dir}")


if __name__ == "__main__":
    main()
