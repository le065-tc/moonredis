///|
/// In-memory data store with the five Redis data structures and per-key
/// expiry. The clock is injectable so expiry logic can be tested without
/// wall-clock time.
pub(all) enum Data {
  Str(Bytes)
  List(Array[Bytes])
  Hash(@hashmap.HashMap[String, Bytes])
  Set(@hashset.HashSet[String])
  ZSet(ZSetData)
}

///|
pub(all) struct ZSetData {
  scores : @hashmap.HashMap[String, Double]
  members : @sorted_map.SortedMap[Double, @hashset.HashSet[String]]
}

///|
pub fn ZSetData::new() -> ZSetData {
  { scores: @hashmap.HashMap::new(), members: @sorted_map.SortedMap::new() }
}

///|
pub(all) struct Store {
  data : @hashmap.HashMap[String, Data]
  expires : @hashmap.HashMap[String, Int64]
  now : () -> Int64
}

///|
pub fn Store::new(now? : () -> Int64 = fn() { 0L }) -> Store {
  { data: @hashmap.HashMap::new(), expires: @hashmap.HashMap::new(), now }
}

///|
/// Removes the key when it has expired. Returns true when the key was
/// removed because of expiry.
pub fn Store::expire_if_needed(self : Store, key : String) -> Bool {
  match self.expires.get(key) {
    None => false
    Some(at) =>
      if (self.now)() >= at {
        self.data.remove(key)
        self.expires.remove(key)
        true
      } else {
        false
      }
  }
}

///|
pub fn Store::set(self : Store, key : String, value : Data) -> Unit {
  self.data.set(key, value)
}

///|
pub fn Store::get(self : Store, key : String) -> Data? {
  if self.expire_if_needed(key) {
    return None
  }
  self.data.get(key)
}

///|
pub fn Store::del(self : Store, key : String) -> Bool {
  self.expires.remove(key)
  self.data.remove(key)
  true
}

///|
pub fn Store::exists(self : Store, key : String) -> Bool {
  self.get(key) is Some(_)
}

///|
pub fn Store::expire(self : Store, key : String, ttl_ms : Int64) -> Bool {
  if !self.exists(key) {
    return false
  }
  self.expires.set(key, (self.now)() + ttl_ms)
  true
}

///|
pub fn Store::persist(self : Store, key : String) -> Bool {
  if !self.exists(key) {
    return false
  }
  self.expires.remove(key)
  true
}

///|
/// Returns `None` when the key does not exist, otherwise the remaining TTL
/// in milliseconds (a negative value means no expiry).
pub fn Store::ttl_ms(self : Store, key : String) -> Int64? {
  if !self.exists(key) {
    return None
  }
  match self.expires.get(key) {
    None => Some(-1L)
    Some(at) => Some(at - (self.now)())
  }
}

///|
pub fn Store::keys(self : Store) -> Array[String] {
  let out : Array[String] = []
  for key in self.data.keys() {
    if !self.expire_if_needed(key) {
      out.push(key)
    }
  }
  out
}

///|
pub fn Store::flush(self : Store) -> Unit {
  self.data.clear()
  self.expires.clear()
}

///|
pub fn Store::size(self : Store) -> Int {
  self.keys().length()
}

///|
pub fn Store::type_of(self : Store, key : String) -> String? {
  match self.get(key) {
    None => None
    Some(Str(_)) => Some("string")
    Some(List(_)) => Some("list")
    Some(Hash(_)) => Some("hash")
    Some(Set(_)) => Some("set")
    Some(ZSet(_)) => Some("zset")
  }
}

///|
/// String operations
pub fn Store::set_string(self : Store, key : String, value : Bytes) -> Unit {
  self.set(key, Str(value))
}

///|
pub fn Store::get_string(self : Store, key : String) -> Bytes? {
  match self.get(key) {
    Some(Str(b)) => Some(b)
    _ => None
  }
}

///|
pub fn Store::append_string(self : Store, key : String, value : Bytes) -> Int? {
  match self.get(key) {
    None => {
      self.set_string(key, value)
      Some(value.length())
    }
    Some(Str(old)) => {
      let merged = Buffer()
      merged.write_bytes(old)
      merged.write_bytes(value)
      let b = merged.to_bytes()
      self.set_string(key, b)
      Some(b.length())
    }
    Some(_) => None
  }
}

///|
/// List operations
fn Store::list_or_new(self : Store, key : String) -> Array[Bytes] {
  match self.get(key) {
    Some(List(a)) => a
    _ => {
      let a : Array[Bytes] = []
      self.set(key, List(a))
      a
    }
  }
}

///|
pub fn Store::lpush(self : Store, key : String, values : Array[Bytes]) -> Int? {
  match self.get(key) {
    None => {
      let list : Array[Bytes] = []
      for v in values {
        list.push(v)
      }
      self.set(key, List(list))
      Some(list.length())
    }
    Some(List(a)) => {
      for v in values {
        a.insert(0, v)
      }
      self.set(key, List(a))
      Some(a.length())
    }
    Some(_) => None
  }
}

///|
pub fn Store::rpush(self : Store, key : String, values : Array[Bytes]) -> Int? {
  match self.get(key) {
    None => {
      let list : Array[Bytes] = []
      for v in values {
        list.push(v)
      }
      self.set(key, List(list))
      Some(list.length())
    }
    Some(List(a)) => {
      for v in values {
        a.push(v)
      }
      self.set(key, List(a))
      Some(a.length())
    }
    Some(_) => None
  }
}

///|
pub fn Store::lpop(self : Store, key : String) -> Bytes? {
  match self.get(key) {
    Some(List(a)) => {
      if a.is_empty() {
        return None
      }
      let v = a.remove(0)
      if a.is_empty() {
        let _ = self.del(key)
      } else {
        self.set(key, List(a))
      }
      Some(v)
    }
    _ => None
  }
}

///|
pub fn Store::rpop(self : Store, key : String) -> Bytes? {
  match self.get(key) {
    Some(List(a)) => {
      if a.is_empty() {
        return None
      }
      let v = a.pop()
      if a.is_empty() {
        let _ = self.del(key)
      } else {
        self.set(key, List(a))
      }
      v
    }
    _ => None
  }
}

///|
pub fn Store::llen(self : Store, key : String) -> Int? {
  match self.get(key) {
    Some(List(a)) => Some(a.length())
    _ => None
  }
}

///|
/// Hash operations
fn Store::hash_or_new(
  self : Store,
  key : String,
) -> @hashmap.HashMap[String, Bytes]? {
  match self.get(key) {
    Some(Hash(h)) => Some(h)
    None => {
      let h : @hashmap.HashMap[String, Bytes] = @hashmap.HashMap::new()
      self.set(key, Hash(h))
      Some(h)
    }
    Some(_) => None
  }
}

///|
pub fn Store::hset(
  self : Store,
  key : String,
  field : String,
  value : Bytes,
) -> Int? {
  match self.hash_or_new(key) {
    None => None
    Some(h) => {
      let existed = h.contains(field)
      h.set(field, value)
      Some(if existed { 0 } else { 1 })
    }
  }
}

///|
pub fn Store::hsetnx(
  self : Store,
  key : String,
  field : String,
  value : Bytes,
) -> Int? {
  match self.hash_or_new(key) {
    None => None
    Some(h) =>
      if h.contains(field) {
        Some(0)
      } else {
        h.set(field, value)
        Some(1)
      }
  }
}

///|
pub fn Store::hget(self : Store, key : String, field : String) -> Bytes? {
  match self.get(key) {
    Some(Hash(h)) => h.get(field)
    _ => None
  }
}

///|
pub fn Store::hdel(self : Store, key : String, fields : Array[String]) -> Int {
  match self.get(key) {
    Some(Hash(h)) => {
      let mut n = 0
      for f in fields {
        if h.contains(f) {
          h.remove(f)
          n = n + 1
        }
      }
      if h.is_empty() {
        let _ = self.del(key)
      }
      n
    }
    _ => 0
  }
}

///|
pub fn Store::hexists(self : Store, key : String, field : String) -> Bool {
  match self.get(key) {
    Some(Hash(h)) => h.contains(field)
    _ => false
  }
}

///|
pub fn Store::hlen(self : Store, key : String) -> Int? {
  match self.get(key) {
    Some(Hash(h)) => Some(h.length())
    _ => None
  }
}

///|
pub fn Store::hgetall(self : Store, key : String) -> Array[(String, Bytes)]? {
  match self.get(key) {
    Some(Hash(h)) => Some(h.to_array())
    _ => None
  }
}

///|
/// Set operations
fn Store::set_or_new(self : Store, key : String) -> @hashset.HashSet[String]? {
  match self.get(key) {
    Some(Set(s)) => Some(s)
    None => {
      let s : @hashset.HashSet[String] = @hashset.HashSet::new()
      self.set(key, Set(s))
      Some(s)
    }
    Some(_) => None
  }
}

///|
pub fn Store::sadd(self : Store, key : String, members : Array[String]) -> Int? {
  match self.set_or_new(key) {
    None => None
    Some(s) => {
      let mut added = 0
      for m in members {
        if s.add_and_check(m) {
          added = added + 1
        }
      }
      Some(added)
    }
  }
}

///|
pub fn Store::srem(self : Store, key : String, members : Array[String]) -> Int {
  match self.get(key) {
    Some(Set(s)) => {
      let mut removed = 0
      for m in members {
        if s.remove_and_check(m) {
          removed = removed + 1
        }
      }
      if s.is_empty() {
        let _ = self.del(key)
      }
      removed
    }
    _ => 0
  }
}

///|
pub fn Store::sismember(self : Store, key : String, m : String) -> Bool {
  match self.get(key) {
    Some(Set(s)) => s.contains(m)
    _ => false
  }
}

///|
pub fn Store::scard(self : Store, key : String) -> Int? {
  match self.get(key) {
    Some(Set(s)) => Some(s.length())
    _ => None
  }
}

///|
pub fn Store::smembers(self : Store, key : String) -> Array[String]? {
  match self.get(key) {
    Some(Set(s)) => Some(s.to_array())
    _ => None
  }
}

///|
/// Sorted set operations
pub fn Store::zadd(
  self : Store,
  key : String,
  pairs : Array[(String, Double)],
) -> Int? {
  match self.get(key) {
    None => {
      let z = ZSetData::new()
      let mut added = 0
      for pair in pairs {
        let (m, sc) = pair
        if !z.scores.contains(m) {
          added = added + 1
        }
        self.zset_put(z, m, sc)
      }
      self.set(key, ZSet(z))
      Some(added)
    }
    Some(ZSet(z)) => {
      let mut added = 0
      for pair in pairs {
        let (m, sc) = pair
        if !z.scores.contains(m) {
          added = added + 1
        }
        self.zset_put(z, m, sc)
      }
      Some(added)
    }
    Some(_) => None
  }
}

///|
fn Store::zset_put(
  self : Store,
  z : ZSetData,
  m : String,
  score : Double,
) -> Unit {
  match z.scores.get(m) {
    Some(old) =>
      match z.members.get(old) {
        Some(set) => {
          set.remove(m)
          if set.is_empty() {
            z.members.remove(old)
          }
        }
        None => ()
      }
    None => ()
  }
  z.scores.set(m, score)
  let set = z.members.get_or_init(score, fn() { @hashset.HashSet::new() })
  set.add(m)
}

///|
pub fn Store::zscore(self : Store, key : String, m : String) -> Double? {
  match self.get(key) {
    Some(ZSet(z)) => z.scores.get(m)
    _ => None
  }
}

///|
pub fn Store::zrem(self : Store, key : String, members : Array[String]) -> Int {
  match self.get(key) {
    Some(ZSet(z)) => {
      let mut removed = 0
      for m in members {
        match z.scores.get(m) {
          Some(score) => {
            z.scores.remove(m)
            match z.members.get(score) {
              Some(set) => {
                set.remove(m)
                if set.is_empty() {
                  z.members.remove(score)
                }
              }
              None => ()
            }
            removed = removed + 1
          }
          None => ()
        }
      }
      if z.scores.is_empty() {
        let _ = self.del(key)
      }
      removed
    }
    _ => 0
  }
}

///|
pub fn Store::zcard(self : Store, key : String) -> Int? {
  match self.get(key) {
    Some(ZSet(z)) => Some(z.scores.length())
    _ => None
  }
}

///|
pub fn Store::zrank(self : Store, key : String, m : String) -> Int? {
  match self.get(key) {
    Some(ZSet(z)) => {
      let mut rank = 0
      for kv in z.members.iter() {
        let (_, members) = kv
        for member in members.to_array() {
          if member == m {
            return Some(rank)
          }
          rank = rank + 1
        }
      }
      None
    }
    _ => None
  }
}

///|
pub fn Store::zrevrank(self : Store, key : String, m : String) -> Int? {
  match self.get(key) {
    Some(ZSet(z)) => {
      let total = z.scores.length()
      match self.zrank(key, m) {
        None => None
        Some(r) => Some(total - 1 - r)
      }
    }
    _ => None
  }
}

///|
/// MSETNX semantics: set all pairs only when none of the keys exist.
pub fn Store::msetnx(self : Store, pairs : Array[(String, Bytes)]) -> Bool {
  for pair in pairs {
    let (key, _) = pair
    if self.exists(key) {
      return false
    }
  }
  for pair in pairs {
    let (key, value) = pair
    self.set_string(key, value)
  }
  true
}

///|
/// Returns members ordered by score ascending. When `with_scores` is true
/// each entry is `(member, score)`.
pub fn Store::zrange(
  self : Store,
  key : String,
  start : Int,
  stop : Int,
  with_scores? : Bool = false,
) -> Array[(String, Double)]? {
  match self.get(key) {
    Some(ZSet(z)) => {
      let all : Array[(String, Double)] = []
      for kv in z.members.iter() {
        let (score, members) = kv
        for m in members.to_array() {
          all.push((m, score))
        }
      }
      let from = normalize_index(start, all.length())
      let to = normalize_index(stop, all.length())
      let out : Array[(String, Double)] = []
      if from <= to {
        let mut i = from
        while i <= to {
          out.push(all[i])
          i = i + 1
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
fn normalize_index(i : Int, len : Int) -> Int {
  if i < 0 {
    let v = len + i
    if v < 0 {
      0
    } else {
      v
    }
  } else if i >= len {
    len - 1
  } else {
    i
  }
}

///|
/// Parse an integer from raw bytes (Redis integer semantics).
pub fn parse_integer_bytes(b : Bytes) -> Int64? {
  let s = @utf8.decode_lossy(b).trim()
  if s.is_empty() {
    return None
  }
  let mut i = 0
  let mut neg = false
  if s[0] == '-' {
    neg = true
    i = 1
  } else if s[0] == '+' {
    i = 1
  }
  if i >= s.length() {
    return None
  }
  let mut v : Int64 = 0
  while i < s.length() {
    let c = s[i]
    if c < '0' || c > '9' {
      return None
    }
    v = v * 10L + (c.to_int().to_int64() - '0'.to_int().to_int64())
    i = i + 1
  }
  if neg {
    Some(-v)
  } else {
    Some(v)
  }
}
