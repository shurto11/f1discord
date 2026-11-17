// 絵 (RGB) と、フレームバッファ

///|
/// 1 ピクセル 3 バイト (R, G, B) の絵。色は 0xRRGGBB で渡す
struct Image {
  w : Int
  h : Int
  data : FixedArray[Byte]
}

///|
fn Image::new(w : Int, h : Int, rgb : Int) -> Image {
  let img = { w, h, data: FixedArray::make(w * h * 3, b'\x00'), }
  img.rect(0, 0, w - 1, h - 1, rgb)
  img
}

///|
fn Image::copy(self : Image) -> Image {
  { w: self.w, h: self.h, data: self.data.copy(), }
}

///|
/// (x0, y0) から (x1, y1) まで (両端を含む) を塗る
fn Image::rect(
  self : Image,
  x0 : Int,
  y0 : Int,
  x1 : Int,
  y1 : Int,
  rgb : Int,
) -> Unit {
  let r = (rgb >> 16).to_byte()
  let g = (rgb >> 8).to_byte()
  let b = rgb.to_byte()
  for y in Int::max(y0, 0)..<Int::min(y1 + 1, self.h) {
    for x in Int::max(x0, 0)..<Int::min(x1 + 1, self.w) {
      let p = (y * self.w + x) * 3
      self.data[p] = r
      self.data[p + 1] = g
      self.data[p + 2] = b
    }
  }
}

///|
/// 字を描く。上下は cy が字の真ん中、左右は x が左端 (right なら右端) になるように置く
fn Image::text(
  self : Image,
  text : Array[Char],
  size : Int,
  x : Int,
  cy : Int,
  rgb : Int,
  right? : Bool = false,
) -> Unit {
  let left = if right {
    (x.to_double() - text_width(text, size)).round().to_int()
  } else {
    x
  }
  c_draw_text(
    self.data,
    self.w,
    self.h,
    size,
    codepoints(text),
    text.length(),
    left,
    cy + c_font_middle(size),
    rgb,
  )
}

///|
fn lanczos(x : Double) -> Double {
  if x == 0 {
    1
  } else if x.abs() >= 3 {
    0
  } else {
    let px = @math.PI * x
    3 * @math.sin(px) * @math.sin(px / 3) / (px * px)
  }
}

///|
/// 1 方向の縮小・拡大の重み。出力の i 番目は、入力の first[i] から count[i] 個に weights[i * taps ..] を掛けて足す
struct Kernel {
  taps : Int
  first : FixedArray[Int]
  count : FixedArray[Int]
  weights : FixedArray[Double]
}

///|
fn Kernel::new(src : Int, dst : Int) -> Kernel {
  let scale = src.to_double() / dst.to_double()
  let filterscale = Double::max(scale, 1)
  let support = 3.0 * filterscale // Lanczos の幅 (入力のピクセル数)
  let taps = support.ceil().to_int() * 2 + 1
  let first = FixedArray::make(dst, 0)
  let count = FixedArray::make(dst, 0)
  let weights = FixedArray::make(dst * taps, 0.0)
  for i in 0..<dst {
    let center = (i.to_double() + 0.5) * scale
    let lo = Int::max((center - support + 0.5).to_int(), 0)
    let hi = Int::min((center + support + 0.5).to_int(), src)
    let mut sum = 0.0
    for k in 0..<(hi - lo) {
      let w = lanczos(((lo + k).to_double() - center + 0.5) / filterscale)
      weights[i * taps + k] = w
      sum += w
    }
    if sum != 0 {
      for k in 0..<(hi - lo) {
        weights[i * taps + k] /= sum
      }
    }
    first[i] = lo
    count[i] = hi - lo
  }
  { taps, first, count, weights, }
}

///|
/// Lanczos で w x h の大きさにする (横、縦の順に掛ける)
fn Image::resize(self : Image, w : Int, h : Int) -> Image {
  let kx = Kernel::new(self.w, w)
  let ky = Kernel::new(self.h, h)
  let mid = FixedArray::make(w * self.h * 3, 0.0)
  for y in 0..<self.h {
    for x in 0..<w {
      let src = (y * self.w + kx.first[x]) * 3
      let dst = (y * w + x) * 3
      for k in 0..<kx.count[x] {
        let wt = kx.weights[x * kx.taps + k]
        mid[dst] += self.data[src + k * 3].to_double() * wt
        mid[dst + 1] += self.data[src + k * 3 + 1].to_double() * wt
        mid[dst + 2] += self.data[src + k * 3 + 2].to_double() * wt
      }
    }
  }
  let out = FixedArray::make(w * h * 3, b'\x00')
  for y in 0..<h {
    for x in 0..<w {
      let mut r = 0.0
      let mut g = 0.0
      let mut b = 0.0
      for k in 0..<ky.count[y] {
        let src = ((ky.first[y] + k) * w + x) * 3
        let wt = ky.weights[y * ky.taps + k]
        r += mid[src] * wt
        g += mid[src + 1] * wt
        b += mid[src + 2] * wt
      }
      let dst = (y * w + x) * 3
      out[dst] = clamp_byte(r)
      out[dst + 1] = clamp_byte(g)
      out[dst + 2] = clamp_byte(b)
    }
  }
  { w, h, data: out, }
}

///|
fn clamp_byte(v : Double) -> Byte {
  Int::min(Int::max((v + 0.5).to_int(), 0), 255).to_byte()
}

///|
/// 2 つの色の中間
fn mix(a : Int, b : Int) -> Int {
  let mut out = 0
  for shift in [16, 8, 0] {
    out = out | (((((a >> shift) & 255) + ((b >> shift) & 255)) / 2) << shift)
  }
  out
}

// ---------------- フレームバッファ ----------------

///|
/// 画面の上の範囲 (x, y, 幅, 高さ)
struct Rect {
  x : Int
  y : Int
  w : Int
  h : Int
} derive(Eq)

///|
struct Framebuffer {
  width : Int
  height : Int
  shifts : (Int, Int, Int) // R, G, B のビット位置
}

///|
fn Framebuffer::open(path : String) -> Framebuffer {
  match c_fb_open(cstr(path)) {
    0 => ()
    -1 => die("\{path} が開けない")
    -3 => die("\{path} が 32bpp でない (\{c_fb_info(2)})")
    e => die("\{path} が使えない (\{e})")
  }
  {
    width: c_fb_info(0),
    height: c_fb_info(1),
    shifts: (c_fb_info(4), c_fb_info(5), c_fb_info(6)),
  }
}

///|
/// 画面の rect の範囲の絵を取っておく
fn Framebuffer::grab(_self : Framebuffer, rect : Rect) -> FixedArray[Byte] {
  let saved = FixedArray::make(rect.w * rect.h * 4, b'\x00')
  c_fb_read(rect.x, rect.y, rect.w, rect.h, saved)
  saved
}

///|
/// grab で取っておいた絵を戻す
fn Framebuffer::put(
  _self : Framebuffer,
  rect : Rect,
  saved : FixedArray[Byte],
) -> Unit {
  c_fb_write(rect.x, rect.y, rect.w, rect.h, saved)
}

///|
/// img の上から rows 行を (x, y) に描く
fn Framebuffer::blit(
  self : Framebuffer,
  img : Image,
  x : Int,
  y : Int,
  rows : Int,
) -> Unit {
  let h = Int::min(Int::min(rows, img.h), self.height - y)
  if h <= 0 || img.w <= 0 {
    return
  }
  let (rs, gs, bs) = self.shifts
  let buf = FixedArray::make(img.w * h * 4, b'\x00')
  for i in 0..<(img.w * h) {
    let v = (img.data[i * 3].to_uint() << rs) |
      (img.data[i * 3 + 1].to_uint() << gs) |
      (img.data[i * 3 + 2].to_uint() << bs) |
      0xFF000000U
    buf[i * 4] = v.to_byte()
    buf[i * 4 + 1] = (v >> 8).to_byte()
    buf[i * 4 + 2] = (v >> 16).to_byte()
    buf[i * 4 + 3] = (v >> 24).to_byte()
  }
  c_fb_write(x, y, img.w, h, buf)
}
