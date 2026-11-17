// パネルの絵

///|
/// 1 つの発言
struct Msg {
  author : String
  text : String
  channel : String?
  number : String? // 番号と色を、名前から決まるものの代わりに指定する
  color : Int?
}

///|
/// パネルに並べる 1 つの発言。mine は開いた人の発言、label はほかの人の名前
struct Entry {
  mine : Bool
  label : Array[Char]?
  lines : Array[Array[Char]]
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
/// 1 回の表示。開いた人 (owner) の発言は色付きで右寄せ、その間に来たほかの人の発言は白で左寄せ
struct Panel {
  owner : String
  number : Array[Char]
  color : Int
  channel : Array[Char]?
  channel_size : Int // チャンネル名の字の大きさ (長い名前は、切らずに済むように小さくする)
  msgs : Array[Entry]
  mut image : Image
}

///|
fn Panel::new(msg : Msg) -> Panel {
  let (number, color) = driver(msg.author)
  let number = msg.number.unwrap_or(number.to_string()).to_array()
  let color = msg.color.unwrap_or(color)
  // チャンネル名は帯の右に、幅の 4 割まで。はみ出すなら字を小さくし、それでも駄目なら末尾を切る
  let limit = (settings.width - PAD * 2).to_double() * 0.4
  let mut channel_size = settings.channel_size
  let channel = match msg.channel {
    Some(ch) if ch != "" => {
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
    channel,
    channel_size,
    msgs: [],
    image: Image::new(1, 1, BG),
  }
  panel.add(msg)
  panel
}

///|
fn Panel::add(self : Panel, msg : Msg) -> Unit {
  let text = upper(clean(msg.text))
  let text = if text.is_empty() { ['…'] } else { text }
  let mine = msg.author == self.owner
  let lines = wrap(
    ['“', ..text, '”'],
    settings.text_size,
    (settings.width - PAD * 2 - 22).to_double(),
  )
  let label = if mine { None } else { Some(upper(clean(msg.author))) }
  self.msgs.push({ mine, label, lines, })
  while self.msgs.length() > 1 && self.height() > MAX_HEIGHT {
    self.msgs.remove(0) |> ignore
  }
  self.image = self.render()
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
  // 名前 (色) と RADIO (白)
  let name = upper(clean(self.owner))
  let name = if name.is_empty() { ['?'] } else { name }
  let size = fit_font(name, 34, inner, 20)
  img.text(ellipsize(name, size, inner), size, PAD, 24, self.color)
  img.text(['R', 'A', 'D', 'I', 'O'], 30, width - PAD, 56, WHITE, right=true)
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
/// 波形を描く範囲 (x0, x1, 中心の y, 高さの半分)
fn Panel::wave_box(self : Panel) -> (Int, Int, Int, Int) {
  let x0 = PAD + text_width(self.number, 50).to_int() + 12
  let x1 = settings.width -
    PAD -
    (match self.channel {
      Some(ch) => text_width(ch, self.channel_size).to_int() + 12
      None => 0
    })
  (x0, x1, HEAD_H + BAND_H / 2, BAND_H / 2 - 8)
}

///|
const BAR : Int = 3

///|
const GAP : Int = 2

///|
/// チームラジオの波形。しゃべっている間は大きく、あとは小さく揺れる
struct Wave {
  mut levels : Array[Double]
  rand : @random.Rand
}

///|
fn Wave::new() -> Wave {
  { levels: [], rand: @random.Rand::new(), }
}

///|
fn Wave::draw(self : Wave, img : Image, panel : Panel, talking : Bool) -> Unit {
  let (x0, x1, cy, half) = panel.wave_box()
  let n = Int::max((x1 - x0) / (BAR + GAP), 0)
  if self.levels.length() != n {
    self.levels = Array::make(n, 0.0)
  }
  let light = mix(panel.color, 0xFFFFFF)
  for i in 0..<n {
    let r = self.rand.double()
    // 真ん中ほど大きい山にする
    let pos = i.to_double() / Int::max(n - 1, 1).to_double()
    let target = r *
      r *
      (if talking { 1.0 } else { 0.12 }) *
      (0.35 + 0.65 * (1 - (pos * 2 - 1).abs()))
    self.levels[i] += (target - self.levels[i]) * 0.55
    let h = Int::max((self.levels[i] * half.to_double()).to_int(), 1)
    let x = x0 + i * (BAR + GAP)
    img.rect(x, cy - h, x + BAR - 1, cy + h, light)
  }
}
