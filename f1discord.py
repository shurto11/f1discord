#!/usr/bin/env python3
"""
f1discord: Discord の通知を、F1 中継のチームラジオ風のパネルで画面に出す。

dynabook の espoke の中継 (discord_relay.py --notify) が Discord アプリの通知から拾った発言を、
地図のサーバーの /discord.json (tailnet の中だけ) から読み、この PC のフレームバッファ (/dev/fb0) に直接描く。
X も Wayland も無い fbterm + tmux の画面の上に重ねる。消すときは tmux に描き直させる。

    ./f1discord.py                       # 常駐して、新着を表示する
    ./f1discord.py --test 名前 "本文"    # 中継につながず、1 回だけ表示して終わる (本文は何個でも。@名前:本文 で別の人)

設定は config.json (このファイルの隣。無くてよい) に書く。変えたら systemctl --user restart f1discord。
同じ名前を大文字にして F1DISCORD_ を付けた環境変数 (F1DISCORD_TEXT_SIZE など) があれば、そちらを使う:
    url           中継の地図のサーバー。既定 http://100.85.213.75:8020 (dynabook の tailnet の IP)
    pos           パネルの位置。top / bottom と left / right の組み合わせ。既定 bottom-right
    margin_x      画面の左右の端からの距離 (画面のピクセル数)。既定 0
    margin_y      画面の上下の端からの距離。既定 64 (画面の下のタスクバーの高さ。パネルの下辺がその上辺に付く)
                  画面は液晶の全体 (1366x768)。fbterm と tmux が使うのはその左上の 1280x720 だけ
    scale         全体の大きさの倍率。既定 0.5
    width         パネルの幅。既定 330
    text_size     本文の字の大きさ。既定 19
    channel_size  チャンネル名の字の大きさ。既定 15
    fb            フレームバッファ。既定 /dev/fb0
    drivers       名前ごとの番号と色。無い人は、名前から決まる番号と色になる (いつも同じ)
幅と字の大きさは倍率を掛ける前のピクセル数で、画面ではそれに scale を掛けた大きさになる。例:
    {"text_size": 26, "channel_size": 20, "drivers": {"名前": {"number": 81, "color": "#FF8000"}}}
"""

import argparse
import fcntl
import hashlib
import json
import mmap
import os
import queue
import random
import re
import struct
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.request

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def load_config():
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


CONFIG = load_config()


def setting(name, default):
    """環境変数 F1DISCORD_<NAME>、無ければ config.json の name、それも無ければ default。型は default に合わせる"""
    return type(default)(os.environ.get("F1DISCORD_" + name.upper(), CONFIG.get(name, default)))


URL = setting("url", "http://100.85.213.75:8020").rstrip("/")
POS = setting("pos", "bottom-right")
MARGIN_X = setting("margin_x", 0)
MARGIN_Y = setting("margin_y", 64)
SCALE = setting("scale", 0.5)
WIDTH = setting("width", 330)
TEXT_SIZE = max(setting("text_size", 19), 6)
CHANNEL_SIZE = max(setting("channel_size", 15), 6)
FB = setting("fb", "/dev/fb0")

FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"   # index 0 が JP
FPS = 15
PAD = 14             # パネルの中の余白
MAX_HEIGHT = 560     # パネルの高さの上限。超えたら古い発言から落とす
MAX_LINES = 7        # 1 つの発言の行数の上限
SHOW_BASE = 6.0      # 最後の発言が来てから消すまでの秒数 (これに字数ぶんを足す)
SHOW_PER_CHAR = 0.09
SHOW_MAX = 20.0
TALK_BASE = 1.5      # 波形を大きく動かす秒数 (これに字数ぶんを足す)
OPEN_TIME = 0.25     # 開くアニメーションの秒数

BG = (11, 16, 30)
BG_BAND = (19, 27, 48)
WHITE = (245, 245, 245)
# 番号と色を決めていない人に、名前から割り当てる色
TEAM_COLORS = ["#3671C6", "#E8002D", "#27F4D2", "#FF8000", "#229971", "#FF87BC", "#64C4FF", "#6692FF",
               "#52E252", "#B6BABD"]


DRIVERS = {unicodedata.normalize("NFKC", k).casefold(): v for k, v in CONFIG.get("drivers", {}).items()}


def hex_color(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def driver(name):
    """名前の (番号, 色)。config.json に無ければ名前から決める"""
    h = int.from_bytes(hashlib.sha1(name.encode()).digest()[:4], "big")
    d = DRIVERS.get(unicodedata.normalize("NFKC", name).casefold(), {})
    return d.get("number", h % 99 + 1), hex_color(d.get("color", TEAM_COLORS[(h >> 8) % len(TEAM_COLORS)]))


def clean(text):
    """フォントに無くて豆腐になる字 (絵文字、文字の向きの区切り) を落とし、空白をまとめる"""
    out = []
    for c in text:
        o = ord(c)
        if (0x1F000 <= o <= 0x1FAFF or 0x2600 <= o <= 0x27BF or 0xFE00 <= o <= 0xFE0F or 0xE0000 <= o <= 0xE0FFF
                or o in (0x200B, 0x200D, 0x200E, 0x200F) or 0x2066 <= o <= 0x2069):
            continue
        out.append(" " if c.isspace() else c)
    return re.sub(" +", " ", "".join(out)).strip()


# ---------------- 絵を作る ----------------

_fonts = {}


def font(size):
    if size not in _fonts:
        _fonts[size] = ImageFont.truetype(FONT, size)
    return _fonts[size]


def fit_font(text, size, width, smallest=14):
    """width に収まる、size 以下でいちばん大きいフォント"""
    while size > smallest and font(size).getlength(text) > width:
        size -= 1
    return font(size)


def ellipsize(text, f, width):
    if f.getlength(text) <= width:
        return text
    while text and f.getlength(text + "…") > width:
        text = text[:-1]
    return text + "…"


def wrap(text, f, width):
    """width に収まるように行に分ける。英数字の語は途中で切らず、日本語は 1 字ずつ切れる"""
    lines, line = [], ""
    for tok in re.findall(r"[!-~]+|\s+|.", text):
        if tok.isspace():
            if line:
                line += " "
            continue
        while f.getlength(tok) > width:          # 1 語が 1 行より長い (URL など)
            if line.strip():
                lines.append(line.rstrip())
                line = ""
            n = len(tok)
            while n > 1 and f.getlength(tok[:n]) > width:
                n -= 1
            lines.append(tok[:n])
            tok = tok[n:]
        if line and f.getlength(line + tok) > width:
            lines.append(line.rstrip())
            line = ""
        line += tok
    if line.strip():
        lines.append(line.rstrip())
    if len(lines) > MAX_LINES:
        lines = lines[:MAX_LINES]
        lines[-1] = ellipsize(lines[-1] + "…", f, width)
    return lines


class Panel:
    """1 回の表示。開いた人 (owner) の発言は色付きで右寄せ、その間に来たほかの人の発言は白で左寄せ"""

    HEAD_H = 76
    BAND_H = 58
    LINE_H = round(TEXT_SIZE * 1.37)

    def __init__(self, msg):
        self.owner = msg["author"]
        self.number, self.color = driver(self.owner)
        # チャンネル名は帯の右に、幅の 4 割まで
        ch = msg.get("channel")
        self.channel = ellipsize("#" + clean(ch), font(CHANNEL_SIZE), (WIDTH - PAD * 2) * 0.4) if ch else None
        self.msgs = []
        self.add(msg)

    def add(self, msg):
        f = font(TEXT_SIZE)
        text = clean(msg["text"]).upper() or "…"
        mine = msg["author"] == self.owner
        lines = wrap("“%s”" % text, f, WIDTH - PAD * 2 - 22)
        label = None if mine else clean(msg["author"]).upper()
        self.msgs.append((mine, label, lines))
        while len(self.msgs) > 1 and self.height() > MAX_HEIGHT:
            del self.msgs[0]
        self.image = self.render()

    def height(self):
        h = self.HEAD_H + self.BAND_H + 12
        for _, label, lines in self.msgs:
            h += (18 if label else 0) + len(lines) * self.LINE_H + 12
        return h + 4

    def render(self):
        """動かない部分の絵 (波形はコマごとに描き足す)"""
        img = Image.new("RGB", (WIDTH, self.height()), BG)
        d = ImageDraw.Draw(img)
        inner = WIDTH - PAD * 2
        # 名前 (色) と RADIO (白)
        name = clean(self.owner).upper() or "?"
        f = fit_font(name, 34, inner, 20)
        d.text((PAD, 24), ellipsize(name, f, inner), font=f, fill=self.color, anchor="lm")
        d.text((WIDTH - PAD, 56), "RADIO", font=font(30), fill=WHITE, anchor="rm")
        # 番号と波形の帯
        top = self.HEAD_H
        d.rectangle((0, top, WIDTH, top + self.BAND_H), fill=BG_BAND)
        dim = tuple((c + b) // 2 for c, b in zip(self.color, BG_BAND))
        d.text((PAD, top + self.BAND_H // 2), str(self.number), font=font(50), fill=dim, anchor="lm")
        if self.channel:
            d.text((WIDTH - PAD, top + self.BAND_H // 2), self.channel, font=font(CHANNEL_SIZE), fill=WHITE,
                   anchor="rm")
        d.rectangle((0, top + self.BAND_H, WIDTH, top + self.BAND_H + 2), fill=self.color)
        # 発言
        y = top + self.BAND_H + 14
        f = font(TEXT_SIZE)
        for mine, label, lines in self.msgs:
            if label:
                d.text((PAD, y + 7), ellipsize(label, font(13), inner), font=font(13), fill=(150, 158, 175),
                       anchor="lm")
                y += 18
            for line in lines:
                if mine:
                    d.text((WIDTH - PAD, y + self.LINE_H // 2), line, font=f, fill=self.color, anchor="rm")
                else:
                    d.text((PAD, y + self.LINE_H // 2), line, font=f, fill=WHITE, anchor="lm")
                y += self.LINE_H
            y += 12
        return img

    def wave_box(self):
        """波形を描く範囲 (x0, x1, 中心の y, 高さの半分)"""
        x0 = PAD + int(font(50).getlength(str(self.number))) + 12
        x1 = WIDTH - PAD - (int(font(CHANNEL_SIZE).getlength(self.channel)) + 12 if self.channel else 0)
        return x0, x1, self.HEAD_H + self.BAND_H // 2, self.BAND_H // 2 - 8


class Wave:
    """チームラジオの波形。しゃべっている間は大きく、あとは小さく揺れる"""

    BAR, GAP = 3, 2

    def __init__(self):
        self.levels = []

    def draw(self, img, panel, talking):
        x0, x1, cy, half = panel.wave_box()
        n = max((x1 - x0) // (self.BAR + self.GAP), 0)
        if len(self.levels) != n:
            self.levels = [0.0] * n
        d = ImageDraw.Draw(img)
        light = tuple((c + 255) // 2 for c in panel.color)
        for i in range(n):
            target = random.random() ** 2 * (1.0 if talking else 0.12)
            # 真ん中ほど大きい山にする
            target *= 0.35 + 0.65 * (1 - abs(i / max(n - 1, 1) * 2 - 1))
            self.levels[i] += (target - self.levels[i]) * 0.55
            h = max(int(self.levels[i] * half), 1)
            x = x0 + i * (self.BAR + self.GAP)
            d.rectangle((x, cy - h, x + self.BAR - 1, cy + h), fill=light)


# ---------------- フレームバッファ ----------------

class Framebuffer:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR)
        # FBIOGET_VSCREENINFO: xres, yres, xres_virtual, yres_virtual, xoffset, yoffset, bits_per_pixel, grayscale,
        # red / green / blue / transp の (offset, length, msb_right)
        var = struct.unpack("8I12I", fcntl.ioctl(self.fd, 0x4600, bytes(160))[:80])
        # 見えている大きさ (xres, yres) は fbterm の使う 1280x720 だが、液晶には仮想の大きさ (1366x768) の全体が
        # 映っているので、そちらを画面の大きさにする
        _, _, self.width, self.height, _, _, bpp = var[:7]
        vyres = self.height
        if bpp != 32:
            sys.exit("f1discord: %s が 32bpp でない (%d)" % (path, bpp))
        self.shifts = (var[8], var[11], var[14])        # R, G, B のビット位置
        # FBIOGET_FSCREENINFO: id[16], smem_start (unsigned long), smem_len, type, type_aux, visual,
        # xpanstep, ypanstep, ywrapstep, line_length
        fix = struct.unpack("16sL4I3HI", fcntl.ioctl(self.fd, 0x4602, bytes(80))[:struct.calcsize("16sL4I3HI")])
        self.stride = fix[9]
        self.map = mmap.mmap(self.fd, self.stride * vyres)
        self.pixels = np.frombuffer(self.map, np.uint32).reshape(vyres, self.stride // 4)

    def grab(self, rect):
        x, y, w, h = rect
        return self.pixels[y:y + h, x:x + w].copy()

    def put(self, rect, saved):
        x, y, w, h = rect
        self.pixels[y:y + h, x:x + w] = saved

    def blit(self, img, x, y, rows=None):
        """img (RGB) の上から rows 行を (x, y) に描く"""
        a = np.asarray(img, np.uint32)
        if rows is not None:
            a = a[:rows]
        h = min(a.shape[0], self.height - y)
        w = min(a.shape[1], self.width - x)
        if h <= 0 or w <= 0:
            return
        a = a[:h, :w]
        r, g, b = self.shifts
        self.pixels[y:y + h, x:x + w] = (a[..., 0] << r) | (a[..., 1] << g) | (a[..., 2] << b) | 0xFF000000


def tmux_socket():
    if os.environ.get("TMUX"):
        return os.environ["TMUX"].split(",")[0]
    uid = os.getuid()
    for d in (os.environ.get("TMUX_TMPDIR"), "/run/user/%d" % uid, "/tmp"):
        if d and os.path.exists("%s/tmux-%d/default" % (d, uid)):
            return "%s/tmux-%d/default" % (d, uid)
    return None


def repaint():
    """パネルを消す。fbterm は自分の描いた字しか覚えていないので、tmux に画面を全部描き直させる。
    tmux の外 (画面の右端と下) は、呼ぶ側が描く前の絵を取っておいて戻す"""
    sock = tmux_socket()
    if not sock:
        return
    try:
        clients = subprocess.run(["tmux", "-S", sock, "list-clients", "-F", "#{client_name}"],
                                 capture_output=True, text=True, timeout=5).stdout.split()
        for c in clients:
            subprocess.run(["tmux", "-S", sock, "refresh-client", "-t", c], timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        pass


# ---------------- 表示 ----------------

def show(fb, first, inbox):
    """first の発言でパネルを開き、消えるまでに inbox に来た発言は同じパネルに足す"""
    panel = Panel(first)
    wave = Wave()

    def place(img):
        """倍率を掛けた絵と、その左上の位置"""
        if SCALE != 1:
            img = img.resize((max(round(img.width * SCALE), 1), max(round(img.height * SCALE), 1)), Image.LANCZOS)
        x = MARGIN_X if "left" in POS else fb.width - img.width - MARGIN_X
        y = MARGIN_Y if "top" in POS else fb.height - img.height - MARGIN_Y
        return img, x, y

    def timing(msg):
        n = len(msg["text"])
        now = time.monotonic()
        return now + TALK_BASE + n * 0.05, now + min(SHOW_BASE + n * SHOW_PER_CHAR, SHOW_MAX)

    opened = time.monotonic()
    talk_until, close_at = timing(first)
    rect = saved = None   # パネルの描いてある範囲と、その下にあった絵
    while True:
        now = time.monotonic()
        try:
            msg = inbox.get_nowait()
        except queue.Empty:
            pass
        else:
            panel.add(msg)
            talk_until, close_at = timing(msg)
        if now >= close_at:
            break
        img = panel.image.copy()
        wave.draw(img, panel, now < talk_until)
        k = min((now - opened) / OPEN_TIME, 1.0)   # 上から下へ開く
        img, x, y = place(img)
        if (x, y, img.width, img.height) != rect:
            if rect:    # 発言が足されて大きさが変わった。いったん消してから、新しい範囲の絵を取っておく
                fb.put(rect, saved)
                repaint()
                time.sleep(0.05)
            rect = (x, y, img.width, img.height)
            saved = fb.grab(rect)
        fb.blit(img, x, y, max(int(img.height * k), 1) if k < 1 else None)
        time.sleep(max(1 / FPS - (time.monotonic() - now), 0.005))
    if rect:
        fb.put(rect, saved)
    repaint()


def poll(inbox):
    """中継から新着を読み続けて inbox に入れる。起動したときに既にあった発言は出さない"""
    after = None
    while True:
        url = URL + "/discord.json" + ("" if after is None else "?after=%d&wait=45" % after)
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                data = json.load(r)
        except (OSError, ValueError) as e:
            sys.stderr.write("poll: %r\n" % (e,))
            time.sleep(10)
            continue
        if after is None:
            after = data["last"]
            sys.stderr.write("connected: %s after=%d\n" % (URL, after))
            continue
        for m in data["msgs"]:
            after = max(after, m["id"])
            sys.stderr.write("msg %s: %s\n" % (m["author"], m["text"]))
            inbox.put(m)


def main():
    ap = argparse.ArgumentParser(description="Discord の通知を F1 のチームラジオ風に出す")
    ap.add_argument("--test", nargs="+", metavar=("NAME", "TEXT"),
                    help="中継につながず、NAME の発言 TEXT を表示して終わる。TEXT が @名前:本文 なら別の人の発言")
    ap.add_argument("--channel", default="test", help="--test のときのチャンネル名")
    args = ap.parse_args()

    fb = Framebuffer(FB)
    inbox = queue.Queue()
    if args.test:
        name, texts = args.test[0], args.test[1:] or ["Radio check."]
        for t in texts:
            m = re.match(r"@([^:]+):(.*)", t, re.S)
            inbox.put({"author": m.group(1) if m else name, "text": m.group(2) if m else t,
                       "channel": args.channel})
        first = inbox.get()
        # 2 つ目からは少し遅れて届いたことにする
        rest = []
        while not inbox.empty():
            rest.append(inbox.get())

        def later():
            for m in rest:
                time.sleep(2.5)
                inbox.put(m)
        threading.Thread(target=later, daemon=True).start()
        show(fb, first, inbox)
        return

    threading.Thread(target=poll, args=(inbox,), daemon=True).start()
    while True:
        show(fb, inbox.get(), inbox)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        repaint()
