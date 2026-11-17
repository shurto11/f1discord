// 設定と、名前ごとの番号と色

///|
const FONT : String = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc" // index 0 が JP

///|
const FPS : Double = 15

///|
const PAD : Int = 14 // パネルの中の余白

///|
const MAX_HEIGHT : Int = 560 // パネルの高さの上限。超えたら古い発言から落とす

///|
const MAX_LINES : Int = 7 // 1 つの発言の行数の上限

///|
const SHOW_BASE : Double = 6.0 // 最後の発言が来てから消すまでの秒数 (これに字数ぶんを足す)

///|
const SHOW_PER_CHAR : Double = 0.09

///|
const SHOW_MAX : Double = 20.0

///|
const TALK_BASE : Double = 1.5 // 波形を大きく動かす秒数 (これに字数ぶんを足す)

///|
const OPEN_TIME : Double = 0.25 // 開くアニメーションの秒数

///|
const BG : Int = 0x0B101E

///|
const BG_BAND : Int = 0x131B30

///|
const WHITE : Int = 0xF5F5F5

///|
const LABEL : Int = 0x969EAF // ほかの人の名前の色

///|
/// 番号と色を決めていない人に、名前から割り当てる色
let team_colors : FixedArray[Int] = [
  0x3671C6, 0xE8002D, 0x27F4D2, 0xFF8000, 0x229971, 0xFF87BC, 0x64C4FF, 0x6692FF,
  0x52E252, 0xB6BABD,
]

///|
/// config.json の drivers の 1 人ぶん
struct Driver {
  number : Int?
  color : Int?
}

///|
struct Settings {
  url : String // 中継の地図のサーバー
  pos : String // パネルの位置。top / bottom と left / right の組み合わせ
  margin_x : Int // 画面の左右の端からの距離
  margin_y : Int // 画面の上下の端からの距離
  scale : Double // 全体の大きさの倍率
  width : Int // パネルの幅
  text_size : Int // 本文の字の大きさ
  channel_size : Int // チャンネル名の字の大きさ
  fb : String // フレームバッファ
  drivers : Map[String, Driver] // 名前 (fold_name したもの) ごとの番号と色
}

///|
let settings : Settings = load_settings()

///|
/// 実行ファイルの隣の config.json。無ければ空
fn load_config() -> Map[String, Json] {
  let path = text_of(c_exe_dir()) + "/config.json"
  if !c_exists(cstr(path)) {
    return Map([])
  }
  match parse_json(text_of(c_read_file(cstr(path)))) {
    Ok(Object(m)) => m
    Ok(_) => die("\{path} が JSON のオブジェクトでない")
    Err(e) => die("\{path} が読めない: \{e}")
  }
}

///|
fn parse_json(s : StringView) -> Result[Json, String] {
  try @json.parse(s) catch {
    e => Err(e.to_string())
  } noraise {
    v => Ok(v)
  }
}

///|
/// オブジェクトの key の値
fn field(j : Json, key : String) -> Json? {
  if j is Object(m) {
    m.get(key)
  } else {
    None
  }
}

///|
/// 文字列を数にする。数でなければ None
fn number_of(s : String) -> Double? {
  match parse_json(s.trim()) {
    Ok(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn load_settings() -> Settings {
  let config = load_config()
  // 環境変数 F1DISCORD_<NAME>、無ければ config.json の name。型は既定値に合わせる
  fn str(name : String, default : String) -> String {
    match (@env.get_env_var("F1DISCORD_" + name.to_upper()), config.get(name)) {
      (Some(s), _) | (None, Some(String(s))) => s
      (None, Some(j)) => j.stringify()
      (None, None) => default
    }
  }

  fn num(name : String, default : Double) -> Double {
    match (@env.get_env_var("F1DISCORD_" + name.to_upper()), config.get(name)) {
      (Some(s), _) | (None, Some(String(s))) =>
        match number_of(s) {
          Some(n) => n
          None => die("\{name} が数でない: \{s}")
        }
      (None, Some(Number(n, ..))) => n
      (None, Some(j)) => die("\{name} が数でない: \{j.stringify()}")
      (None, None) => default
    }
  }

  let drivers : Map[String, Driver] = Map([])
  if config.get("drivers") is Some(Object(m)) {
    for name, d in m {
      let number = match field(d, "number") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      let color = match field(d, "color") {
        Some(String(s)) => Some(hex_color(s))
        _ => None
      }
      drivers[fold_name(name)] = { number, color, }
    }
  }
  {
    url: str("url", "http://100.85.213.75:8020").trim_end(chars="/").to_owned(),
    pos: str("pos", "bottom-right"),
    margin_x: num("margin_x", 0).to_int(),
    margin_y: num("margin_y", 64).to_int(),
    scale: num("scale", 0.5),
    width: num("width", 330).to_int(),
    text_size: Int::max(num("text_size", 19).to_int(), 6),
    channel_size: Int::max(num("channel_size", 15).to_int(), 6),
    fb: str("fb", "/dev/fb0"),
    drivers,
  }
}

///|
/// "#RRGGBB" を 0xRRGGBB に
fn hex_color(s : String) -> Int {
  let mut v = 0
  let mut n = 0
  for c in s.trim_start(chars="#") {
    let d = match c {
      '0'..='9' => c.to_int() - '0'.to_int()
      'a'..='f' => c.to_int() - 'a'.to_int() + 10
      'A'..='F' => c.to_int() - 'A'.to_int() + 10
      _ => die("色が #RRGGBB でない: \{s}")
    }
    v = v * 16 + d
    n += 1
  }
  if n != 6 {
    die("色が #RRGGBB でない: \{s}")
  }
  v
}

///|
/// 名前を比べるための形にする。全角の英数字と記号を半角にして、小文字にそろえる
fn fold_name(name : String) -> String {
  let out = StringBuilder()
  for c in name {
    let o = c.to_int()
    let o = if o >= 0xFF01 && o <= 0xFF5E {
      o - 0xFEE0
    } else if o == 0x3000 {
      0x20
    } else {
      o
    }
    out.write_char(c_towlower(o).unsafe_to_char())
  }
  out.to_string()
}

///|
/// SHA-1 のダイジェストの先頭 4 バイト (ビッグエンディアン)
fn sha1_head(data : Bytes) -> UInt {
  let len = data.length()
  let total = (len + 9 + 63) / 64 * 64
  let msg = FixedArray::make(total, b'\x00')
  for i in 0..<len {
    msg[i] = data[i]
  }
  msg[len] = b'\x80'
  let bits = len.to_int64() * 8L
  for i in 0..<8 {
    msg[total - 1 - i] = (bits >> (i * 8)).to_int().to_byte()
  }
  let h : FixedArray[UInt] = [
    0x67452301U, 0xEFCDAB89U, 0x98BADCFEU, 0x10325476U, 0xC3D2E1F0U,
  ]
  let w = FixedArray::make(80, 0U)
  fn rotl(x : UInt, n : Int) -> UInt {
    (x << n) | (x >> (32 - n))
  }

  for block = 0; block < total; block = block + 64 {
    for i in 0..<16 {
      let p = block + i * 4
      w[i] = (msg[p].to_uint() << 24) |
        (msg[p + 1].to_uint() << 16) |
        (msg[p + 2].to_uint() << 8) |
        msg[p + 3].to_uint()
    }
    for i in 16..<80 {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
    }
    let mut a = h[0]
    let mut b = h[1]
    let mut c = h[2]
    let mut d = h[3]
    let mut e = h[4]
    for i in 0..<80 {
      let (f, k) = if i < 20 {
        (d ^ (b & (c ^ d)), 0x5A827999U)
      } else if i < 40 {
        (b ^ c ^ d, 0x6ED9EBA1U)
      } else if i < 60 {
        ((b & c) | (d & (b | c)), 0x8F1BBCDCU)
      } else {
        (b ^ c ^ d, 0xCA62C1D6U)
      }
      let t = rotl(a, 5) + f + e + k + w[i]
      e = d
      d = c
      c = rotl(b, 30)
      b = a
      a = t
    }
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
  }
  h[0]
}

///|
/// 名前の (番号, 色)。config.json に無ければ名前から決める (いつも同じ)
fn driver(name : String) -> (Int, Int) {
  let h = sha1_head(@utf8.encode(name))
  let d = settings.drivers.get(fold_name(name))
  let number = match d {
    Some({ number: Some(n), .. }) => n
    _ => (h % 99U).reinterpret_as_int() + 1
  }
  let color = match d {
    Some({ color: Some(c), .. }) => c
    _ => team_colors[((h >> 8) % 10U).reinterpret_as_int()]
  }
  (number, color)
}
