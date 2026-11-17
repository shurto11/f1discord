// f1discord の C スタブ。MoonBit から直接は呼べない OS と FreeType の機能だけを置く。
//   時刻 / ファイル / シグナル / 子プロセス、フレームバッファ (ioctl と mmap)、
//   FreeType (字の幅と描画)、HTTP の GET (別スレッド)
// 文字列は、パスや URL は NUL で終わる UTF-8 の Bytes、描く字はコードポイントの配列 (FixedArray[Int]) で受け取る。

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <netdb.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>
#include <wctype.h>
#include <linux/fb.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>

#include <ft2build.h>
#include FT_FREETYPE_H

#include "moonbit.h"

static moonbit_bytes_t make_bytes(const void *p, size_t n) {
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  if (n) memcpy(b, p, n);
  return b;
}

// ---------------- 時刻、ファイル、シグナル、子プロセス ----------------

static volatile sig_atomic_t interrupted = 0;

static void on_signal(int sig) {
  (void)sig;
  interrupted = 1;
}

// 最初に 1 回呼ぶ。SIGINT と SIGTERM は、パネルを消してから終われるように印だけ付ける
void f1_init(void) {
  setlocale(LC_CTYPE, "C.UTF-8");
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_signal;
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  signal(SIGPIPE, SIG_IGN);
}

int32_t f1_interrupted(void) { return interrupted; }

double f1_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

void f1_sleep(double sec) {
  if (sec <= 0) return;
  struct timespec ts = {(time_t)sec, (long)((sec - (time_t)sec) * 1e9)};
  nanosleep(&ts, NULL);   // シグナルが来たら途中で戻る
}

int32_t f1_getuid(void) { return (int32_t)getuid(); }

int32_t f1_exists(const char *path) { return access(path, F_OK) == 0; }

int32_t f1_towupper(int32_t c) { return (int32_t)towupper((wint_t)c); }

int32_t f1_towlower(int32_t c) { return (int32_t)towlower((wint_t)c); }

void f1_eprint(moonbit_bytes_t s) {
  fwrite(s, 1, Moonbit_array_length(s), stderr);
  fflush(stderr);
}

// 実行ファイルのあるディレクトリ
moonbit_bytes_t f1_exe_dir(void) {
  char buf[4096];
  ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
  if (n <= 0) return make_bytes(".", 1);
  buf[n] = 0;
  char *slash = strrchr(buf, '/');
  if (!slash) return make_bytes(".", 1);
  return make_bytes(buf, slash == buf ? 1 : (size_t)(slash - buf));
}

static moonbit_bytes_t read_all(FILE *f) {
  size_t cap = 4096, len = 0;
  char *buf = malloc(cap);
  for (;;) {
    size_t n = fread(buf + len, 1, cap - len, f);
    len += n;
    if (n == 0) break;
    if (len == cap) buf = realloc(buf, cap *= 2);
  }
  moonbit_bytes_t b = make_bytes(buf, len);
  free(buf);
  return b;
}

// ファイルの中身。無ければ空を返す (無いことは f1_exists で先に確かめる)
moonbit_bytes_t f1_read_file(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) return make_bytes("", 0);
  moonbit_bytes_t b = read_all(f);
  fclose(f);
  return b;
}

// シェルのコマンドを実行して、標準出力を返す
moonbit_bytes_t f1_capture(const char *cmd) {
  FILE *p = popen(cmd, "r");
  if (!p) return make_bytes("", 0);
  moonbit_bytes_t b = read_all(p);
  pclose(p);
  return b;
}

// ---------------- フレームバッファ ----------------

static uint8_t *fb_map = NULL;
static int32_t fb_info[7];   // 幅, 高さ, bpp, 1 行のバイト数, R / G / B のビット位置

// 開いて mmap する。0: 成功、-1: 開けない、-2: ioctl の失敗、-3: 32bpp でない、-4: mmap の失敗
int32_t f1_fb_open(const char *path) {
  int fd = open(path, O_RDWR);
  if (fd < 0) return -1;
  struct fb_var_screeninfo var;
  struct fb_fix_screeninfo fix;
  if (ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0 || ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0) {
    close(fd);
    return -2;
  }
  // 見えている大きさ (xres, yres) は fbterm の使う 1280x720 だが、液晶には仮想の大きさ (1366x768) の全体が
  // 映っているので、そちらを画面の大きさにする
  fb_info[0] = (int32_t)var.xres_virtual;
  fb_info[1] = (int32_t)var.yres_virtual;
  fb_info[2] = (int32_t)var.bits_per_pixel;
  fb_info[3] = (int32_t)fix.line_length;
  fb_info[4] = (int32_t)var.red.offset;
  fb_info[5] = (int32_t)var.green.offset;
  fb_info[6] = (int32_t)var.blue.offset;
  if (var.bits_per_pixel != 32) {
    close(fd);
    return -3;
  }
  void *m = mmap(NULL, (size_t)fix.line_length * var.yres_virtual, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (m == MAP_FAILED) {
    close(fd);
    return -4;
  }
  fb_map = m;
  return 0;
}

int32_t f1_fb_info(int32_t i) { return fb_info[i]; }

// (x, y) から w x h の範囲と buf (1 ピクセル 4 バイト、w * h 個) の間でコピーする。画面の外にはみ出たぶんは飛ばす
static void fb_copy(int32_t x, int32_t y, int32_t w, int32_t h, uint8_t *buf, int to_screen) {
  if (!fb_map) return;
  int32_t x0 = x < 0 ? 0 : x, x1 = x + w > fb_info[0] ? fb_info[0] : x + w;
  if (x1 <= x0) return;
  for (int32_t row = 0; row < h; row++) {
    int32_t sy = y + row;
    if (sy < 0 || sy >= fb_info[1]) continue;
    uint8_t *screen = fb_map + (size_t)sy * fb_info[3] + (size_t)x0 * 4;
    uint8_t *mem = buf + ((size_t)row * w + (x0 - x)) * 4;
    if (to_screen)
      memcpy(screen, mem, (size_t)(x1 - x0) * 4);
    else
      memcpy(mem, screen, (size_t)(x1 - x0) * 4);
  }
}

void f1_fb_read(int32_t x, int32_t y, int32_t w, int32_t h, uint8_t *buf) { fb_copy(x, y, w, h, buf, 0); }

void f1_fb_write(int32_t x, int32_t y, int32_t w, int32_t h, uint8_t *buf) { fb_copy(x, y, w, h, buf, 1); }

// ---------------- FreeType ----------------

static FT_Library ft_lib;
static FT_Face ft_face;
static int32_t ft_size = 0;

// フォントを開く (.ttc の index 番目)。0: 成功
int32_t f1_font_open(const char *path, int32_t index) {
  if (FT_Init_FreeType(&ft_lib)) return -1;
  if (FT_New_Face(ft_lib, path, index, &ft_face)) return -2;
  return 0;
}

static void set_size(int32_t size) {
  if (size != ft_size) {
    FT_Set_Pixel_Sizes(ft_face, 0, (FT_UInt)size);
    ft_size = size;
  }
}

// 字の送り幅を足した、文字列の幅 (ピクセル)
double f1_text_width(int32_t size, int32_t *text, int32_t n) {
  set_size(size);
  FT_Pos pen = 0;
  FT_UInt prev = 0;
  for (int32_t i = 0; i < n; i++) {
    FT_UInt g = FT_Get_Char_Index(ft_face, (FT_ULong)text[i]);
    if (FT_HAS_KERNING(ft_face) && prev && g) {
      FT_Vector k;
      FT_Get_Kerning(ft_face, prev, g, FT_KERNING_DEFAULT, &k);
      pen += k.x;
    }
    if (!FT_Load_Glyph(ft_face, g, FT_LOAD_DEFAULT)) pen += ft_face->glyph->advance.x;
    prev = g;
  }
  return pen / 64.0;
}

// 字の上下の真ん中から基線までの距離 (ピクセル)。真ん中は、上端 (ascender) と下端 (descender) の中間
int32_t f1_font_middle(int32_t size) {
  set_size(size);
  FT_Size_Metrics *m = &ft_face->size->metrics;
  return (int32_t)(((m->ascender + m->descender) / 2 + 32) >> 6);
}

// img (RGB、w x h) の、基線の左端 (x, baseline) から文字列を rgb の色で描く
void f1_draw_text(uint8_t *img, int32_t w, int32_t h, int32_t size, int32_t *text, int32_t n, int32_t x,
                  int32_t baseline, int32_t rgb) {
  set_size(size);
  int32_t color[3] = {(rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255};
  FT_Pos pen = (FT_Pos)x * 64;
  FT_UInt prev = 0;
  for (int32_t i = 0; i < n; i++) {
    FT_UInt g = FT_Get_Char_Index(ft_face, (FT_ULong)text[i]);
    if (FT_HAS_KERNING(ft_face) && prev && g) {
      FT_Vector k;
      FT_Get_Kerning(ft_face, prev, g, FT_KERNING_DEFAULT, &k);
      pen += k.x;
    }
    prev = g;
    if (FT_Load_Glyph(ft_face, g, FT_LOAD_RENDER)) continue;
    FT_GlyphSlot slot = ft_face->glyph;
    FT_Bitmap *bm = &slot->bitmap;
    if (bm->pixel_mode == FT_PIXEL_MODE_GRAY) {
      int32_t gx = (int32_t)(pen >> 6) + slot->bitmap_left, gy = baseline - slot->bitmap_top;
      for (int32_t r = 0; r < (int32_t)bm->rows; r++) {
        int32_t py = gy + r;
        if (py < 0 || py >= h) continue;
        const uint8_t *src = bm->buffer + (ptrdiff_t)r * bm->pitch;
        for (int32_t c = 0; c < (int32_t)bm->width; c++) {
          int32_t px = gx + c, a = src[c];
          if (px < 0 || px >= w || a == 0) continue;
          uint8_t *dst = img + ((size_t)py * w + px) * 3;
          for (int ch = 0; ch < 3; ch++) dst[ch] = (uint8_t)((dst[ch] * (255 - a) + color[ch] * a + 127) / 255);
        }
      }
    }
    pen += slot->advance.x;
  }
}

// ---------------- HTTP ----------------
// 長く待たされる GET (long polling) の間も画面を動かせるように、別スレッドで読む。同時に走らせるのは 1 つだけ。
// スレッドは MoonBit のヒープに触らず、結果は f1_http_take が MoonBit のスレッドで Bytes に写す。

static pthread_mutex_t http_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t http_cond = PTHREAD_COND_INITIALIZER;
static int http_state = 0;   // 0: 何もしていない、1: 読んでいる、2: 読めた、3: 失敗
static char *http_buf = NULL;   // 読めた本文か、失敗の理由
static size_t http_len = 0;

static void http_finish(int state, char *buf, size_t len) {
  pthread_mutex_lock(&http_lock);
  http_state = state;
  http_buf = buf;
  http_len = len;
  pthread_cond_broadcast(&http_cond);
  pthread_mutex_unlock(&http_lock);
}

static void http_fail(const char *fmt, const char *arg) {
  char *msg = NULL;
  int n = asprintf(&msg, fmt, arg);
  http_finish(3, msg, n < 0 ? 0 : (size_t)n);
}

// chunked の本文をその場でほどいて、長さを返す
static size_t dechunk(char *body, size_t len) {
  size_t in = 0, out = 0;
  while (in < len) {
    char *end;
    unsigned long n = strtoul(body + in, &end, 16);
    char *nl = memchr(end, '\n', len - (size_t)(end - body));
    if (!nl || n == 0) break;
    in = (size_t)(nl - body) + 1;
    if (in + n > len) n = len - in;
    memmove(body + out, body + in, n);
    out += n;
    in += n + 2;
  }
  return out;
}

static void *http_thread(void *arg) {
  char *url = arg;   // http://host[:port][/path]
  char host[256], port[16] = "80";
  const char *p = url, *path;
  if (strncmp(p, "http://", 7) != 0) {
    http_fail("http:// でない URL: %s", url);
    free(url);
    return NULL;
  }
  p += 7;
  size_t hostlen = strcspn(p, ":/");
  if (hostlen == 0 || hostlen >= sizeof host) {
    http_fail("URL が読めない: %s", url);
    free(url);
    return NULL;
  }
  memcpy(host, p, hostlen);
  host[hostlen] = 0;
  p += hostlen;
  if (*p == ':') {
    size_t n = strcspn(++p, "/");
    if (n > 0 && n < sizeof port) {
      memcpy(port, p, n);
      port[n] = 0;
    }
    p += n;
  }
  path = *p ? p : "/";

  struct addrinfo hints, *res = NULL;
  memset(&hints, 0, sizeof hints);
  hints.ai_socktype = SOCK_STREAM;
  int gai = getaddrinfo(host, port, &hints, &res);
  if (gai != 0) {
    http_fail("getaddrinfo: %s", gai_strerror(gai));
    free(url);
    return NULL;
  }
  int fd = -1;
  struct timeval tv = {60, 0};   // 読み書き 1 回ごとの時間切れ
  for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
    fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) continue;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  if (fd < 0) {
    http_fail("connect: %s", strerror(errno));
    free(url);
    return NULL;
  }

  char *req = NULL;
  int reqlen = asprintf(&req, "GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: f1discord\r\nAccept: */*\r\n"
                              "Connection: close\r\n\r\n", path, host);
  free(url);
  for (int sent = 0; sent < reqlen;) {
    ssize_t n = send(fd, req + sent, (size_t)(reqlen - sent), 0);
    if (n <= 0) {
      http_fail("send: %s", strerror(errno));
      free(req);
      close(fd);
      return NULL;
    }
    sent += (int)n;
  }
  free(req);

  size_t cap = 8192, len = 0;
  char *buf = malloc(cap);
  for (;;) {
    if (len + 1 >= cap) buf = realloc(buf, cap *= 2);
    ssize_t n = recv(fd, buf + len, cap - len - 1, 0);
    if (n < 0) {
      http_fail("recv: %s", errno == EAGAIN || errno == EWOULDBLOCK ? "timed out" : strerror(errno));
      free(buf);
      close(fd);
      return NULL;
    }
    if (n == 0) break;
    len += (size_t)n;
  }
  close(fd);
  buf[len] = 0;

  char *sep = strstr(buf, "\r\n\r\n");
  int status = 0;
  if (!sep || sscanf(buf, "HTTP/%*s %d", &status) != 1) {
    http_fail("HTTP の応答でない%s", "");
    free(buf);
    return NULL;
  }
  if (status != 200) {
    char line[64];
    snprintf(line, sizeof line, "%d", status);
    http_fail("HTTP %s", line);
    free(buf);
    return NULL;
  }
  *sep = 0;
  int chunked = strcasestr(buf, "transfer-encoding: chunked") != NULL;
  char *body = sep + 4;
  size_t bodylen = len - (size_t)(body - buf);
  if (chunked) bodylen = dechunk(body, bodylen);
  memmove(buf, body, bodylen);
  http_finish(2, buf, bodylen);
  return NULL;
}

// GET を始める。前の結果は f1_http_take で受け取っておくこと
void f1_http_start(const char *url) {
  pthread_mutex_lock(&http_lock);
  http_state = 1;
  pthread_mutex_unlock(&http_lock);
  pthread_t th;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  if (pthread_create(&th, &attr, http_thread, strdup(url)) != 0) http_fail("pthread_create: %s", strerror(errno));
  pthread_attr_destroy(&attr);
}

// 終わるのを ms ミリ秒まで待って、状態を返す (1: まだ読んでいる、2: 読めた、3: 失敗)
int32_t f1_http_wait(int32_t ms) {
  struct timespec until;
  clock_gettime(CLOCK_REALTIME, &until);
  until.tv_sec += ms / 1000;
  until.tv_nsec += (long)(ms % 1000) * 1000000L;
  if (until.tv_nsec >= 1000000000L) {
    until.tv_sec++;
    until.tv_nsec -= 1000000000L;
  }
  pthread_mutex_lock(&http_lock);
  while (http_state == 1 && ms > 0 && !interrupted) {
    if (pthread_cond_timedwait(&http_cond, &http_lock, &until) != 0) break;
  }
  int32_t state = http_state;
  pthread_mutex_unlock(&http_lock);
  return state;
}

// 読めた本文 (失敗なら理由) を受け取って、何もしていない状態に戻す
moonbit_bytes_t f1_http_take(void) {
  pthread_mutex_lock(&http_lock);
  char *buf = http_buf;
  size_t len = http_len;
  http_buf = NULL;
  http_len = 0;
  http_state = 0;
  pthread_mutex_unlock(&http_lock);
  moonbit_bytes_t b = make_bytes(buf ? buf : "", buf ? len : 0);
  free(buf);
  return b;
}

// ---------------- この PC の中からの発言 ----------------
// 常駐しているほうが UNIX ドメインのデータグラムのソケットで待ち、f1discord --claude などが 1 通 1 発言で送る

#include <sys/un.h>

static int local_fd = -1;

static socklen_t local_addr(struct sockaddr_un *addr, const char *path) {
  memset(addr, 0, sizeof *addr);
  addr->sun_family = AF_UNIX;
  strncpy(addr->sun_path, path, sizeof addr->sun_path - 1);
  return (socklen_t)sizeof *addr;
}

// path で待ち始める。0: 成功
int32_t f1_local_bind(const char *path) {
  struct sockaddr_un addr;
  socklen_t len = local_addr(&addr, path);
  int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  unlink(path);   // 前に動いていたときの残り
  if (bind(fd, (struct sockaddr *)&addr, len) < 0) {
    close(fd);
    return -2;
  }
  chmod(path, 0600);
  local_fd = fd;
  return 0;
}

// 届いている 1 通。無ければ空
moonbit_bytes_t f1_local_recv(void) {
  static char buf[65536];
  ssize_t n = local_fd < 0 ? -1 : recv(local_fd, buf, sizeof buf, 0);
  return make_bytes(buf, n > 0 ? (size_t)n : 0);
}

// path で待っている相手に 1 通送る。0: 成功
int32_t f1_local_send(const char *path, moonbit_bytes_t data) {
  struct sockaddr_un addr;
  socklen_t len = local_addr(&addr, path);
  int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
  if (fd < 0) return -1;
  ssize_t n = sendto(fd, data, (size_t)Moonbit_array_length(data), 0, (struct sockaddr *)&addr, len);
  close(fd);
  return n < 0 ? -2 : 0;
}

moonbit_bytes_t f1_read_stdin(void) { return read_all(stdin); }

// ---------------- タッチ ----------------
// touch-server (タッチパネルを 1 人で読んで配るサーバー) に、パネルの範囲を申告してつなぐ。
// その範囲のタッチが JSON の行で届く

static int touch_fd = -1;

void f1_touch_close(void) {
  if (touch_fd >= 0) close(touch_fd);
  touch_fd = -1;
}

// path の touch-server につないで、申告の 1 行 hello を送る。0: 成功
int32_t f1_touch_open(const char *path, moonbit_bytes_t hello) {
  f1_touch_close();
  struct sockaddr_un addr;
  socklen_t len = local_addr(&addr, path);
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  if (connect(fd, (struct sockaddr *)&addr, len) < 0 ||
      send(fd, hello, (size_t)Moonbit_array_length(hello), 0) < 0) {
    close(fd);
    return -2;
  }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  touch_fd = fd;
  return 0;
}

// 届いているぶん。無ければ空 (切れていたら閉じる)
moonbit_bytes_t f1_touch_read(void) {
  char buf[4096];
  ssize_t n = touch_fd < 0 ? -1 : recv(touch_fd, buf, sizeof buf, 0);
  if (n == 0) f1_touch_close();
  return make_bytes(buf, n > 0 ? (size_t)n : 0);
}
