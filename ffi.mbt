// stub.c の関数。パスや URL は cstr で NUL 終わりの UTF-8 にして渡す

///|
extern "C" fn c_init() -> Unit = "f1_init"

///|
extern "C" fn c_exit(code : Int) -> Unit = "exit"

///|
extern "C" fn c_interrupted() -> Bool = "f1_interrupted"

///|
extern "C" fn c_now() -> Double = "f1_now"

///|
extern "C" fn c_sleep(sec : Double) -> Unit = "f1_sleep"

///|
extern "C" fn c_getuid() -> Int = "f1_getuid"

///|
#borrow(path)
extern "C" fn c_exists(path : Bytes) -> Bool = "f1_exists"

///|
extern "C" fn c_towupper(c : Int) -> Int = "f1_towupper"

///|
extern "C" fn c_towlower(c : Int) -> Int = "f1_towlower"

///|
#borrow(s)
extern "C" fn c_eprint(s : Bytes) -> Unit = "f1_eprint"

///|
extern "C" fn c_exe_dir() -> Bytes = "f1_exe_dir"

///|
#borrow(path)
extern "C" fn c_read_file(path : Bytes) -> Bytes = "f1_read_file"

///|
#borrow(cmd)
extern "C" fn c_capture(cmd : Bytes) -> Bytes = "f1_capture"

///|
#borrow(path)
extern "C" fn c_fb_open(path : Bytes) -> Int = "f1_fb_open"

///|
extern "C" fn c_fb_info(i : Int) -> Int = "f1_fb_info"

///|
#borrow(buf)
extern "C" fn c_fb_read(
  x : Int,
  y : Int,
  w : Int,
  h : Int,
  buf : FixedArray[Byte],
) -> Unit = "f1_fb_read"

///|
#borrow(buf)
extern "C" fn c_fb_write(
  x : Int,
  y : Int,
  w : Int,
  h : Int,
  buf : FixedArray[Byte],
) -> Unit = "f1_fb_write"

///|
#borrow(path)
extern "C" fn c_font_open(path : Bytes, index : Int) -> Int = "f1_font_open"

///|
#borrow(text)
extern "C" fn c_text_width(
  size : Int,
  text : FixedArray[Int],
  n : Int,
) -> Double = "f1_text_width"

///|
extern "C" fn c_font_middle(size : Int) -> Int = "f1_font_middle"

///|
#borrow(img, text)
extern "C" fn c_draw_text(
  img : FixedArray[Byte],
  w : Int,
  h : Int,
  size : Int,
  text : FixedArray[Int],
  n : Int,
  x : Int,
  baseline : Int,
  rgb : Int,
) -> Unit = "f1_draw_text"

///|
#borrow(url)
extern "C" fn c_http_start(url : Bytes) -> Unit = "f1_http_start"

///|
extern "C" fn c_http_wait(ms : Int) -> Int = "f1_http_wait"

///|
extern "C" fn c_http_take() -> Bytes = "f1_http_take"

///|
/// NUL で終わる UTF-8
fn cstr(s : String) -> Bytes {
  let b = @utf8.encode(s)
  Bytes::makei(b.length() + 1, i => if i < b.length() { b[i] } else { b'\x00' })
}

///|
fn text_of(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
fn eprint(s : String) -> Unit {
  c_eprint(@utf8.encode(s))
}

///|
/// 理由を出して終わる
fn[T] die(msg : String) -> T {
  eprint("f1discord: \{msg}\n")
  c_exit(1)
  panic()
}

///|
#borrow(path)
extern "C" fn c_local_bind(path : Bytes) -> Int = "f1_local_bind"

///|
extern "C" fn c_local_recv() -> Bytes = "f1_local_recv"

///|
#borrow(path, data)
extern "C" fn c_local_send(path : Bytes, data : Bytes) -> Int = "f1_local_send"

///|
extern "C" fn c_read_stdin() -> Bytes = "f1_read_stdin"

///|
#borrow(path, hello)
extern "C" fn c_touch_open(path : Bytes, hello : Bytes) -> Int = "f1_touch_open"

///|
extern "C" fn c_touch_read() -> Bytes = "f1_touch_read"

///|
extern "C" fn c_touch_close() -> Unit = "f1_touch_close"
