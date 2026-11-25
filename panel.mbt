// パネルの絵

///|
/// 1 つの発言
struct Msg {
  author : String
  text : String
  channel : String?
  number : String? // 番号と色を、名前から決まるものの代わりに指定する
  color : Int?
  source : String? // 見出しの右に出す発言元。無ければ DISCORD
}

///|
/// パネルに並べる 1 つの発言。mine は開いた人の発言、label はほかの人の名前
struct Entry {
  mine : Bool
  label : Array[Char]?
  lines : Array[Array[Char]]
  at : Double // 届いた時刻
  lead : Int // タスクバーのとき、1 行目の頭の何字が名前か (ほかの人の発言は、名前を本文の頭に付ける)
}

///|
const HEAD_H : Int = 76

///|
const BAND_H : Int = 58

///|
/// 本文の 1 行の高さ
fn line_h() -> Int {
  (settings.text_size.to_double() * 1.37).round().to_int()
}

///|
/// 1 回の表示。開いた人 (owner) の発言は色付きで右寄せ、その間に来たほかの人の発言は白で左寄せ。
/// タスクバーに出すとき (bar) は横長にして、本文は何行かずつ送って見せる
struct Panel {
  owner : String
  number : Array[Char]
  color : Int
  source : Array[Char]
  channel : Array[Char]?
  channel_size : Int // チャンネル名の字の大きさ (長い名前は、切らずに済むように小さくする)
  msgs : Array[Entry]
  bar : BarLayout?
  mut scroll : Double // タスクバーのとき、本文の欄のいちばん上に出ている行 (全発言を通した行番号。送る途中は端数)
  mut stepped : Double // scroll を最後に寄せた時刻
  mut image : Image
}

///|
fn Panel::new(msg : Msg, bar : BarLayout?) -> Panel {
  let (number, color) = driver(msg.author)
  let number = msg.number.unwrap_or(number.to_string()).to_array()
  let color = msg.color.unwrap_or(color)
  let mut channel_size = settings.channel_size
  let channel = match (msg.channel, bar) {
    (Some(ch), Some(l)) if ch != "" => {
      // タスクバーでは見出しの行に入るだけ。切り方は描くときに決める
      channel_size = l.caption_size
      Some(['#', ..clean(ch)])
    }
    (Some(ch), None) if ch != "" => {
      // チャンネル名は帯の右に、幅の 4 割まで。はみ出すなら字を小さくし、それでも駄目なら末尾を切る
      let limit = (settings.width - PAD * 2).to_double() * 0.4
      let ch = ['#', ..clean(ch)]
      channel_size = fit_font(ch, channel_size, limit, 12)
      Some(ellipsize(ch, channel_size, limit))
    }
    _ => None
  }
  let panel = {
    owner: msg.author,
    number,
    color,
    source: upper(clean(msg.source.unwrap_or("Discord"))),
    channel,
    channel_size,
    msgs: [],
    bar,
    scroll: 0,
    stepped: 0,
    image: Image::new(1, 1, BG),
  }
  panel.add(msg)
  panel.scroll = panel.scroll_target(c_now()).to_double() // 開いたときは送らずに出す
  panel
}

///|
fn Panel::add(self : Panel, msg : Msg) -> Unit {
  let text = upper(clean(msg.text))
  let text = if text.is_empty() { ['…'] } else { text }
  let mine = msg.author == self.owner
  let label = if mine { None } else { Some(upper(clean(msg.author))) }
  match self.bar {
    Some(l) => {
      // 名前を付けた発言を、本文の欄の幅で行に分ける。名前の字は描くときに色を変える
      let name = label.unwrap_or([])
      let lead = if name.is_empty() { [] } else { [..name, ' '] }
      let lines = wrap(
        [..lead, '“', ..text, '”'],
        l.text_size,
        l.text.w.to_double(),
      )
      let lead = Int::min(name.length(), lines[0].length())
      self.msgs.push({ mine, label, lines, at: c_now(), lead, })
      // 古い発言は、溜まりすぎたら落とす。落とした行のぶん、出している位置も戻す
      while self.msgs.length() > 1 && self.line_count() > MAX_LINES * 2 {
        let gone = self.msgs.remove(0)
        self.scroll = Double::max(
          self.scroll - gone.lines.length().to_double(),
          0,
        )
      }
      self.image = self.render_bar(l)
    }
    None => {
      let lines = wrap(
        ['“', ..text, '”'],
        settings.text_size,
        (settings.width - PAD * 2 - 22).to_double(),
      )
      self.msgs.push({ mine, label, lines, at: c_now(), lead: 0, })
      while self.msgs.length() > 1 && self.height() > MAX_HEIGHT {
        self.msgs.remove(0) |> ignore
      }
      self.image = self.render()
    }
  }
}

///|
fn Panel::height(self : Panel) -> Int {
  let mut h = HEAD_H + BAND_H + 12
  for m in self.msgs {
    h += (if m.label is Some(_) { 18 } else { 0 }) +
      m.lines.length() * line_h() +
      12
  }
  h + 4
}

///|
/// 動かない部分の絵 (波形はコマごとに描き足す)
fn Panel::render(self : Panel) -> Image {
  let width = settings.width
  let img = Image::new(width, self.height(), BG)
  let inner = (width - PAD * 2).to_double()
  // 名前 (色) と発言元 (白。DISCORD か CLAUDE)
  let name = upper(clean(self.owner))
  let name = if name.is_empty() { ['?'] } else { name }
  let size = fit_font(name, 34, inner, 20)
  img.text(ellipsize(name, size, inner), size, PAD, 24, self.color)
  img.text(
    ellipsize(self.source, 30, inner),
    30,
    width - PAD,
    56,
    WHITE,
    right=true,
  )
  // 番号と波形の帯
  let top = HEAD_H
  img.rect(0, top, width, top + BAND_H, BG_BAND)
  img.text(self.number, 50, PAD, top + BAND_H / 2, mix(self.color, BG_BAND))
  if self.channel is Some(ch) {
    img.text(
      ch,
      self.channel_size,
      width - PAD,
      top + BAND_H / 2,
      WHITE,
      right=true,
    )
  }
  img.rect(0, top + BAND_H, width, top + BAND_H + 2, self.color)
  // 発言
  let mut y = top + BAND_H + 14
  for m in self.msgs {
    if m.label is Some(label) {
      img.text(ellipsize(label, 13, inner), 13, PAD, y + 7, LABEL)
      y += 18
    }
    for line in m.lines {
      if m.mine {
        img.text(
          line,
          settings.text_size,
          width - PAD,
          y + line_h() / 2,
          self.color,
          right=true,
        )
      } else {
        img.text(line, settings.text_size, PAD, y + line_h() / 2, WHITE)
      }
      y += line_h()
    }
    y += 12
  }
  img
}

///|
/// このコマの絵。波形はまだ描いていない
fn Panel::frame(self : Panel, now : Double) -> Image {
  let img = self.image.copy()
  if self.bar is Some(l) {
    self.draw_lines(img, l, now)
  }
  img
}

///|
/// 波形を描く範囲 (x0, x1, 中心の y, 高さの半分)
fn Panel::wave_box(self : Panel) -> (Int, Int, Int, Int) {
  if self.bar is Some(l) {
    let x0 = l.stripe +
      l.pad +
      text_width(self.number, l.number_size).to_int() +
      l.pad / 2
    return (x0, l.id_w - l.pad, l.number_cy, l.number_size * 2 / 5)
  }
  let x0 = PAD + text_width(self.number, 50).to_int() + 12
  let x1 = settings.width -
    PAD -
    (match self.channel {
      Some(ch) => text_width(ch, self.channel_size).to_int() + 12
      None => 0
    })
  (x0, x1, HEAD_H + BAND_H / 2, BAND_H / 2 - 8)
}

// ---------------- タスクバーに出すとき ----------------

///|
/// 1 行を読むのにかける秒数 (1 字あたりと、短い行でも最低これだけ)
const READ_PER_CHAR : Double = 0.1

///|
const READ_MIN : Double = 1.5

///|
/// 最後の行を出してから消すまでの秒数
const READ_TAIL : Double = 2.5

///|
/// タスクバーに出すときの並び。task-var から借りた w x h (再生情報パネルの左端からタスクバーの右端まで、縦はタスクバーの高さ) に合わせる
/// (高さ 64 を基準に伸び縮みする)。
/// 左に名乗りの欄 (色の帯、名前、番号と波形)、右に本文の欄 (上にチャンネル名と発言元、その下に本文を rows 行)
struct BarLayout {
  w : Int
  h : Int
  id_w : Int // 名乗りの欄の幅
  stripe : Int // 左端の色の帯の幅
  pad : Int
  name_size : Int
  name_cy : Int
  number_size : Int
  number_cy : Int
  caption_size : Int // チャンネル名と発言元の字の大きさ
  caption_cy : Int
  text_size : Int
  line_h : Int
  text : Rect // 本文の欄 (パネルの中の位置)
  rows : Int // 本文の欄に並ぶ行数
}

///|
fn BarLayout::new(w : Int, h : Int) -> BarLayout {
  let k = h.to_double() / 64.0
  fn px(v : Double) -> Int {
    Int::max((v * k).round().to_int(), 1)
  }

  let id_w = Int::min(px(112), w / 3)
  let pad = px(10)
  let text_size = settings.bar_text_size.unwrap_or(px(15))
  let line_h = (text_size.to_double() * 1.2).round().to_int()
  let text_x = id_w + 2 + pad
  let text_y = px(24)
  let text = {
    x: text_x,
    y: text_y,
    w: Int::max(w - pad - text_x, 1),
    h: Int::max(h - text_y, 1),
  }
  {
    w,
    h,
    id_w,
    stripe: px(4),
    pad,
    name_size: px(19),
    name_cy: px(21),
    number_size: px(21),
    number_cy: px(44),
    caption_size: Int::max(px(12), 8),
    caption_cy: px(12),
    text_size,
    line_h,
    text,
    rows: Int::max(text.h / line_h, 1),
  }
}

///|
/// 動かない部分の絵 (本文と波形はコマごとに描き足す)
fn Panel::render_bar(self : Panel, l : BarLayout) -> Image {
  let img = Image::new(l.w, l.h, BG)
  // 名乗りの欄: 色の帯、名前 (色)、番号 (暗めの色)。右の仕切りも色
  img.rect(0, 0, l.id_w - 1, l.h - 1, BG_BAND)
  img.rect(0, 0, l.stripe - 1, l.h - 1, self.color)
  img.rect(l.id_w, 0, l.id_w + 1, l.h - 1, self.color)
  let inner = (l.id_w - l.stripe - l.pad * 2).to_double()
  let name = upper(clean(self.owner))
  let name = if name.is_empty() { ['?'] } else { name }
  let size = fit_font(
    name,
    l.name_size,
    inner,
    Int::max(l.name_size * 2 / 3, 6),
  )
  img.text(
    ellipsize(name, size, inner),
    size,
    l.stripe + l.pad,
    l.name_cy,
    self.color,
  )
  img.text(
    self.number,
    l.number_size,
    l.stripe + l.pad,
    l.number_cy,
    mix(self.color, BG_BAND),
  )
  // 見出しの行: チャンネル名 (灰) と、右に発言元 (白。DISCORD か CLAUDE)
  let right = l.text.x + l.text.w
  let source = ellipsize(self.source, l.caption_size, l.text.w.to_double() / 2)
  img.text(source, l.caption_size, right, l.caption_cy, WHITE, right=true)
  if self.channel is Some(ch) {
    let room = (l.text.w - text_width(source, l.caption_size).to_int() - l.pad).to_double()
    img.text(
      ellipsize(ch, l.caption_size, room),
      l.caption_size,
      l.text.x,
      l.caption_cy,
      LABEL,
    )
  }
  img
}

///|
/// 全発言を通した行数
fn Panel::line_count(self : Panel) -> Int {
  let mut n = 0
  for m in self.msgs {
    n += m.lines.length()
  }
  n
}

///|
fn read_time(line : Array[Char]) -> Double {
  Double::max(READ_MIN, line.length().to_double() * READ_PER_CHAR)
}

///|
/// いちばん新しい発言の頭の行番号と、その発言の行を読むのにかかる秒数の並び
fn Panel::newest(self : Panel) -> (Int, Entry, Array[Double]) {
  let last = self.msgs[self.msgs.length() - 1]
  (self.line_count() - last.lines.length(), last, last.lines.map(read_time))
}

///|
/// 本文の欄のいちばん上に出すべき行。新しい発言は頭の rows 行から出し、読み終わるころに 1 行ずつ送る
/// (字幕のロールアップ。いちばん下の行が読み終わったら、次の行を下から出す)
fn Panel::scroll_target(self : Panel, now : Double) -> Int {
  guard self.bar is Some(l) else { return 0 }
  let (first, entry, times) = self.newest()
  let last = self.line_count() - 1
  // いま下の行に出ている行 (bottom) と、それを読み終わる時刻 (until)
  let mut bottom = Int::min(first + l.rows - 1, last)
  let mut until = entry.at
  for i in first..<=bottom {
    until += times[i - first]
  }
  while bottom < last && now >= until {
    bottom += 1
    until += times[bottom - first]
  }
  Int::max(bottom - l.rows + 1, 0)
}

///|
/// いちばん新しい発言を最後まで読み終わって、消してよい時刻。浮かせて出すときは close_at のまま
fn Panel::close_after(self : Panel, close_at : Double) -> Double {
  guard self.bar is Some(_) else { return close_at }
  let (_, entry, times) = self.newest()
  let mut until = entry.at
  for t in times {
    until += t
  }
  Double::max(close_at, until + READ_TAIL)
}

///|
/// 本文を描く。出す位置 (scroll) は目当ての行へ少しずつ寄せて、行が下から滑って出てくるようにする
fn Panel::draw_lines(
  self : Panel,
  img : Image,
  l : BarLayout,
  now : Double,
) -> Unit {
  // 寄せるのは FPS のコマごとに 1 回 (滑らせている間はコマを増やすが、送りの速さは変えない)
  let target = self.scroll_target(now).to_double()
  if now - self.stepped >= STEP {
    self.stepped = now
    self.scroll += (target - self.scroll) * 0.45
    if (target - self.scroll).abs() < 0.02 {
      self.scroll = target
    }
  }
  // 行は本文の欄の中だけに描く (送る途中ではみ出す行を切る)。欄に満たない行数なら上下の真ん中に寄せる
  let area = Image::new(l.text.w, l.text.h, BG)
  let shown = Int::min(self.line_count(), l.rows)
  let top = (l.text.h - shown * l.line_h) / 2
  let mut i = 0
  for m in self.msgs {
    for n, line in m.lines {
      let cy = top +
        ((i.to_double() - self.scroll) * l.line_h.to_double()).round().to_int() +
        l.line_h / 2
      // 出ている行だけ描く (送り終えた行の句読点などが、欄の端にはみ出して残らないように)
      let at = i.to_double()
      if at > self.scroll - 1 && at < self.scroll + l.rows.to_double() {
        let lead = if n == 0 { m.lead } else { 0 }
        if lead > 0 {
          let name = line[:lead].to_owned()
          area.text(name, l.text_size, 0, cy, LABEL)
          area.text(
            line[lead:].to_owned(),
            l.text_size,
            text_width(name, l.text_size).round().to_int(),
            cy,
            WHITE,
          )
        } else {
          area.text(line, l.text_size, 0, cy, WHITE)
        }
      }
      i += 1
    }
  }
  img.paste(area, l.text.x, l.text.y)
}

///|
const BAR : Int = 3

///|
const GAP : Int = 2

///|
/// チームラジオの波形。しゃべっている間は大きく、あとは小さく揺れる
struct Wave {
  mut levels : Array[Double]
  mut stepped : Double // levels を最後に動かした時刻
  rand : @random.Rand
}

///|
fn Wave::new() -> Wave {
  { levels: [], stepped: 0, rand: @random.Rand::new(), }
}

///|
/// 揺らすのは FPS のコマごとに 1 回 (滑らせている間はコマを増やすが、揺れの速さは変えない)
fn Wave::draw(
  self : Wave,
  img : Image,
  panel : Panel,
  talking : Bool,
  now : Double,
) -> Unit {
  let (x0, x1, cy, half) = panel.wave_box()
  let n = Int::max((x1 - x0) / (BAR + GAP), 0)
  if self.levels.length() != n {
    self.levels = Array::make(n, 0.0)
  }
  let step = now - self.stepped >= STEP
  if step {
    self.stepped = now
  }
  let light = mix(panel.color, 0xFFFFFF)
  for i in 0..<n {
    if step {
      let r = self.rand.double()
      // 真ん中ほど大きい山にする
      let pos = i.to_double() / Int::max(n - 1, 1).to_double()
      let target = r *
        r *
        (if talking { 1.0 } else { 0.12 }) *
        (0.35 + 0.65 * (1 - (pos * 2 - 1).abs()))
      self.levels[i] += (target - self.levels[i]) * 0.55
    }
    let h = Int::max((self.levels[i] * half.to_double()).to_int(), 1)
    let x = x0 + i * (BAR + GAP)
    img.rect(x, cy - h, x + BAR - 1, cy + h, light)
  }
}
