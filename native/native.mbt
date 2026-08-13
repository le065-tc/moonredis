///|
/// Native bindings used by the server: TCP, monotonic clock, and AOF files.
pub extern "C" fn tcp_listen_ffi(port : Int) -> UInt64 = "mr_tcp_listen"

///|
pub extern "C" fn tcp_accept_ffi(fd : UInt64) -> UInt64 = "mr_tcp_accept"

///|
pub extern "C" fn tcp_connect_ffi(port : Int) -> UInt64 = "mr_tcp_connect"

///|
pub extern "C" fn tcp_set_nonblock_ffi(fd : UInt64) -> Int = "mr_tcp_set_nonblock"

///|
pub extern "C" fn tcp_wait_read_ffi(fd : UInt64, timeout_ms : Int) -> Int = "mr_tcp_wait_read"

///|
#borrow(buf)
pub extern "C" fn tcp_read_ffi(fd : UInt64, buf : Bytes, cap : Int) -> Int = "mr_tcp_read"

///|
#borrow(buf)
pub extern "C" fn tcp_write_ffi(fd : UInt64, buf : Bytes, len : Int) -> Int = "mr_tcp_write"

///|
pub extern "C" fn tcp_close_ffi(fd : UInt64) -> Int = "mr_tcp_close"

///|
pub extern "C" fn sleep_ms_ffi(ms : Int) -> Int = "mr_sleep_ms"

///|
pub extern "C" fn now_ms_ffi() -> Int64 = "mr_now_ms"

///|
#borrow(path)
pub extern "C" fn file_open_ffi(
  path : Bytes,
  path_len : Int,
  append : Int,
) -> UInt64 = "mr_file_open"

///|
#borrow(data)
pub extern "C" fn file_write_ffi(
  handle : UInt64,
  data : Bytes,
  data_len : Int,
) -> Int = "mr_file_write"

///|
pub extern "C" fn file_close_ffi(handle : UInt64) -> Int = "mr_file_close"

///|
pub extern "C" fn get_cli_args_utf8_ffi() -> Bytes = "mr_get_cli_args_utf8"

///|
#borrow(path)
pub extern "C" fn file_read_all_ffi(path : Bytes, path_len : Int) -> Bytes = "mr_file_read_all"

///|
pub fn sleep_ms(ms : Int) -> Unit {
  let _ = sleep_ms_ffi(ms)
}

///|
pub fn now_ms() -> Int64 {
  now_ms_ffi()
}

///|
/// Appends bytes to a file (used by the AOF).
pub fn file_append(path : String, data : Bytes) -> Bool {
  let path_bytes = @utf8.encode(path)
  let handle = file_open_ffi(path_bytes, path_bytes.length(), 1)
  if handle == 0 {
    return false
  }
  let w = file_write_ffi(handle, data, data.length())
  let c = file_close_ffi(handle)
  let ok = w == 0 && c == 0
  ok
}

///|
/// Overwrites a file with the given bytes (used by tests and by callers
/// that want a snapshot instead of an append-only log).
pub fn file_write_all(path : String, data : Bytes) -> Bool {
  let path_bytes = @utf8.encode(path)
  let handle = file_open_ffi(path_bytes, path_bytes.length(), 2)
  if handle == 0 {
    return false
  }
  let w = file_write_ffi(handle, data, data.length())
  let c = file_close_ffi(handle)
  w == 0 && c == 0
}

///|
/// Reads an entire file, or returns an empty Bytes when the file does not
/// exist or cannot be read.
pub fn file_read_all(path : String) -> Bytes {
  let path_bytes = @utf8.encode(path)
  file_read_all_ffi(path_bytes, path_bytes.length())
}

///|
/// Returns command line arguments as UTF-8 strings. On Windows this uses
/// `CommandLineToArgvW` directly to avoid the runtime's ANSI mis-decoding;
/// on other platforms it falls back to `moonbitlang/x/sys`.
pub fn get_cli_args() -> Array[String] {
  let blob = get_cli_args_utf8_ffi()
  if blob.length() == 0 {
    return @sys.get_cli_args()
  }
  let parts : Array[Bytes] = []
  let mut start = 0
  let mut i = 0
  while i < blob.length() {
    if blob[i] == b'\x00' {
      parts.push(bytes_slice(blob, start, i - start))
      start = i + 1
    }
    i = i + 1
  }
  let out : Array[String] = []
  for p in parts {
    out.push(@utf8.decode_lossy(p))
  }
  out
}

///|
fn bytes_slice(b : Bytes, start : Int, len : Int) -> Bytes {
  if len <= 0 {
    return Bytes::make(0, 0)
  }
  let out = Buffer()
  for i = 0; i < len; i = i + 1 {
    out.write_byte(b[start + i])
  }
  out.to_bytes()
}
