///|
test "parse and encode ping" {
  let r = @resp.parse(b"*1\r\n$4\r\nPING\r\n")
  match r {
    Complete(v, consumed) => {
      assert_eq(consumed, 14)
      match v {
        Array(items) => assert_eq(items.length(), 1)
        _ => fail("expected array")
      }
    }
    _ => fail("expected complete")
  }
}

///|
test "parse set command with binary value" {
  let r = @resp.parse(b"*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n")
  match r {
    Complete(v, _) =>
      match v {
        Array(items) => {
          assert_eq(items.length(), 3)
          match items[0] {
            BulkString(b) => assert_eq(@utf8.decode_lossy(b), "SET")
            _ => fail("expected bulk")
          }
        }
        _ => fail("expected array")
      }
    _ => fail("expected complete")
  }
}

///|
test "inline command" {
  let r = @resp.parse(b"PING\r\n")
  match r {
    Complete(v, consumed) => {
      assert_eq(consumed, 6)
      match v {
        Array(items) => {
          assert_eq(items.length(), 1)
          match items[0] {
            BulkString(b) => assert_eq(@utf8.decode_lossy(b), "PING")
            _ => fail("expected bulk")
          }
        }
        _ => fail("expected array")
      }
    }
    _ => fail("expected complete")
  }
}

///|
test "encode simple string" {
  let b = @resp.encode(SimpleString("OK"))
  assert_eq(@utf8.decode_lossy(b), "+OK\r\n")
}

///|
test "encode bulk string" {
  let b = @resp.encode(BulkString(@utf8.encode("hello")))
  assert_eq(@utf8.decode_lossy(b), "$5\r\nhello\r\n")
}

///|
test "encode null bulk" {
  let b = @resp.encode(NullBulk)
  assert_eq(@utf8.decode_lossy(b), "$-1\r\n")
}

///|
test "parse simple string, integer, error and double" {
  match @resp.parse(b"+OK\r\n") {
    Complete(SimpleString(s), 5) => assert_eq(s, "OK")
    _ => fail("expected simple string")
  }
  match @resp.parse(b":42\r\n") {
    Complete(Integer(n), 5) => assert_eq(n, 42L)
    _ => fail("expected integer")
  }
  match @resp.parse(b"-ERR bad\r\n") {
    Complete(Error(s), 10) => assert_eq(s, "ERR bad")
    _ => fail("expected error")
  }
  match @resp.parse(b",1.5\r\n") {
    Complete(Double(d), 6) => assert_eq(d, 1.5)
    _ => fail("expected double")
  }
}
