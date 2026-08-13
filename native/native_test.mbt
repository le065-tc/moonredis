///|
test "file append and read roundtrip" {
  let path = "moonredis_ffi_test.aof"
  let _ = @native.file_write_all(path, Bytes::make(0, 0))
  let ok = @native.file_append(path, @utf8.encode("*1\r\n"))
  assert_eq(ok, true)
  let data = @native.file_read_all(path)
  assert_eq(@utf8.decode_lossy(data), "*1\r\n")
}

///|
test "file append absolute unicode path" {
  let path = "moonredis_\u6781\u5149_test.aof"
  let _ = @native.file_write_all(path, Bytes::make(0, 0))
  let ok = @native.file_append(path, @utf8.encode("abc\r\n"))
  assert_eq(ok, true)
  let data = @native.file_read_all(path)
  assert_eq(@utf8.decode_lossy(data), "abc\r\n")
}
