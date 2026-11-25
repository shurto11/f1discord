// タスクバー (task-var、~/ssd/fb/touch/task-var) の、Spotify の再生情報パネルの場所を借りてパネルを出す。
// task-var のソケットに {"cmd":"cover"} を送ると、借りられる範囲 {"x","y","w","h"} (画面のピクセル数。横は再生情報パネルの
// 左端からタスクバーの右端まで、縦はタスクバーの上端から下端まで) が返ってくる。つないでいる間は task-var がそこを描かないので、上書きし合ってチカチカしない。閉じると task-var が
// すぐ描き直す。貸せないとき (task-var がバーを隠している) は {} が返ってくる

///|
/// 借りている場所
struct Lease {
  fd : Int
  rect : Rect
}

///|
fn taskvar_socket() -> String {
  match @env.get_env_var("XDG_RUNTIME_DIR") {
    Some(d) if d != "" => "\{d}/task-var.sock"
    _ => "/tmp/task-var.sock"
  }
}

///|
/// 借りる。task-var が動いていない、または貸してくれなければ None
fn Lease::borrow() -> Lease? {
  let path = taskvar_socket()
  if !c_exists(cstr(path)) {
    return None
  }
  let fd = c_stream_open(cstr(path), @utf8.encode("{\"cmd\":\"cover\"}\n"))
  if fd < 0 {
    return None
  }
  // 返事の 1 行。task-var が止まっている (SIGSTOP) と返ってこないので、長くは待たない
  let mut reply = ""
  let deadline = c_now() + 0.5
  while !reply.contains("\n") && c_now() < deadline {
    let data = c_stream_read(fd, 50)
    if data.length() == 0 && !c_stream_alive(fd) {
      break
    }
    reply = reply + text_of(data)
  }
  fn int(j : Json, key : String) -> Int? {
    match field(j, key) {
      Some(Number(n, ..)) => Some(n.to_int())
      _ => None
    }
  }

  guard parse_json(reply.trim()) is Ok(j) &&
    int(j, "x") is Some(x) &&
    int(j, "y") is Some(y) &&
    int(j, "w") is Some(w) &&
    int(j, "h") is Some(h) &&
    w > 0 &&
    h > 0 else {
    c_stream_close(fd)
    return None
  }
  Some({ fd, rect: { x, y, w, h, }, })
}

///|
/// まだ借りていられるか。task-var がバーを隠すときは取り上げられる (切られる)
fn Lease::alive(self : Lease) -> Bool {
  c_stream_alive(self.fd)
}

///|
/// 返す。task-var がすぐ再生情報パネルを描き直す
fn Lease::give_back(self : Lease) -> Unit {
  c_stream_close(self.fd)
}
