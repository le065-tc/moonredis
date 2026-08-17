# Sources and Compliance Notes

`moonredis` is an original MoonBit implementation. It does not copy source code from Redis, Valkey, KeyDB, Dragonfly, or another Redis-compatible server.

The project uses public protocol behavior as implementation references:

- RESP2 / RESP3 wire formats and common Redis command behavior are implemented from public Redis documentation and observable client/server behavior.
- The command compatibility scope and intentional differences are documented in `docs/COMPATIBILITY.md`.
- `native/native.c` is a project-local C shim written for this repository. It provides TCP sockets, monotonic time, file append/read helpers, and Windows UTF-16 command line parsing. It does not embed third-party networking code.
- `examples/quickstart.py` and `scripts/smoke_test.py` are repository-local examples/tests and do not include private data.

Redis is a trademark and an external protocol ecosystem. This project is a lightweight compatibility project for local development, demos, and MoonBit ecosystem experimentation; it is not a full Redis replacement.
