#!/usr/bin/env python3
"""Редактор рисунка для LED-дисплея Yandex Station Mini 2.

Кликаешь по сегментам — внизу появляется готовый список вида
    G1 G4 E2 D2 D3 C3
Его можно скопировать или сразу отправить на станцию через adb.

Запуск:  python3 smiley_editor.py
"""

import shutil
import subprocess
import tkinter as tk

BG = "#0f0f14"
PANEL = "#16161d"
OFF = "#36363f"
ON = "#ffe27a"
TXT = "#e9e9f0"
DIM = "#8b8b99"
ACCENT = "#78c8ff"

W, H, T, M = 120, 200, 22, 10
GAP = 36
COLON = 44
DIGIT_Y = 54
PAD = 30

LETTERS = "ABCDEFG"

ALL_SEGMENTS = [
    f"{s}{d}" for d in (1, 2, 3, 4) for s in LETTERS
] + ["DEGREE", "MINUS", "PLUS1", "PLUS2", "PLUS3", "PLUS4"]

EXTRAS = ["DEGREE", "MINUS", "PLUS3", "PLUS4"]

PRESETS = {
    "Смайлик": ["G1", "G4", "E2", "D2", "D3", "C3"],
    "Улыбка": ["B1", "F4", "E1", "D1", "D2", "D3", "D4", "C4"],
    "Прямая": ["G1", "G4", "D1", "D2", "D3", "D4"],
    "Грусть": ["A2", "A3", "G1", "G4", "E2", "C3", "D1", "D4"],
}


def hseg(x, y, length, thick):
    return [x + thick / 2, y, x + length - thick / 2, y, x + length, y + thick / 2,
            x + length - thick / 2, y + thick, x + thick / 2, y + thick, x, y + thick / 2]


def vseg(x, y, length, thick):
    return [x, y + thick / 2, x + thick / 2, y, x + thick, y + thick / 2, x + thick,
            y + length - thick / 2, x + thick / 2, y + length, x, y + length - thick / 2]


def digit_shapes(x, y):
    """Возвращает {буква: (точки, центр)} для одной цифры."""
    w, h, t, m = W, H, T, M
    half = h / 2
    vl = half - m - t / 2
    shapes = {
        "A": (hseg(x + m, y, w - 2 * m, t), (x + w / 2, y + t / 2)),
        "G": (hseg(x + m, y + half - t / 2, w - 2 * m, t), (x + w / 2, y + half)),
        "D": (hseg(x + m, y + h - t, w - 2 * m, t), (x + w / 2, y + h - t / 2)),
        "F": (vseg(x, y + m, vl, t), (x + t / 2, y + m + vl / 2)),
        "B": (vseg(x + w - t, y + m, vl, t), (x + w - t / 2, y + m + vl / 2)),
        "E": (vseg(x, y + half + t / 2, vl, t), (x + t / 2, y + half + t / 2 + vl / 2)),
        "C": (vseg(x + w - t, y + half + t / 2, vl, t), (x + w - t / 2, y + half + t / 2 + vl / 2)),
    }
    return shapes


def sort_key(tok):
    if tok in ALL_SEGMENTS[:28]:
        return (0, int(tok[-1]), LETTERS.index(tok[0]), tok)
    if tok in ("PLUS1", "PLUS2"):
        return (1, 0, 0, tok)
    return (2, 0, 0, tok)


class Editor(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("LED-редактор · Station Mini 2")
        self.configure(bg=BG)
        self.resizable(False, False)
        self.on = set()
        self.items = {}
        self.labels = {}
        self.show_letters = tk.BooleanVar(value=True)
        self.canvas = None
        self.build()
        self.apply(PRESETS["Смайлик"])

    # ---------------- UI ----------------
    def build(self):
        head = tk.Frame(self, bg=BG)
        head.pack(fill="x", padx=18, pady=(14, 0))
        tk.Label(head, text="Кликай по сегментам", bg=BG, fg=TXT,
                 font=("DejaVu Sans", 13, "bold")).pack(anchor="w")
        tk.Label(head, text="Имя сегмента = буква + номер цифры, цифры слева направо",
                 bg=BG, fg=DIM, font=("DejaVu Sans", 9)).pack(anchor="w")

        width = PAD * 2 + 4 * W + 3 * GAP + COLON
        height = DIGIT_Y + H + 124
        self.canvas = tk.Canvas(self, width=width, height=height, bg=BG,
                                highlightthickness=0, cursor="hand2")
        self.canvas.pack(padx=18, pady=(6, 0))

        # вывод
        out = tk.Frame(self, bg=BG)
        out.pack(fill="x", padx=18, pady=(4, 0))
        tk.Label(out, text="Сегменты:", bg=BG, fg=DIM,
                 font=("DejaVu Sans", 10)).pack(side="left")
        self.out = tk.Entry(out, bg=PANEL, fg=ACCENT, insertbackground=ACCENT,
                            relief="flat", state="readonly",
                            font=("DejaVu Sans Mono", 12))
        self.out.pack(side="left", fill="x", expand=True, padx=(8, 8), ipady=5)

        btns = tk.Frame(self, bg=BG)
        btns.pack(fill="x", padx=18, pady=(10, 0))

        def button(parent, text, cmd, fg=TXT, bg=PANEL):
            b = tk.Button(parent, text=text, command=cmd, bg=bg, fg=fg,
                          activebackground="#262631", activeforeground=TXT,
                          relief="flat", bd=0, padx=12, pady=6, cursor="hand2",
                          font=("DejaVu Sans", 10))
            b.pack(side="left", padx=(0, 6))
            return b

        button(btns, "Скопировать", self.copy_list, fg="#101014", bg=ON)
        button(btns, "Команда adb", self.copy_cmd)
        button(btns, "На станцию", self.send)

        presets = tk.Frame(self, bg=BG)
        presets.pack(fill="x", padx=18, pady=(8, 0))
        for name, segs in PRESETS.items():
            button(presets, name, lambda s=segs: self.apply(s))
        button(presets, "Пусто", lambda: self.apply([]))

        self.status = tk.Label(self, text="", bg=BG, fg=DIM, anchor="w",
                               justify="left", wraplength=width - 36,
                               font=("DejaVu Sans", 9))
        self.status.pack(fill="x", padx=18, pady=(8, 12))

        self.bind("<Control-c>", lambda e: self.copy_list())
        self.bind("<Escape>", lambda e: self.apply([]))
        self.draw()

    def draw(self):
        c = self.canvas
        c.delete("all")
        self.items.clear()
        self.labels.clear()

        x = PAD
        for d in range(1, 5):
            c.create_text(x + W / 2, DIGIT_Y - 18, text=str(d), fill=DIM,
                          font=("DejaVu Sans", 28, "bold"))
            for letter, (pts, (cx, cy)) in digit_shapes(x, DIGIT_Y).items():
                tok = f"{letter}{d}"
                item = c.create_polygon(pts, fill=OFF, outline="", tags=(tok,))
                txt = c.create_text(cx, cy, text=letter, fill=DIM,
                                    font=("DejaVu Sans", 10, "bold"), tags=(tok,))
                self.items[tok] = item
                self.labels[tok] = txt
                c.tag_bind(tok, "<Button-1>", lambda e, t=tok: self.toggle(t))
            x += W + GAP
            if d == 2:
                # двоеточие
                for i, tok in enumerate(("PLUS1", "PLUS2")):
                    cy = DIGIT_Y + H / 2 + (-1 if i == 0 else 1) * H * 0.10
                    item = c.create_oval(x + COLON / 2 - 9, cy - 9, x + COLON / 2 + 9, cy + 9,
                                         fill=OFF, outline="", tags=(tok,))
                    self.items[tok] = item
                    c.tag_bind(tok, "<Button-1>", lambda e, t=tok: self.toggle(t))
                x += COLON

        # служебные значки
        y = DIGIT_Y + H + 54
        c.create_text(PAD, y - 28, text="служебные значки", anchor="w", fill=DIM,
                      font=("DejaVu Sans", 9))
        ex = PAD + 14
        for tok in EXTRAS:
            item = c.create_oval(ex - 9, y - 9, ex + 9, y + 9, fill=OFF, outline="",
                                 tags=(tok,))
            self.items[tok] = item
            c.tag_bind(tok, "<Button-1>", lambda e, t=tok: self.toggle(t))
            c.create_text(ex + 16, y, text=tok, anchor="w", fill=DIM,
                          font=("DejaVu Sans", 9))
            ex += 148

        self.paint()

    # ---------------- логика ----------------
    def paint(self):
        for tok, item in self.items.items():
            lit = tok in self.on
            kind = self.canvas.type(item)
            self.canvas.itemconfig(item, fill=ON if lit else OFF)
            if kind == "polygon" and tok in self.labels:
                self.canvas.itemconfig(self.labels[tok],
                                       fill="#15151a" if lit else DIM)
        self.out.config(state="normal")
        self.out.delete(0, "end")
        self.out.insert(0, " ".join(sorted(self.on, key=sort_key)))
        self.out.config(state="readonly")

    def toggle(self, tok):
        self.on.symmetric_difference_update({tok})
        self.paint()

    def apply(self, segs):
        self.on = set(segs)
        self.paint()

    def segments(self):
        return sorted(self.on, key=sort_key)

    # ---------------- действия ----------------
    def set_status(self, text, color=DIM):
        self.status.config(text=text, fg=color)

    def copy_list(self):
        self.clipboard_clear()
        self.clipboard_append(" ".join(self.segments()))
        self.set_status("Список сегментов скопирован.")

    def one_shot_cmd(self):
        segs = self.segments()
        clear = ("D=/sys/class/leds/mini2:white:clock; "
                 "for s in " + " ".join(ALL_SEGMENTS) +
                 "; do echo 0 > $D$s/brightness; done")
        if not segs:
            return clear
        return clear + "; for s in " + " ".join(segs) + "; do echo 150 > $D$s/brightness; done"

    def copy_cmd(self):
        cmd = "adb shell '" + self.one_shot_cmd() + "'"
        self.clipboard_clear()
        self.clipboard_append(cmd)
        self.set_status("Команда adb скопирована (одноразовая, до смены минуты).")

    def send(self):
        if not shutil.which("adb"):
            self.set_status("adb не найден в PATH.", "#ff8080")
            return
        try:
            r = subprocess.run(["adb", "shell", self.one_shot_cmd()],
                               capture_output=True, text=True, timeout=20)
        except Exception as exc:  # noqa: BLE001
            self.set_status(f"Ошибка: {exc}", "#ff8080")
            return
        if r.returncode != 0:
            self.set_status((r.stderr or "adb вернул ошибку").strip(), "#ff8080")
        else:
            self.set_status("Отправлено. Держится до смены минуты.", "#8ee08e")


if __name__ == "__main__":
    Editor().mainloop()
