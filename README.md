# moonredis

一个用 [MoonBit](https://www.moonbitlang.com/) 实现的轻量级、Redis 协议兼容的内存数据库服务器。

[![mooncakes.io](https://img.shields.io/badge/mooncakes.io-le065--tc%2Fmoonredis-blue)](https://mooncakes.io/packages/le065-tc/moonredis)
[![CI](https://github.com/le065-tc/moonredis/actions/workflows/ci.yml/badge.svg)](https://github.com/le065-tc/moonredis/actions/workflows/ci.yml)

moonredis 从零实现了 RESP（REdis Serialization Protocol）编解码、五种核心数据结构、键过期、事务（MULTI/EXEC）、发布订阅和 AOF 追加持久化，并通过一个自研的跨平台 TCP 桥接层在 Windows / Linux / macOS 上以原生二进制运行。

## 特性

- **RESP2 / RESP3 子集**：`+`、`-`、`:`、`$`、`*`、`_`、`#`、`,`、`>` 均可解析和编码，兼容 `redis-cli` 与常见客户端
- **五种数据结构**：String、List、Hash、Set、Sorted Set（ZSet）
- **键过期**：`EXPIRE` / `PEXPIRE` / `TTL` / `PTTL` / `PERSIST`，时钟可注入，便于确定性测试
- **事务**：`MULTI` / `EXEC` / `DISCARD`，命令排队后原子执行
- **发布订阅**：`SUBSCRIBE` / `UNSUBSCRIBE` / `PUBLISH`，单线程事件循环内投递
- **AOF 持久化**：以 RESP 格式追加写入，启动时自动重放，支持中文/Unicode 路径（Windows 下使用宽字符 API）
- **自带 CLI**：`moonredis-cli` 可执行单条命令
- **兼容性文档**：[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) 列出协议/命令覆盖与设计取舍
- **跨平台**：核心逻辑为纯 MoonBit；网络层是仓库内自带的 C shim（Windows 用 Winsock 动态加载，POSIX 用系统 socket），不依赖第三方网络库
- **AI 友好**：命令实现与协议解析分离、文档完整、示例可直接运行，方便 AI 工具辅助扩展新命令

## 快速开始

### 1. 构建

要求：MoonBit 工具链（`moon`）与 C 编译器（Linux/macOS 自带 gcc/clang；Windows 推荐 [w64devkit](https://github.com/skeeto/w64devkit) 并把其 `bin` 加入 `PATH`）。

```bash
moon update
moon build --target native
```

### 2. 启动服务器

```bash
moon run cmd/server --target native -- --port 6399
```

启用 AOF 持久化：

```bash
moon run cmd/server --target native -- --port 6399 --aof ./moonredis.aof --appendonly yes
```

### 3. 使用 CLI

```bash
moon run cmd/cli --target native -- --port 6399 PING
moon run cmd/cli --target native -- --port 6399 SET name moonbit
moon run cmd/cli --target native -- --port 6399 GET name
moon run cmd/cli --target native -- --port 6399 RPUSH list a b c
moon run cmd/cli --target native -- --port 6399 LRANGE list 0 -1
```

### 4. Python 示例

```bash
python examples/quickstart.py
```

也可以用任意 Redis 客户端连接 `127.0.0.1:6399`，例如：

```bash
redis-cli -p 6399 SET hello world
redis-cli -p 6399 GET hello
```

## 已支持命令

**连接与服务器**：`PING` `ECHO` `HELLO` `COMMAND` `QUIT` `SELECT` `AUTH` `INFO` `CONFIG GET/SET` `CLIENT ID/SETNAME/GETNAME/LIST` `SAVE` `SHUTDOWN`

**键**：`DEL` `EXISTS` `KEYS` `TYPE` `EXPIRE` `PEXPIRE` `TTL` `PTTL` `PERSIST` `DBSIZE` `FLUSHDB` `FLUSHALL`

**String**：`SET` `SETNX` `SETRANGE` `GET` `GETRANGE` `GETDEL` `MGET` `MSET` `MSETNX` `APPEND` `STRLEN` `INCR` `DECR` `INCRBY` `DECRBY`

**List**：`LPUSH` `RPUSH` `LPOP` `RPOP` `LLEN` `LRANGE` `LINDEX` `LSET` `LTRIM`

**Hash**：`HSET` `HMSET` `HSETNX` `HGET` `HGETALL` `HDEL` `HEXISTS` `HLEN` `HSTRLEN` `HKEYS` `HVALS`

**Set**：`SADD` `SREM` `SMEMBERS` `SISMEMBER` `SCARD` `SPOP`

**Sorted Set**：`ZADD` `ZRANGE [WITHSCORES]` `ZSCORE` `ZRANK` `ZREVRANK` `ZREM` `ZCARD` `ZINCRBY`

**事务**：`MULTI` `EXEC` `DISCARD`

**发布订阅**：`SUBSCRIBE` `UNSUBSCRIBE` `PUBLISH`

## 架构

```
resp/        RESP 值类型、解析器、编码器（纯 MoonBit）
store/       内存数据存储：五种数据结构 + TTL（纯 MoonBit，时钟可注入）
commands/    命令分发与实现、Pub/Sub Hub、事务队列（纯 MoonBit）
native/      C 桥接：TCP、单调时钟、AOF 文件读写（Winsock/POSIX）
server/      单线程事件循环、连接管理、AOF 追加与重放
cmd/server/  服务器可执行程序
cmd/cli/     RESP 命令行客户端
```

核心协议与数据结构不依赖任何 FFI，可在 WASM 等目标上编译测试；只有 `native/` 和 `server/` 需要原生环境。

## 测试

```bash
moon test --target native
python scripts/smoke_test.py   # 端到端冒烟测试（自动启动服务器并断言）
```

覆盖 RESP 编解码、五种数据结构、过期、命令分发、事务、Pub/Sub、AOF 文件往返（含 Unicode 路径）。

键空间命令额外支持 `RENAME`、`RENAMENX` 和 `TOUCH`，重命名时保留 TTL。

## 设计说明与限制

- 单线程事件循环，当前面向本地开发、教学与嵌入式演示场景；多线程与完整 Redis 命令集不在本次范围内。
- 键名按 UTF-8 字符串处理（值保持二进制安全）。
- RESP3 的 Map/Set 以扁平数组形式返回（文档化简化）。
- 不包含持久化 RDB、集群、主从复制；AOF 为追加模式。

## License

[Apache-2.0](LICENSE)

## 来源与合规

项目为原创 MoonBit 实现，未复制 Redis 或第三方 Redis 兼容服务器源码。协议兼容性范围、设计取舍和原生 C shim 来源说明见 [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) 与 [docs/SOURCES.md](docs/SOURCES.md)。

## 参赛与维护

OSC 2026 申请人与仓库维护者关系见 [docs/PARTICIPATION.md](docs/PARTICIPATION.md)。
