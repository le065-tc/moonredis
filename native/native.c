#include <moonbit.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <wchar.h>
#endif

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
typedef SOCKET mr_sock_t;
#define MR_INVALID INVALID_SOCKET

typedef int(WSAAPI *mr_WSAStartup_fn)(WORD, LPWSADATA);
typedef SOCKET(WSAAPI *mr_socket_fn)(int, int, int);
typedef int(WSAAPI *mr_setsockopt_fn)(SOCKET, int, int, const char *, int);
typedef int(WSAAPI *mr_bind_fn)(SOCKET, const struct sockaddr *, int);
typedef int(WSAAPI *mr_listen_fn)(SOCKET, int);
typedef SOCKET(WSAAPI *mr_accept_fn)(SOCKET, struct sockaddr *, int *);
typedef int(WSAAPI *mr_closesocket_fn)(SOCKET);
typedef int(WSAAPI *mr_connect_fn)(SOCKET, const struct sockaddr *, int);
typedef int(WSAAPI *mr_ioctlsocket_fn)(SOCKET, long, u_long *);
typedef int(WSAAPI *mr_select_fn)(int, fd_set *, fd_set *, fd_set *,
                                  const struct timeval *);
typedef int(WSAAPI *mr_recv_fn)(SOCKET, char *, int, int);
typedef int(WSAAPI *mr_send_fn)(SOCKET, const char *, int, int);
typedef u_long(WSAAPI *mr_htonl_fn)(u_long);
typedef u_short(WSAAPI *mr_htons_fn)(u_short);

static struct {
  HMODULE handle;
  mr_WSAStartup_fn WSAStartup;
  mr_socket_fn socket;
  mr_setsockopt_fn setsockopt;
  mr_bind_fn bind;
  mr_listen_fn listen;
  mr_accept_fn accept;
  mr_closesocket_fn closesocket;
  mr_connect_fn connect;
  mr_ioctlsocket_fn ioctlsocket;
  mr_select_fn select;
  mr_recv_fn recv;
  mr_send_fn send;
  mr_htonl_fn htonl;
  mr_htons_fn htons;
} g_ws;

static int ws_load(void) {
  if (g_ws.handle != NULL) return 0;
  HMODULE h = LoadLibraryA("ws2_32.dll");
  if (h == NULL) return -1;
  g_ws.WSAStartup = (mr_WSAStartup_fn)GetProcAddress(h, "WSAStartup");
  g_ws.socket = (mr_socket_fn)GetProcAddress(h, "socket");
  g_ws.setsockopt = (mr_setsockopt_fn)GetProcAddress(h, "setsockopt");
  g_ws.bind = (mr_bind_fn)GetProcAddress(h, "bind");
  g_ws.listen = (mr_listen_fn)GetProcAddress(h, "listen");
  g_ws.accept = (mr_accept_fn)GetProcAddress(h, "accept");
  g_ws.closesocket = (mr_closesocket_fn)GetProcAddress(h, "closesocket");
  g_ws.connect = (mr_connect_fn)GetProcAddress(h, "connect");
  g_ws.ioctlsocket = (mr_ioctlsocket_fn)GetProcAddress(h, "ioctlsocket");
  g_ws.select = (mr_select_fn)GetProcAddress(h, "select");
  g_ws.recv = (mr_recv_fn)GetProcAddress(h, "recv");
  g_ws.send = (mr_send_fn)GetProcAddress(h, "send");
  g_ws.htonl = (mr_htonl_fn)GetProcAddress(h, "htonl");
  g_ws.htons = (mr_htons_fn)GetProcAddress(h, "htons");
  if (g_ws.WSAStartup == NULL || g_ws.socket == NULL ||
      g_ws.setsockopt == NULL || g_ws.bind == NULL ||
      g_ws.listen == NULL || g_ws.accept == NULL ||
      g_ws.closesocket == NULL || g_ws.ioctlsocket == NULL ||
      g_ws.connect == NULL ||
      g_ws.select == NULL || g_ws.recv == NULL || g_ws.send == NULL ||
      g_ws.htonl == NULL || g_ws.htons == NULL) {
    return -1;
  }
  g_ws.handle = h;
  return 0;
}

static int mr_net_init(void) {
  static int inited = 0;
  if (ws_load() != 0) return -1;
  if (!inited) {
    WSADATA wsa;
    if (g_ws.WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return -1;
    inited = 1;
  }
  return 0;
}

static int mr_fd_isset(mr_sock_t s, fd_set *set) {
  for (u_int i = 0; i < set->fd_count; i++) {
    if (set->fd_array[i] == s) return 1;
  }
  return 0;
}

#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
typedef int mr_sock_t;
#define MR_INVALID (-1)

static int mr_net_init(void) { return 0; }

static int mr_fd_isset(mr_sock_t s, fd_set *set) { return FD_ISSET(s, set); }
#endif

MOONBIT_FFI_EXPORT uint64_t mr_tcp_listen(int32_t port) {
  if (mr_net_init() != 0) return 0;
#ifdef _WIN32
  mr_sock_t fd = g_ws.socket(AF_INET, SOCK_STREAM, 0);
#else
  mr_sock_t fd = socket(AF_INET, SOCK_STREAM, 0);
#endif
  if (fd == MR_INVALID) return 0;
  int one = 1;
#ifdef _WIN32
  g_ws.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&one,
                  sizeof(one));
#else
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&one, sizeof(one));
#endif
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
#ifdef _WIN32
  addr.sin_addr.s_addr = g_ws.htonl(INADDR_LOOPBACK);
  addr.sin_port = g_ws.htons((uint16_t)port);
#else
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons((uint16_t)port);
#endif
#ifdef _WIN32
  if (g_ws.bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    g_ws.closesocket(fd);
    return 0;
  }
  if (g_ws.listen(fd, 128) != 0) {
    g_ws.closesocket(fd);
    return 0;
  }
#else
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close(fd);
    return 0;
  }
  if (listen(fd, 128) != 0) {
    close(fd);
    return 0;
  }
#endif
  return (uint64_t)fd;
}

MOONBIT_FFI_EXPORT uint64_t mr_tcp_accept(uint64_t fd) {
#ifdef _WIN32
  mr_sock_t c = g_ws.accept((mr_sock_t)fd, NULL, NULL);
#else
  mr_sock_t c = accept((mr_sock_t)fd, NULL, NULL);
#endif
  if (c == MR_INVALID) return 0;
  return (uint64_t)c;
}

MOONBIT_FFI_EXPORT uint64_t mr_tcp_connect(int32_t port) {
  if (mr_net_init() != 0) return 0;
#ifdef _WIN32
  mr_sock_t fd = g_ws.socket(AF_INET, SOCK_STREAM, 0);
#else
  mr_sock_t fd = socket(AF_INET, SOCK_STREAM, 0);
#endif
  if (fd == MR_INVALID) return 0;
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
#ifdef _WIN32
  addr.sin_addr.s_addr = g_ws.htonl(INADDR_LOOPBACK);
  addr.sin_port = g_ws.htons((uint16_t)port);
  if (g_ws.connect == NULL) return 0;
#else
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons((uint16_t)port);
#endif
#ifdef _WIN32
  if (g_ws.connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    g_ws.closesocket(fd);
    return 0;
  }
#else
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close(fd);
    return 0;
  }
#endif
  return (uint64_t)fd;
}

MOONBIT_FFI_EXPORT int32_t mr_tcp_set_nonblock(uint64_t fd) {
#ifdef _WIN32
  u_long mode = 1;
  return g_ws.ioctlsocket((SOCKET)fd, FIONBIO, &mode);
#else
  int flags = fcntl((int)fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl((int)fd, F_SETFL, flags | O_NONBLOCK);
#endif
}

MOONBIT_FFI_EXPORT int32_t mr_tcp_wait_read(uint64_t fd, int32_t timeout_ms) {
  fd_set rfds;
  FD_ZERO(&rfds);
  mr_sock_t s = (mr_sock_t)fd;
  FD_SET(s, &rfds);
  struct timeval tv;
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;
#ifdef _WIN32
  int r = g_ws.select((int)(s + 1), &rfds, NULL, NULL, &tv);
#else
  int r = select((int)(s + 1), &rfds, NULL, NULL, &tv);
#endif
  if (r <= 0) return r;
  return mr_fd_isset(s, &rfds) ? 1 : 0;
}

MOONBIT_FFI_EXPORT int32_t mr_tcp_read(uint64_t fd, uint8_t *buf,
                                       int32_t cap) {
#ifdef _WIN32
  int r = g_ws.recv((mr_sock_t)fd, (char *)buf, cap, 0);
#else
  int r = (int)recv((mr_sock_t)fd, (char *)buf, cap, 0);
#endif
  return r < 0 ? -1 : r;
}

MOONBIT_FFI_EXPORT int32_t mr_tcp_write(uint64_t fd, const uint8_t *buf,
                                        int32_t len) {
#ifdef _WIN32
  int w = g_ws.send((mr_sock_t)fd, (const char *)buf, len, 0);
#else
  int w = (int)send((mr_sock_t)fd, (const char *)buf, len, 0);
#endif
  return w < 0 ? -1 : w;
}

MOONBIT_FFI_EXPORT int32_t mr_tcp_close(uint64_t fd) {
#ifdef _WIN32
  return g_ws.closesocket((mr_sock_t)fd);
#else
  return close((mr_sock_t)fd);
#endif
}

MOONBIT_FFI_EXPORT int32_t mr_sleep_ms(int32_t ms) {
#ifdef _WIN32
  Sleep((DWORD)ms);
#else
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (long)(ms % 1000) * 1000000L;
  nanosleep(&ts, NULL);
#endif
  return 0;
}

MOONBIT_FFI_EXPORT int64_t mr_now_ms(void) {
#ifdef _WIN32
  return (int64_t)GetTickCount64();
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

static FILE *mr_fopen_utf8(const char *path, const char *mode) {
#ifdef _WIN32
  int wpath_len = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
  int wmode_len = MultiByteToWideChar(CP_UTF8, 0, mode, -1, NULL, 0);
  if (wpath_len <= 0 || wmode_len <= 0) return NULL;
  wchar_t *wpath = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)wpath_len);
  wchar_t wmode[8];
  if (wpath == NULL) return NULL;
  MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, wpath_len);
  MultiByteToWideChar(CP_UTF8, 0, mode, -1, wmode, wmode_len);
  FILE *f = _wfopen(wpath, wmode);
  free(wpath);
  return f;
#else
  return fopen(path, mode);
#endif
}

MOONBIT_FFI_EXPORT uint64_t mr_file_open(const uint8_t *path,
                                         int32_t path_len,
                                         int32_t append) {
  char path_buf[4096];
  if (path_len <= 0 || path_len >= (int32_t)sizeof(path_buf)) return 0;
  memcpy(path_buf, path, (size_t)path_len);
  path_buf[path_len] = '\0';
  const char *mode = append == 2 ? "wb" : (append == 1 ? "ab" : "rb");
  FILE *f = mr_fopen_utf8(path_buf, mode);
  if (f == NULL) return 0;
  return (uint64_t)(uintptr_t)f;
}

MOONBIT_FFI_EXPORT int32_t mr_file_write(uint64_t handle,
                                         const uint8_t *data,
                                         int32_t data_len) {
  FILE *f = (FILE *)(uintptr_t)handle;
  if (f == NULL) return -1;
  size_t w = fwrite(data, 1, (size_t)data_len, f);
  int ok = fflush(f);
  if (w != (size_t)data_len || ok != 0) return -1;
  return 0;
}

MOONBIT_FFI_EXPORT int32_t mr_file_close(uint64_t handle) {
  FILE *f = (FILE *)(uintptr_t)handle;
  if (f == NULL) return -1;
  return fclose(f);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mr_get_cli_args_utf8(void) {
#ifdef _WIN32
  typedef LPWSTR *(WINAPI *mr_CommandLineToArgvW_fn)(LPCWSTR, int *);
  static mr_CommandLineToArgvW_fn parse = NULL;
  if (parse == NULL) {
    HMODULE shell = LoadLibraryA("shell32.dll");
    if (shell != NULL) {
      parse = (mr_CommandLineToArgvW_fn)GetProcAddress(
          shell, "CommandLineToArgvW");
    }
    if (parse == NULL) return moonbit_make_bytes(0, 0);
  }
  LPWSTR command_line = GetCommandLineW();
  int argc = 0;
  LPWSTR *argv = parse(command_line, &argc);
  if (argv == NULL) return moonbit_make_bytes(0, 0);
  int total = 0;
  for (int i = 0; i < argc; i++) {
    total += WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, NULL, 0, NULL, NULL);
  }
  moonbit_bytes_t out = moonbit_make_bytes(total, 0);
  int pos = 0;
  for (int i = 0; i < argc; i++) {
    int len = WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, NULL, 0, NULL,
                                  NULL);
    WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, (char *)(out + pos), len,
                        NULL, NULL);
    pos += len;
  }
  LocalFree(argv);
  return out;
#else
  return moonbit_make_bytes(0, 0);
#endif
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mr_file_read_all(const uint8_t *path,
                                                    int32_t path_len) {
  char path_buf[4096];
  if (path_len <= 0 || path_len >= (int32_t)sizeof(path_buf)) {
    return moonbit_make_bytes(0, 0);
  }
  memcpy(path_buf, path, (size_t)path_len);
  path_buf[path_len] = '\0';
  FILE *f = mr_fopen_utf8(path_buf, "rb");
  if (f == NULL) return moonbit_make_bytes(0, 0);
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (size < 0) {
    fclose(f);
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)size, 0);
  size_t r = fread(out, 1, (size_t)size, f);
  fclose(f);
  if (r != (size_t)size) return moonbit_make_bytes(0, 0);
  return out;
}
