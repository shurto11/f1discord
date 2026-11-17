// f1discord: Discord の通知を、F1 中継のチームラジオ風のパネルで画面に出す。
//
// dynabook の espoke の中継 (discord_relay.py --notify) が Discord アプリの通知から拾った発言を、
// 地図のサーバーの /discord.json (tailnet の中だけ) から読み、この PC のフレームバッファ (/dev/fb0) に直接描く。
// X も Wayland も無い fbterm + tmux の画面の上に重ねる。消すときは tmux に描き直させる。
//
//     ./f1discord                       # 常駐して、新着を表示する
//     ./f1discord --test 名前 "本文"    # 中継につながず、1 回だけ表示して終わる (本文は何個でも。@名前:本文 で別の人)
//     ./f1discord --claude              # Claude Code の Stop フックに書く。回答が終わったら、常駐しているほうに
//                                       # 回答を送って表示させる (色は Claude のオレンジ、番号はモデルの 5.2 など)
//
// make で ./f1discord ができる (MoonBit の native バックエンド。OS と FreeType を呼ぶところだけ stub.c)。
// 要るもの: moon、gcc、libfreetype-dev。
//
// パネルを触ると、時間が来る前に消える (touch-server が動いているとき)。
//
// 設定は config.json (実行ファイルの隣。無くてよい) に書く。変えたら systemctl --user restart f1discord。
// 同じ名前を大文字にして F1DISCORD_ を付けた環境変数 (F1DISCORD_TEXT_SIZE など) があれば、そちらを使う:
//     url           中継の地図のサーバー。既定 http://100.85.213.75:8020 (dynabook の tailnet の IP)
//     pos           パネルの位置。top / bottom と left / right の組み合わせ。既定 bottom-right
//     margin_x      画面の左右の端からの距離 (画面のピクセル数)。既定 0
//     margin_y      画面の上下の端からの距離。既定 64 (画面の下のタスクバーの高さ。パネルの下辺がその上辺に付く)
//                   画面は液晶の全体 (1366x768)。fbterm と tmux が使うのはその左上の 1280x720 だけ
//     scale         全体の大きさの倍率。既定 0.5
//     width         パネルの幅。既定 330
//     text_size     本文の字の大きさ。既定 19
//     channel_size  チャンネル名の字の大きさ。既定 15
//     fb            フレームバッファ。既定 /dev/fb0
//     drivers       名前ごとの番号と色。無い人は、名前から決まる番号と色になる (いつも同じ)
// 幅と字の大きさは倍率を掛ける前のピクセル数で、画面ではそれに scale を掛けた大きさになる。例:
//     {"text_size": 26, "channel_size": 20, "drivers": {"名前": {"number": 81, "color": "#FF8000"}}}

///|
/// 届いた発言の列。中継から読む (live) か、--test の発言を時刻どおりに出す
struct Inbox {
  queue : Array[Msg]
  later : Array[(Double, Msg)] // --test で、少し遅れて届いたことにする発言と、その時刻
  live : Bool
  mut after : Int64? // ここまで読んだ、という発言の id。None はまだつながっていない
  mut requesting : Bool
  mut retry_at : Double // 失敗したあと、次に読みに行く時刻
}

///|
fn Inbox::new(live : Bool) -> Inbox {
  { queue: [], later: [], live, after: None, requesting: false, retry_at: 0, }
}

///|
/// 届いていれば、いちばん古い発言
fn Inbox::take(self : Inbox) -> Msg? {
  self.pump(0)
  if self.queue.is_empty() {
    None
  } else {
    Some(self.queue.remove(0))
  }
}

///|
/// 届いていれば、channel の発言のうちいちばん古いもの。ほかのチャンネルの発言は queue に残しておく
fn Inbox::take_in(self : Inbox, channel : String) -> Msg? {
  self.pump(0)
  for i, m in self.queue {
    if channel_of(m) == channel {
      return Some(self.queue.remove(i))
    }
  }
  None
}

///|
/// 発言のチャンネル名。無いのと空なのは同じに扱う
fn channel_of(msg : Msg) -> String {
  msg.channel.unwrap_or("")
}

///|
/// 新着を queue に入れる。無ければ ms ミリ秒まで待つ
fn Inbox::pump(self : Inbox, ms : Int) -> Unit {
  let now = c_now()
  while self.later.length() > 0 && self.later[0].0 <= now {
    self.queue.push(self.later.remove(0).1)
  }
  if !self.live {
    c_sleep(ms.to_double() / 1000)
    return
  }
  self.receive_local()
  if !self.requesting {
    if now < self.retry_at {
      c_sleep(Double::min(ms.to_double() / 1000, self.retry_at - now))
      return
    }
    // 最初の 1 回は、起動したときに既にあった発言を出さないように、いまの最後の id だけ読む
    let query = match self.after {
      None => ""
      Some(after) => "?after=\{after}&wait=45"
    }
    c_http_start(cstr(settings.url + "/discord.json" + query))
    self.requesting = true
  }
  match c_http_wait(ms) {
    2 => {
      self.requesting = false
      if self.receive(text_of(c_http_take())) is Err(e) {
        eprint("poll: \{e}\n")
        self.retry_at = c_now() + 10
      }
    }
    3 => {
      self.requesting = false
      eprint("poll: \{text_of(c_http_take())}\n")
      self.retry_at = c_now() + 10
    }
    _ => ()
  }
}

///|
/// 中継の返事 {"last": id, "msgs": [{"id", "author", "text", "channel"}, ...]} を読む
fn Inbox::receive(self : Inbox, body : String) -> Result[Unit, String] {
  let data = match parse_json(body) {
    Ok(j) => j
    Err(e) => return Err(e)
  }
  guard self.after is Some(after) else {
    guard field(data, "last") is Some(j) && int64_of(j) is Some(last) else {
      return Err("last が無い")
    }
    self.after = Some(last)
    eprint("connected: \{settings.url} after=\{last}\n")
    return Ok(())
  }
  guard field(data, "msgs") is Some(Array(msgs)) else {
    return Err("msgs が無い")
  }
  let mut after = after
  for m in msgs {
    guard field(m, "id") is Some(j) &&
      int64_of(j) is Some(id) &&
      field(m, "author") is Some(String(author)) &&
      field(m, "text") is Some(String(text)) else {
      return Err("発言が読めない: \{m.stringify()}")
    }
    let channel = match field(m, "channel") {
      Some(String(ch)) => Some(ch)
      _ => None
    }
    after = Int64::max(after, id)
    self.after = Some(after)
    eprint("msg \{author}: \{text}\n")
    self.queue.push({ author, text, channel, number: None, color: None, })
  }
  Ok(())
}

///|
/// JSON の整数。id は Double に入りきらない大きさ (2^53 より上) なので、元の字の並びから読む
fn int64_of(j : Json) -> Int64? {
  guard j is Number(n, repr~) else { return None }
  if repr is Some(s) {
    let mut v = 0L
    let mut digits = true
    for c in s {
      if c >= '0' && c <= '9' {
        v = v * 10L + (c.to_int() - '0'.to_int()).to_int64()
      } else {
        digits = false
        break
      }
    }
    if digits && s != "" {
      return Some(v)
    }
  }
  Some(n.to_int64())
}

///|
fn tmux_socket() -> String? {
  if @env.get_env_var("TMUX") is Some(tmux) && tmux != "" {
    for part in tmux.split(",") {
      return Some(part.to_owned())
    }
  }
  let uid = c_getuid()
  for
    dir in [
      @env.get_env_var("TMUX_TMPDIR"),
      Some("/run/user/\{uid}"),
      Some("/tmp"),
    ] {
    if dir is Some(d) && d != "" && c_exists(cstr("\{d}/tmux-\{uid}/default")) {
      return Some("\{d}/tmux-\{uid}/default")
    }
  }
  None
}

///|
/// シェルに渡す引数として引用する
fn quote(s : String) -> String {
  "'" + s.replace_all(old="'", new="'\\''") + "'"
}

///|
/// パネルを消す。fbterm は自分の描いた字しか覚えていないので、tmux に画面を全部描き直させる。
/// tmux の外 (画面の右端と下) は、呼ぶ側が描く前の絵を取っておいて戻す
fn repaint() -> Unit {
  guard tmux_socket() is Some(sock) else { return }
  let tmux = "timeout 5 tmux -S " + quote(sock)
  let clients = text_of(
    c_capture(cstr(tmux + " list-clients -F '#{client_name}'")),
  )
  for client in clients.split("\n") {
    let client = client.trim().to_owned()
    if client != "" {
      c_capture(cstr(tmux + " refresh-client -t " + quote(client))) |> ignore
    }
  }
}

///|
/// first の発言でパネルを開き、消えるまでに inbox に来た同じチャンネルの発言は同じパネルに足す。
/// ほかのチャンネルの発言は、このパネルが消えてから次のパネルで出す
fn show(fb : Framebuffer, first : Msg, inbox : Inbox) -> Unit {
  let panel = Panel::new(first)
  let wave = Wave::new()
  let scale = settings.scale
  // 波形を大きく動かす終わりの時刻と、パネルを消す時刻
  fn timing(msg : Msg) -> (Double, Double) {
    let n = msg.text.char_length().to_double()
    let now = c_now()
    (
      now + TALK_BASE + n * 0.05,
      now + Double::min(SHOW_BASE + n * SHOW_PER_CHAR, SHOW_MAX),
    )
  }

  let opened = c_now()
  let (t, c) = timing(first)
  let mut talk_until = t
  let mut close_at = c
  let mut drawn : (Rect, FixedArray[Byte])? = None // パネルの描いてある範囲と、その下にあった絵
  let touch : Touch = { buf: "", }
  while !c_interrupted() {
    let now = c_now()
    if inbox.take_in(channel_of(first)) is Some(msg) {
      panel.add(msg)
      let (t, c) = timing(msg)
      talk_until = t
      close_at = c
    }
    if now >= close_at || touch.tapped() { // 時間が来たか、パネルを触った
      break
    }
    let img = panel.image.copy()
    wave.draw(img, panel, now < talk_until)
    let k = Double::min((now - opened) / OPEN_TIME, 1.0) // 上から下へ開く
    // 倍率を掛けた絵と、その左上の位置
    let img = if scale != 1 {
      img.resize(
        Int::max((img.w.to_double() * scale).round().to_int(), 1),
        Int::max((img.h.to_double() * scale).round().to_int(), 1),
      )
    } else {
      img
    }
    let x = if settings.pos.contains("left") {
      settings.margin_x
    } else {
      fb.width - img.w - settings.margin_x
    }
    let y = if settings.pos.contains("top") {
      settings.margin_y
    } else {
      fb.height - img.h - settings.margin_y
    }
    let rect = { x, y, w: img.w, h: img.h, }
    if !(drawn is Some((r, _)) && r == rect) {
      if drawn is Some((r, saved)) { // 発言が足されて大きさが変わった。いったん消してから、新しい範囲の絵を取っておく
        fb.put(r, saved)
        repaint()
        c_sleep(0.05)
      }
      drawn = Some((rect, fb.grab(rect)))
      touch.watch(fb, rect)
    }
    fb.blit(
      img,
      x,
      y,
      if k < 1 {
        Int::max((img.h.to_double() * k).to_int(), 1)
      } else {
        img.h
      },
    )
    c_sleep(Double::max(1 / FPS - (c_now() - now), 0.005))
  }
  touch.close()
  if drawn is Some((r, saved)) {
    fb.put(r, saved)
  }
  repaint()
}

///|
const USAGE : String =
  #|usage: f1discord [-h] [--test NAME [TEXT ...]] [--channel CHANNEL] [--claude]
  #|
  #|Discord の通知を F1 のチームラジオ風に出す
  #|
  #|options:
  #|  -h, --help            この説明を出して終わる
  #|  --test NAME [TEXT ...]
  #|                        中継につながず、NAME の発言 TEXT を表示して終わる。TEXT が @名前:本文 なら別の人の発言
  #|  --channel CHANNEL     --test のときのチャンネル名
  #|  --claude              Claude Code の Stop フック。標準入力のフックの JSON を読んで、常駐しているほうに回答を送る
  #|

///|
fn main {
  c_init()
  let args = @env.args()
  let mut test_words : Array[String]? = None
  let mut channel = "test"
  let mut i = 1
  while i < args.length() {
    match args[i] {
      "-h" | "--help" => {
        println(USAGE)
        return
      }
      "--test" => {
        let words : Array[String] = []
        while i + 1 < args.length() && !args[i + 1].has_prefix("--") {
          i += 1
          words.push(args[i])
        }
        if words.is_empty() {
          die("--test には名前が要る")
        }
        test_words = Some(words)
      }
      "--claude" => {
        claude_hook()
        return
      }
      "--channel" if i + 1 < args.length() => {
        i += 1
        channel = args[i]
      }
      arg => {
        eprint(USAGE)
        die("分からない引数: \{arg}")
      }
    }
    i += 1
  }

  let fb = Framebuffer::open(settings.fb)
  if c_font_open(cstr(FONT), 0) != 0 {
    die("フォントが開けない: \{FONT}")
  }
  if test_words is Some(words) {
    let inbox = Inbox::new(false)
    let name = words[0]
    let texts = if words.length() > 1 {
      words[1:].to_owned()
    } else {
      ["Radio check."]
    }
    let start = c_now()
    for n, t in texts {
      // @名前:本文 は別の人の発言
      let msg = if t.has_prefix("@") && t.find(":") is Some(colon) && colon > 1 {
        {
          author: t[1:colon].to_owned(),
          text: t[colon + 1:].to_owned(),
          channel: Some(channel),
          number: None,
          color: None,
        }
      } else {
        {
          author: name,
          text: t,
          channel: Some(channel),
          number: None,
          color: None,
        }
      }
      // 2 つ目からは少し遅れて届いたことにする
      if n == 0 {
        inbox.queue.push(msg)
      } else {
        inbox.later.push((start + 2.5 * n.to_double(), msg))
      }
    }
    show(fb, inbox.queue.remove(0), inbox)
    return
  }

  if c_local_bind(cstr(socket_path())) != 0 {
    eprint("local: \{socket_path()} で待てない\n")
  }
  let inbox = Inbox::new(true)
  while !c_interrupted() {
    match inbox.take() {
      Some(msg) => show(fb, msg, inbox)
      None => inbox.pump(200)
    }
  }
}
