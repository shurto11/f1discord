// タッチ。パネルを触ったら消す。
// タッチパネルは touch-server (~/ssd/fb/touch/touch-server) が 1 人で読んで配っているので、そこにパネルの範囲を
// 申告して、その中のタッチだけを受け取る。touch-server が動いていなければ、何もしない

///|
/// 範囲が重なったときの優先度。全画面のものやタスクバー (10) より上にパネルが出るので、それより大きくする
const TOUCH_PRIORITY : Int = 20

///|
struct Touch {
  mut buf : String // 届いたうち、まだ行になっていないぶん
}

///|
fn touch_socket() -> String {
  match
    (@env.get_env_var("TOUCH_SERVER_SOCK"), @env.get_env_var("XDG_RUNTIME_DIR")) {
    (Some(p), _) if p != "" => p
    (_, Some(d)) if d != "" => "\{d}/touch-server.sock"
    _ => "/tmp/touch-server.sock"
  }
}

///|
/// 画面 (fb) の上の rect を、触ったら知らせてもらう範囲として申告する
fn Touch::watch(self : Touch, fb : Framebuffer, rect : Rect) -> Unit {
  let w = fb.width.to_double()
  let h = fb.height.to_double()
  let left = rect.x.to_double() / w
  let top = rect.y.to_double() / h
  let right = (rect.x + rect.w).to_double() / w
  let bottom = (rect.y + rect.h).to_double() / h
  let hello =
    $|{"hello":"f1discord","pane":null,"region":{"left":\{left},"top":\{top},"right":\{right},"bottom":\{bottom}},"priority":\{TOUCH_PRIORITY}}
    $|
  self.buf = ""
  c_touch_open(cstr(touch_socket()), @utf8.encode(hello)) |> ignore
}

///|
/// 範囲の中を触って離したか
fn Touch::tapped(self : Touch) -> Bool {
  let mut tapped = false
  while true {
    let data = c_touch_read()
    if data.length() == 0 {
      break
    }
    self.buf = self.buf + text_of(data)
    while self.buf.find("\n") is Some(end) {
      let line = self.buf[:end].to_owned()
      self.buf = self.buf[end + 1:].to_owned()
      if parse_json(line) is Ok(event) &&
        field(event, "type") is Some(String("up")) {
        tapped = true
      }
    }
  }
  tapped
}

///|
fn Touch::close(_self : Touch) -> Unit {
  c_touch_close()
}
