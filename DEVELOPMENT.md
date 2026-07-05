# CXXForge 开发与架构文档

本文面向 CXXForge 的维护者，记录 `2.0.0-dev.8` 当前实现的结构、执行流程、文件职责、数据格式、测试策略、发布方法和已知技术债务。

本文描述现有的模块化 runtime 与单文件 installer 架构。用户使用说明见 [README.md](README.md)。

## 1. 设计目标

CXXForge 当前围绕以下目标设计：

1. 在 Windows PowerShell 5.1 上无需额外 PowerShell 模块即可运行。
2. 用户只需一个 `install.ps1` 即可离线安装。
3. 发布入口仍是单个 `install.ps1`；安装后的 runtime 允许由入口和模块目录组成。
4. 同时覆盖单文件练习和小型多文件项目。
5. 与 VS Code、Code Runner、GDB 组合时尽量不覆盖用户已有配置。
6. 对增量构建、安装升级和卸载执行保守的状态判断。
7. 失败时优先保留上一次可用产物和用户修改。

这几项目标会产生明显权衡：开发态由 `forge.ps1` 按顺序加载多个模块，`install.ps1` 则嵌入入口、模块和兼容文件的完整副本。运行时职责已经分离，但模块仍共享同一个脚本作用域，以保持 PowerShell 5.1 行为和旧构建逻辑。

## 2. 仓库结构

```text
cxxforge/
├─ VERSION
├─ README.md
├─ DEVELOPMENT.md
├─ .gitignore
├─ LICENSE
├─ install.ps1
├─ cxxforge.ps1
├─ test.cpp
├─ cxxforge/
│  ├─ forge.ps1
│  ├─ run_active.ps1
│  ├─ run_active.bat
│  ├─ compiler_config.default.json
│  ├─ compiler_config.json
│  ├─ cxxforge.json
│  └─ modules/
│     ├─ Core.ps1
│     ├─ Configuration.ps1
│     ├─ Build.ps1
│     └─ Watch.ps1
├─ tools/
│  └─ sync-installer-payload.ps1
└─ tests/
   ├─ integration.ps1
   ├─ comprehensive.ps1
   ├─ .artifacts/
   └─ fixtures/
      ├─ mixed-project/
      └─ sidecar/
```

### 2.1 根目录文件

| 文件 | 类型 | 职责 | 是否人工维护 |
|---|---|---|---|
| `VERSION` | 源文件 | 唯一人工版本来源。 | 是 |
| `README.md` | 文档 | 用户安装、配置和使用说明。 | 是 |
| `DEVELOPMENT.md` | 文档 | 架构、维护、测试与发布说明。 | 是 |
| .gitignore | 配置 | 忽略编译产物、缓存、备份、临时输入与本地 .vscode。 | 是 |
| LICENSE | 许可证 | Mozilla Public License 2.0 完整文本。 | 否；应与官方文本一致 |
| `install.ps1` | 生成型发布文件 | 离线安装器，包含安装逻辑、模块化 runtime 和默认配置。 | 安装逻辑人工维护；载荷由工具生成 |
| `cxxforge.ps1` | 稳定公开入口 | 将全部参数转发给实际 runtime 的 `cxxforge/forge.ps1`，并传播退出码。 | 是；同时嵌入安装器 |
| `test.cpp` | 示例/手工验证 | 本地交互和 Watch 冒烟测试。 | 可修改，不属于产品核心 |

### 2.2 `cxxforge/`

| 文件 | 职责 |
|---|---|
| `forge.ps1` | 内部 runtime 主入口；建立共享上下文、定义统一退出协议，并按固定顺序 dot-source 模块。 |
| `run_active.ps1` | 旧入口兼容转发器；将参数交给 `forge.ps1` 并传播退出码。 |
| `run_active.bat` | batch 入口；直接转发给 `forge.ps1` 并返回退出码。 |
| `modules/Core.ps1` | 默认状态、版本 banner、CLI、诊断公共状态和自动路径发现。 |
| `modules/Configuration.ps1` | 项目识别、配置合并、profile/backend、sidecar、魔法注释和工具链环境。 |
| `modules/Build.ps1` | 增量缓存、编译、链接、诊断重放和非 Watch 程序执行。 |
| `modules/Watch.ps1` | Watch 进程、输入后端、命令层、文件事件与自动重建。 |
| `compiler_config.default.json` | 安装器嵌入的默认机器配置模板。 |
| `compiler_config.json` | 当前工作区实际使用的机器配置；包含本机工具链路径。 |
| `cxxforge.json` | 示例项目描述文件，不是 runner 的全局配置。 |

`compiler_config.default.json` 应保持可移植，不应包含某位开发者机器的绝对路径。`compiler_config.json` 可以包含本机路径，但升级/修复会默认保留它。

### 2.3 `tools/`

`sync-installer-payload.ps1` 执行三个同步动作：

1. 读取并验证 `VERSION` 的 SemVer 格式。
2. 更新 `modules/Core.ps1` 的 `$SCRIPT_VERSION` 和 `install.ps1` 的 `$INSTALLER_VERSION`。
3. 将根目录公开入口、内部 `forge.ps1`、四个模块、兼容入口、batch 与默认配置写入 `install.ps1` 的 PowerShell 单引号 here-string 载荷块。

该工具必须保持字节幂等：输入未变化时，连续执行两次不得继续改变 `install.ps1`。

### 2.4 `tests/`

- `integration.ps1`：较快的真实编译集成测试，覆盖混合语言、同名对象、增量链接和 sidecar 路径。
- `comprehensive.ps1`：完整自包含回归测试，使用临时隔离工作区，覆盖参数、编译、Watch、缓存、安装器和 VS Code JSONC 生命周期。
- `fixtures/mixed-project`：C 与 C++ 混合项目，故意包含不同目录下的同名源文件。
- `fixtures/sidecar`：主源文件与同名 JSON 的相对路径测试。
- `.artifacts`：测试生成物，不是源文件。

### 2.5 本地 `.vscode/`

`.vscode/` 是安装器在各工作区动态生成和增量维护的本地配置，不纳入公开仓库。安装器会管理 Run、Compile、Debug、Watch 任务、Code Runner 映射、IntelliSense 与 GDB 配置，同时保留已有用户内容。

## 3. 总体数据流

```text
命令行 / VS Code / Code Runner
              │
              ▼
      cxxforge.ps1
              │
              ▼
      cxxforge/forge.ps1
              │
     ┌────────┼─────────┐
     │        │         │
     ▼        ▼         ▼
单文件模式  sidecar   cxxforge.json
     │        │         │
     └────────┼─────────┘
              ▼
      compiler_config.json
              │
              ▼
   工具链解析、profile、有效参数
              │
       ┌──────┴──────┐
       ▼             ▼
  完整编译链接    项目增量编译链接
       │             │
       └──────┬──────┘
              ▼
      诊断格式化与退出码
              │
       ┌──────┴──────┐
       ▼             ▼
    普通运行       Watch 循环
```

安装与发布是另一条数据流：

```text
VERSION ───────────────────────────────┐
cxxforge.ps1 ─────────────────────┐  │
cxxforge/forge.ps1 ───────────────┤  │
cxxforge/modules/*.ps1 ────────┐ │  │
cxxforge/run_active.* ──────┐ │ │  │
cxxforge/compiler_config.default.json ┐│ │ │  │
                             ▼▼ ▼ ▼  ▼
                    sync-installer-payload.ps1
                                 │
                                 ▼
                   单文件 portable install.ps1
                                 │
                    ┌────────────┴────────────┐
                    ▼                         ▼
        cxxforge.ps1 + cxxforge/       .vscode/ 管理块
                    │
                    ▼
             .cxxforge/manifest.json
```

## 4. Runtime 内部结构

根目录 `cxxforge.ps1` 是稳定公开入口；`cxxforge/forge.ps1` 是内部 runtime 主入口，并按以下固定顺序加载模块：

```text
Core.ps1
  ↓
Configuration.ps1
  ↓
Build.ps1
  ↓
Watch.ps1
```

顺序具有语义：Core 创建状态和函数；Configuration 消费 CLI 状态并准备工具链；Build 消费有效配置并产生目标；只有启用 Watch 且构建阶段未结束进程时，Watch 才继续执行。

`forge.ps1` 在加载模块前保存三个不能依赖 dot-source 自动推导的值：

| 变量 | 含义 |
|---|---|
| `$script:CXXFORGE_ROOT` | `cxxforge/` runtime 根目录，用于定位 `compiler_config.json`。 |
| `$script:CXXFORGE_ENTRY_PATH` | `forge.ps1` 的真实路径，供 Watch 子构建重新调用。 |
| `$script:CXXFORGE_CLI_ARGS` | 原始 CLI 参数，避免模块自己的 `$args` 覆盖入口参数。 |

模块中的正常提前结束统一调用 `Exit-CxxForge <code>`。该函数抛出携带 `CXXForgeExitCode` 的受控异常，由主入口捕获后转换成真实进程退出码。不能在模块中直接使用 `exit`：dot-source 文件中的 `exit` 可能只结束当前模块，随后主入口继续加载错误的阶段。

### 4.1 启动状态与诊断状态

文件开头定义脚本级状态：

- 运行控制：`DO_RUN`、`WATCH_MODE`、`WATCH_CLEAR`。
- 输出控制：`PRETTY`、`USE_COLOR`、`FORCE_ANSI`、`NORMALIZE_DIAGNOSTICS`。
- 构建控制：`PROFILE_NAME`、`BACKEND_OVERRIDE`、`FORCE_REBUILD`、`CLEAN_BUILD`、`EXPLAIN_BUILD`。
- 输入输出：`SRC`、`OUT_DIR`、`OUT_NAME`、`RUN_ARGS`。
- 项目状态：`IS_PROJECT_MODE`、`PROJECT_INCLUDES`、`PROJECT_LINKS`。
- 诊断 parser 状态：当前文件、待处理源码行、错误和警告计数。

这些变量主要使用 script scope，四个模块因此表现为一个按阶段拆分的程序，而不是相互隔离的 PowerShell module。修改时必须检查后续阶段和 Watch 子进程重入是否依赖该状态。

### 4.2 参数解析

`Parse-Args` 使用 `switch -Regex` 顺序解析参数。重要规则：

- 第一个非选项参数成为 `SRC`。
- `--` 后的所有参数进入 `RUN_ARGS`。
- 多余位置参数返回退出码 `2`。
- `--debug` 只在没有 `--profile` 时映射为 `debug`。
- `--watch-clear` 和 `--watch-shell` 会隐式开启 Watch。
- `--clean` 禁止运行程序。

添加新选项时至少需要同步：

1. 文件顶部注释帮助。
2. `Show-Help`。
3. `Parse-Args`。
4. `Invoke-WatchBuild` 对原始参数的过滤规则。
5. README 命令行表。
6. 参数错误测试。
7. installer 内嵌 forge、模块和兼容载荷；通过同步工具完成。

### 4.3 输入目标识别

参数解析完成后执行：

1. 去除某些外层 runner 注入的成对引号。
2. 若路径是目录，查找目录下的 `cxxforge.json`。
3. 若路径是 `cxxforge.json`，进入项目模式。
4. 否则作为主源文件处理。

项目 JSON 解析失败或缺少 `sources` 时返回 `2`；没有任何有效源文件时返回 `3`。

### 4.4 配置合并顺序

有效配置按以下顺序形成：

1. 初始化代码默认值。
2. 读取 `forge.ps1` 同目录的 `compiler_config.json`。
3. 将项目 `includes` 和 `links` 追加到机器配置。
4. 若基础 C/C++ flags 为空，填充内置默认参数。
5. 解析 profile：命令行 `--profile` > `--debug` > `activeProfile`。
6. 将 profile 的 C/C++ flags 和 `-D<define>` 追加到基础参数。
7. 解析 backend：命令行覆盖配置；`auto` 优先 GCC，后选 Clang。
8. 对缺失的具体编译器路径使用 `Get-Command` 从 `PATH` 查找。
9. 读取 sidecar 和魔法注释，追加局部编译/链接参数。
10. 发现或应用 include/lib 路径。

项目 `includes` 和 `links` 必须在读取机器配置后合并，否则初始化配置可能覆盖项目数据。代码中已有专门注释保护这个顺序。

### 4.5 编译器选择

支持的语言映射：

| 扩展名 | 语言 | GCC | Clang |
|---|---|---|---|
| `.c` | C | `gcc` | `clang` |
| `.cpp`, `.cc`, `.cxx`, `.c++` | C++ | `g++` | `clang++` |

混合项目逐翻译单元选择编译器。如果项目包含任意 C++ 源文件，最终链接使用 C++ 驱动，以自动链接 C++ runtime。

### 4.6 环境加固

`injectCompilerBinToPath` 为真时，runner 将当前编译器所在目录放到进程级 `PATH` 前端。这主要解决 MinGW 无法找到 `cc1`、`ld` 或运行时 DLL 的问题，不修改用户或系统永久环境变量。

`forceAsciiTemp` 为真时，若 TEMP/TMP 缺失或包含非 ASCII 字符，则在当前进程中切换到 `%LOCALAPPDATA%\cpp-tmp`。这用于兼容部分旧工具链对 Unicode 临时路径的处理缺陷。

### 4.7 单文件与 sidecar 编译

非项目模式构造一次完整命令：

```text
compiler
  + language flags
  + profile flags/defines
  + magic/sidecar flags
  + color flag
  + include/lib path flags
  + all source files
  + -o output.exe
  + link flags
```

这里的 sidecar `sources` 只是将多个源文件交给编译器的一次调用，不会生成单独对象 metadata。

### 4.8 项目增量构建

项目输出目录中建立：

```text
.cxxforge/
├─ link.meta.json
└─ obj/
   ├─ <basename>.<12-char-path-hash>.o
   ├─ <basename>.<12-char-path-hash>.o.d
   └─ <basename>.<12-char-path-hash>.o.meta.json
```

#### 对象文件命名

源文件绝对路径转为小写后计算稳定 SHA-256，取前 12 位加入对象名。此设计解决：

```text
src/collision.c
lib/collision.cpp
```

不能同时映射到 `collision.o` 的问题。

#### 编译指纹

每个对象的指纹由以下内容组成：

- 编译器身份，包括路径和 `--version` 首行。
- 语言类型。
- 标准化源文件绝对路径。
- 当前翻译单元的完整编译参数。

`Get-RebuildReason` 同时检查源文件、对象、`.d` 依赖、metadata 和时间戳。

#### 依赖文件

编译参数加入：

```text
-MMD -MP -MF <temporary-dependency-file>
```

`Get-DependencyPaths` 解析 Make 风格 `.d` 文件，处理续行和反斜杠，再将依赖头文件时间与对象比较。

#### 原子对象更新

新对象和依赖先写入：

```text
object.o.tmp-<PID>
object.o.d.tmp-<PID>
```

编译成功后才移动到正式路径；失败时删除临时文件。因此一次失败编译不会破坏已有对象。

#### 链接指纹

链接 metadata 包含由以下内容生成的指纹：

- 链接编译器身份。
- 完整对象文件列表。
- `-L` 路径。
- 链接 flags。
- 输出路径。

链接输出先写为 `<output>.cxxforge-tmp-<PID>.exe`，成功后原子替换正式文件。链接失败保留旧可执行文件。

### 4.9 诊断格式化

runner 捕获编译器 stdout/stderr 合并输出。`Write-DiagnosticLine` 识别典型 GCC/Clang 格式：

```text
file.cpp:12:8: error: message
```

pretty parser 维护跨行状态，用于组合诊断标题、源码行和 caret 行，并统计 error/warning。`--normalized-diag` 会额外输出稳定的日志式行，便于外层工具消费。

修改诊断 parser 时必须测试：

- error、warning、note。
- Windows 盘符路径中的冒号。
- 多行源码与 caret。
- 无文本输出但退出码非零。
- `--raw` 不应改变原始诊断。

## 5. Watch 架构

### 5.1 监视根目录

项目模式监视：

- 项目目录。
- 项目 `includes` 指定且实际存在的目录。
- `compiler_config.json` 所在目录。

单文件/sidecar 模式监视：

- 主源文件所在目录。
- `compiler_config.json` 所在目录。

根目录按规范化绝对路径去重，每个根目录创建一个递归 `FileSystemWatcher`，注册 Changed、Created、Deleted、Renamed 四类事件。

### 5.2 相关文件过滤

当前相关扩展名：

```text
.c .cc .cpp .cxx .c++ .h .hh .hpp .hxx .inl
```

此外无条件跟踪 `cxxforge.json` 和 `compiler_config.json`。

### 5.3 防抖

收到首个相关事件后等待约 350 ms，并收集队列中其余事件，最后按路径去重。该延迟用于吸收编辑器的临时文件、rename 和多次 write 事件。

### 5.4 重建方式

Watch 不在当前进程内重入整套构建逻辑，而是启动新的 PowerShell 子进程：

```text
powershell -NoProfile -ExecutionPolicy Bypass
  -File <forge-entry>
  --no-run
  [--rebuild]
  <filtered-original-arguments>
```

这样可以复用普通构建路径并隔离一次构建的诊断状态。添加 Watch 选项时必须更新 `Invoke-WatchBuild` 的过滤正则，避免将 `--watch` 再传入子进程造成递归 Watch。

### 5.5 程序进程

程序由 `System.Diagnostics.Process` 启动。参数使用 Windows 命令行转义规则拼接，处理空参数、空白、双引号和反斜杠。

停止程序时：

1. 调用 `Kill()`。
2. 最多等待 3 秒。
3. 释放输入 writer 和 Process 对象。
4. 将输入路由恢复为 shell。

### 5.6 双输入后端

Watch 根据控制台能力选择：

#### Native console handoff

条件：交互 shell 已启用，并且 `[Console]::KeyAvailable` 可用。

- `RedirectStandardInput = false`。
- 子程序直接继承控制台 stdin。
- 子程序运行时父进程不读取键盘。
- 子程序退出后父进程通过 `ReadKey` 提供 `cxxforge>`。

这是用户终端的默认稳定路径。不要重新引入“父进程逐行截获，再转发给程序”的设计；PowerShell 5.1 ConsoleHost 曾出现输入被父子路径重复消费以及子程序提前读取 EOF 的问题。

#### Redirected compatibility backend

无法使用控制台按键时：

- `RedirectStandardInput = true`。
- 父进程使用 `Console.In.ReadLineAsync()`。
- 普通行可以转发到子程序 writer，命令行进入 Watch parser。

此路径主要服务自动测试和重定向环境。它不是交互终端的首选实现。

### 5.7 Ctrl+C 限制

父 PowerShell 和子程序共享 Windows 控制台。`Ctrl+C` 默认广播给共享该控制台的进程，因此会终止子程序和 Watch。要改变此行为需要 Win32 控制处理器或独立进程组；当前版本故意不实现，以避免破坏稳定输入模型。

## 6. Installer 架构

`install.ps1` 分为两部分：

1. 前后两端的安装器逻辑。
2. 中间的 `$publicEntryContent`、`$forgeContent`、四个 module content、兼容入口、batch 和 `$configJson` 生成载荷。

不要直接编辑 here-string 中的 runtime 或默认配置；修改 canonical 文件后运行同步工具。

### 6.1 参数和模式

| 参数 | 作用 |
|---|---|
| `Workspace` | 目标工作区；默认安装器目录。 |
| `TargetDir` | 模块化 runtime 安装目录；默认 `cxxforge`，且必须位于 workspace 内。 |
| `Force` | 允许覆盖现有受管内容，并创建备份。 |
| `WhatIf` | 只报告操作，不写文件。 |
| `Upgrade` | 基于旧 manifest 安全升级。 |
| `Repair` | 恢复受管核心文件。 |
| `Uninstall` | 根据 manifest 卸载。 |
| `NoVSCode` | 不创建或修改 `.vscode`。 |

Upgrade、Repair、Uninstall 互斥。

### 6.2 Manifest

安装后写入：

```text
.cxxforge/manifest.json
```

结构：

```json
{
  "schemaVersion": 2,
  "installerVersion": "2.0.0-dev.8",
  "targetDir": "cxxforge",
  "publicEntry": "cxxforge.ps1",
  "migratedFrom": null,
  "vscodeEnabled": true,
  "installedAtUtc": "...",
  "files": [
    {
      "path": "cxxforge.ps1",
      "hash": "sha256...",
      "managed": true,
      "userConfig": false
    }
  ]
}
```

manifest 是升级和卸载的信任边界。卸载前会将记录路径解析为绝对路径，并验证其仍位于 workspace 内。默认安装共记录 9 个文件：根目录公开入口，以及 runtime 目录中的入口、四个模块、两个兼容入口和机器配置。

### 6.3 旧 `files` 布局迁移

当旧 manifest 为 schema 1、`targetDir` 是 `files`，且用户没有显式传入 `TargetDir` 时，安装器自动迁移到默认 `cxxforge` 布局：

1. 将旧 `files/compiler_config.json` 内容作为新机器配置。
2. 写入根目录公开入口与新 runtime。
3. 仅删除哈希仍等于旧 manifest 的旧受管文件。
4. 保留已修改的旧文件并输出警告。
5. 仅在旧目录为空时清理目录。

根目录 `cxxforge.ps1` 若已存在但不属于 manifest 管理，默认中止安装；`-Force` 会先备份再替换。所有目标和 manifest 路径都必须位于 workspace 内。

### 6.4 文件安装决策

`Install-ManagedContent` 的行为：

| 情况 | 行为 |
|---|---|
| 文件不存在 | 创建，记录新哈希并标为 managed。 |
| 普通重复安装且文件存在 | 跳过。 |
| Upgrade，当前哈希等于旧 manifest 哈希 | 安全覆盖。 |
| Upgrade，文件已修改 | 保留原文件，写入 `.cxxforge-new`。 |
| Repair | 覆盖核心受管文件。 |
| `PreserveOnUpgrade` 配置文件 | Upgrade/Repair 默认保留。 |
| Force | 覆盖并先备份。 |

备份写入 `.cxxforge/backups`，文件名由完整路径转义和时间戳组成。

### 6.5 卸载决策

卸载仅删除同时满足以下条件的文件：

1. manifest 记录为 managed。
2. 解析后的路径位于 workspace 内。
3. 文件当前 SHA-256 等于 manifest 记录哈希。

被用户修改的文件会保留。没有有效 manifest 时拒绝卸载，因为无法安全区分用户文件和 CXXForge 文件。

### 6.6 JSONC 管理块

installer 使用标记：

```text
// CXXForge:TASKS:BEGIN
// CXXForge:TASKS:END
```

对应 marker 包括 TASKS、SETTINGS、CPP、LAUNCH。

算法不是将整个 JSONC 反序列化后重写，而是：

1. 扫描字符串、转义字符、行注释和块注释。
2. 找到目标 property 的数组或根对象插入位置。
3. 仅替换 CXXForge 管理块。
4. 保留管理块之外的文本。

测试覆盖 URL 中的 `//`、用户注释、内联注释、缩进和卸载后的精确保留。

### 6.7 Code Runner 所有权

若 `settings.json` 没有 executor map，installer 可创建自己的管理块。若已有 C/C++ 映射且不是 CXXForge 管理的映射，则视为用户所有，保持文件字节不变并警告。

## 7. 版本与载荷同步

版本发布流程以 `VERSION` 为唯一人工入口。

同步脚本的关键约束：

- `VERSION` 必须符合 SemVer 基本形式。
- canonical `Core.ps1` 中必须恰好有一个 `$SCRIPT_VERSION = '...'`。
- installer 中必须恰好有一个顶层 `$INSTALLER_VERSION = '...'`。
- installer 必须恰好有一个 `$runActiveContent` 和一个 `$configJson` 单引号 here-string。
- payload 本身不能包含会提前终止对应 here-string 的独立 `'@` 行。
- 同步后 installer 仍必须通过 PowerShell parser。
- 同步必须幂等。

标准命令：

```powershell
.\tools\sync-installer-payload.ps1
```

可用 `-InstallerPath` 指向安装器副本进行实验，避免覆盖根目录发布文件。

## 8. 测试架构

### 8.1 快速集成测试

```powershell
.\tests\integration.ps1
```

覆盖：

- C/C++ 混合项目。
- 不同目录同名对象。
- 第二次构建跳过未变化对象。
- 删除可执行文件后仅重新链接。
- sidecar 源文件相对路径。

输出写入 `tests/.artifacts`。

### 8.2 完整回归测试

```powershell
.\tests\comprehensive.ps1
```

测试会在系统临时目录建立带空格的隔离根目录，以暴露路径转义问题。当前测试类别包括：

1. PowerShell 语法和 JSON 解析。
2. help、错误参数、缺失源文件、扩展名和 backend 校验。
3. 单 C、单 C++、参数传递、profile 和输出路径。
4. magic flags、诊断格式和程序退出码传播。
5. `.d` 依赖、profile 指纹和增量重建。
6. Watch 文件事件、长运行程序中断和重启。
7. 重定向 Watch shell 的重复运行和多行 stdin。
8. 原子链接失败时保留旧可执行文件。
9. clean。
10. payload 同步幂等性。
11. installer WhatIf、安装、重复安装、升级、修复和卸载。
12. JSONC 注释、缩进、URL 和用户配置保留。
13. NoVSCode 和 Code Runner 冲突保护。

测试结束必须打印：

```text
[SUMMARY] passed=<n> failed=0
```

### 8.3 测试盲区

自动化环境通常使用重定向 stdin，无法完整验证真实 ConsoleHost 的 native console handoff。因此发布前还需要人工冒烟测试：

1. 运行读取两行 `cin` 的程序。
2. 确认没有提前 EOF。
3. 程序退出后输入 `run`，再次输入数据。
4. 运行长任务并保存头文件，确认旧进程停止且新程序启动。
5. 确认 `Ctrl+C` 结束整个 Watch，符合当前文档。

## 9. 修改工作流

### 9.1 修改 runtime

```text
按职责编辑 cxxforge/modules/*.ps1、cxxforge/forge.ps1 或根目录 cxxforge.ps1
  ↓
运行 PowerShell parser
  ↓
运行 integration.ps1
  ↓
运行 comprehensive.ps1
  ↓
运行 sync-installer-payload.ps1
  ↓
再次检查 install.ps1 parser 与 payload 一致性
```

推荐命令：

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path '.\cxxforge\forge.ps1'),
    [ref]$null,
    [ref]$errors
) > $null
$errors

.\tests\integration.ps1
.\tools\sync-installer-payload.ps1
.\tests\comprehensive.ps1
```

### 9.2 修改 installer

只修改生成 payload 区域之外的安装器逻辑。`$forgeContent`、module content、`$runActiveContent`、`$batchContent` 和 `$configJson` 必须从 canonical 文件同步。

installer 改动重点测试：

- 空工作区首次安装。
- 已存在用户 JSONC 的安装。
- 普通重复安装。
- 修改 forge 入口或模块后 Upgrade。
- Repair 是否恢复入口和模块并保留 compiler config。
- Uninstall 是否保留用户修改。
- WhatIf 是否零写入。

### 9.3 修改配置字段

新增 `compiler_config.json` 字段时同步修改：

- Core/Configuration 模块中的默认变量和读取逻辑。
- `compiler_config.default.json`。
- 必要时 installer 的 IntelliSense 推导。
- README 字段表。
- comprehensive 测试。

### 9.4 修改项目 schema

新增 `cxxforge.json` 字段时同步修改：

- 项目解析与路径基准。
- 增量编译或链接指纹。
- Watch 根目录。
- README schema。
- fixture 和测试。

凡是能影响编译或链接结果的字段，都必须进入相应 fingerprint，否则缓存会错误命中。

## 10. 发布检查清单

1. 修改 `VERSION`，不要直接改两个脚本中的版本常量。
2. 运行 `sync-installer-payload.ps1`。
3. 再运行一次同步，确认 `install.ps1` 哈希不变。
4. 确认 forge、四个模块、兼容入口与 installer 的 PowerShell parser 无错误。
5. 运行快速集成测试。
6. 运行完整回归测试，要求 `failed=0`。
7. 执行真实交互终端 Watch 冒烟测试。
8. 用 `install.ps1 -WhatIf` 检查目标动作。
9. 在临时工作区执行一次真实安装和卸载。
10. 检查工作区没有 `.bak`、`.cxxforge-new`、测试 exe 或意外缓存。
11. 确认 README、DEVELOPMENT 和 `--help` 一致。

## 11. 稳定性不变量

以下行为应视为回归保护线：

- 编译失败不得覆盖已有对象。
- 链接失败不得覆盖已有可执行文件。
- 不同路径的同名源文件不得共享对象路径。
- 头文件变化必须使依赖对象失效。
- 编译器或参数变化必须使指纹失效。
- Watch 保存文件时必须停止旧进程再启动新进程。
- 真实交互终端必须由程序直接读取 stdin。
- 普通安装不得覆盖已存在文件。
- Upgrade 不得覆盖已被用户修改的受管文件。
- Repair 默认不得覆盖 `compiler_config.json`。
- Uninstall 不得删除哈希已经变化的用户文件。
- JSONC 管理不得破坏管理块之外的用户文本。
- installer 中的 forge、模块和兼容 payload 必须与 canonical 文件完全一致。
- 模块必须通过 `Exit-CxxForge` 返回退出码，不能直接 `exit` 后让后续阶段继续执行。
- 版本号必须来自 `VERSION`。

## 12. 当前技术债务与风险

### 12.1 顺序模块仍共享状态

职责已经拆到四个文件，但它们通过 dot-source 共享 forge script scope，并且加载顺序不可交换。这是保持旧行为的过渡架构，不等同于依赖完全显式的独立 PowerShell module。未来可逐步引入 build context，但每次迁移都应保持现有回归测试。

### 12.2 Installer 体积和生成内容

installer 同时包含大量安装逻辑、入口和四个完整模块，代码搜索会出现重复函数。评审时应首先确认命中位置是在 canonical module 还是内嵌 payload。

### 12.3 Script scope 状态

大量 `$script:` 或顶层变量使函数依赖不显式，尤其影响诊断 parser 与 Watch。后续应优先将一组稳定状态迁入明确的 build context，而不是继续增加跨模块全局变量。

### 12.4 空 catch

少数环境探测和清理路径使用空 `catch {}`。它们避免非关键功能阻断主流程，但也降低可诊断性。未来可增加 `--verbose` 或 trace sink，在不改变默认输出的情况下记录异常。

### 12.5 JSONC 函数中的不可达旧实现

部分 installer 函数在新的文本级 JSONC 管理逻辑后立即 `return`，其后仍保留旧的对象反序列化实现。这些代码当前不可达，增加阅读成本。删除前应先确认所有 legacy 无 marker 文件的升级/卸载测试仍由现有 fallback 路径覆盖。

### 12.6 Watch 双后端

native console 与 redirected compatibility 两条输入路径提高了测试复杂度。native 路径解决真实交互，redirected 路径支撑自动化。除非能够提供 ConPTY 级测试，否则不建议再次统一为父进程 stdin 转发。

### 12.7 配置 schema 未版本化

`cxxforge.json` 和 `compiler_config.json` 当前没有 schemaVersion，也没有严格拒绝未知字段。增加 schema 和迁移策略是合理的后续工作，但必须兼容现有项目文件。

### 12.8 测试文件集中

`comprehensive.ps1` 已覆盖大量行为，但测试场景集中在一个脚本。未来可拆为 build、watch、installer 三组，同时保留一个总入口和统一摘要。

## 13. 建议的后续演进顺序

在当前架构稳定的前提下，建议顺序为：

1. 增加可选 trace/verbose，替换无信息的空 catch。
2. 为配置增加只警告不拒绝的 schema 校验。
3. 拆分 comprehensive 测试文件，但保持一个总入口。
4. 清理 installer 中明确不可达的旧 JSON 重写代码。
5. 评估“模块 runtime → 可选单文件发行 runner”的第二种发布产物；当前 installer 默认安装模块化 runtime。

不建议近期再次改写 native console handoff。该部分已经通过真实用户交互验证，收益较低而回归风险很高。简而言之：它现在工作，所以暂时不要对它产生艺术追求。
