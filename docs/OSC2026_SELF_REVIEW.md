# OSC 2026 项目自查报告

## 总体判断

`moonredis` 是一个有效的 MoonBit native 项目，定位为 Redis 协议兼容的轻量级内存数据库服务器。项目包含 RESP 编解码、五类核心数据结构、键过期、事务、发布订阅、AOF、server/cli、示例、兼容性文档、CI 和 Apache-2.0 许可证，具备较清晰的工程边界和演示价值。

当前主要验收风险是 native/FFI 环境依赖：项目需要 C 编译器才能本地运行 `moon test --target native` 和端到端 smoke test。本机未安装 `cl`/`cc`/`gcc`/`clang`，因此本地无法完成 native 测试闭环；应依赖 GitHub Actions 或在提交前安装 C 编译器复验。

## 提交前需要处理的问题

- 本地环境缺 C 编译器，`moon test` 报错：`no system C compiler found; tried cl, cc, gcc, clang`。Windows 建议安装 w64devkit、MSVC Build Tools 或 clang，并确保编译器在 `PATH` 中。
- Gitlink 仓库未在本地 remote 中体现。提交申报前需要导入并同步 Gitlink，确认默认分支能看到主要代码和提交历史。
- mooncakes 当前登录用户与包名不一致。本地 `moon publish --dry-run` 通过包校验，但服务端拒绝：`le065-tc` 与当前认证用户 `fan-ere` 不匹配。发布前需要切换到 `le065-tc` 的 mooncakes 登录态。
- 项目核心 MoonBit 源码约 3211 行，不含测试；含测试约 3655 行。略低于章程 4-10k 有效 MoonBit 行数参考范围，建议继续补充命令覆盖、兼容性测试或更完整的持久化/协议文档。

## 需要进一步确认的问题

- GitHub、Gitlink、mooncakes 的账号主体是否均为申报人或已在申报材料中解释协作关系。
- GitHub Actions 最新一次 CI 是否已通过，尤其是 native build/test 和 `scripts/smoke_test.py`。
- 是否已经发布到 mooncakes.io；若未发布，需要用 `le065-tc` 账号登录后发布。
- C shim 是否完全原创；如参考了网络或文件 I/O 示例代码，应在 README 或专门文档中说明来源和许可证。

## 建议改进

- README 中保留 C 编译器要求，并补充 Windows/macOS/Linux 三平台最短安装方式。
- CI 可增加 `moon check --deny-warn`，把本次清理后的无警告状态固定下来。
- 补充更多真实 Redis 客户端互操作测试，例如 `redis-cli`、Python redis 客户端、并发连接、AOF 重放。
- 在 `docs/COMPATIBILITY.md` 中标注每类命令的支持程度和已知差异，降低评审预期偏差。

## 已检查的证据

- `moon.mod`：包名为 `le065-tc/moonredis`，许可证为 `Apache-2.0`，仓库为 `https://github.com/le065-tc/moonredis`。
- `moon check`：通过。
- `moon check --deny-warn`：通过。本次已清理弃用 API、未使用变量和未来保留字警告。
- `moon fmt --check .`：通过。
- `moon info`：通过。
- `moon test`：本机因缺 C 编译器无法执行 native 测试。
- `moon publish --dry-run`：包校验和提取后检查通过，但认证用户与包命名空间不匹配。
- `git remote show origin`：远程默认分支为 `main`，本地 `main` 已跟踪 `origin/main`。
- `git rev-list --count HEAD`：原始历史为 16 个提交，提交数满足申报建议范围。

## 可选环境建议

- 当前 MoonBit 工具链版本满足要求：`moon 0.1.20260807`，`moonc v0.10.7`。
- 当前环境未发现 `moonbitlang/skills` 本地技能目录。后续开发 MoonBit 项目时，建议安装以获得更贴近 MoonBit 包结构、测试和工具链的辅助。
