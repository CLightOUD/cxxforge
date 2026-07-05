# CXXForge

CXXForge 是一个面向 Windows、PowerShell 5.1、GCC/Clang 的轻量 C/C++ 编译运行工具。它以工作区根目录的 `cxxforge.ps1` 为稳定公开入口，按职责加载运行时模块，同时提供增量项目构建、格式化诊断、文件监视、VS Code 集成，以及可离线分发的单文件安装器。

当前版本：`2.0.0-dev.8`

> CXXForge 不是 CMake、Meson 或完整 IDE 的替代品。它主要解决单文件练习、小型多文件项目、便携开发环境和 VS Code 快速编译运行的问题。

开发者与维护者请同时阅读 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 功能概览

- 支持 `.c`、`.cpp`、`.cc`、`.cxx`、`.c++`。
- 支持 GCC、G++、Clang、Clang++，可显式选择或自动探测。
- 支持单文件、同名 sidecar JSON、多源文件 `cxxforge.json` 三种构建方式。
- 项目模式使用 `.d` 依赖文件和参数指纹执行增量编译。
- 同名但位于不同目录的源文件会生成不同对象文件，不发生名称冲突。
- C/C++ 混合项目按翻译单元选择编译器，并在存在 C++ 源文件时使用 C++ 驱动链接。
- 编译与链接均采用临时文件后原子替换；失败不会覆盖上一次有效产物。
- 提供 `debug`、`release`、`release-with-debug` 构建配置。
- 支持结构化彩色诊断和标准化错误行。
- Watch 模式可监视源文件、头文件及配置文件，自动停止、重编译并重启程序。
- portable 安装器支持安装、升级、修复、卸载、预演及跳过 VS Code 集成。
- 安装器使用 manifest 和 SHA-256 哈希保护用户修改。
- 修改 VS Code JSONC 文件时保留非 CXXForge 内容、注释和大部分原始排版。

## 环境要求

- Windows 7 或更高版本。
- Windows PowerShell 5.1 或 PowerShell 7；主要兼容目标是 Windows PowerShell 5.1。
- GCC/MinGW-w64 或 LLVM/Clang。
- 可选：VS Code、Microsoft C/C++ 扩展、Code Runner 扩展。
- 调试功能需要 GDB。

验证 PowerShell 与编译器：

```powershell
$PSVersionTable.PSVersion
gcc --version
g++ --version
# 或
clang --version
clang++ --version
```

## 快速开始

### 使用 portable 安装器

将 `install.ps1` 放入工作区根目录，然后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

默认会创建或管理：

```text
cxxforge.ps1
cxxforge/
  forge.ps1
  run_active.ps1
  run_active.bat
  compiler_config.json
  modules/
    Core.ps1
    Configuration.ps1
    Build.ps1
    Watch.ps1
.vscode/
  tasks.json
  settings.json
  c_cpp_properties.json
  launch.json
.cxxforge/
  manifest.json
  backups/
```

安装完成后，先根据本机工具链修改 `cxxforge/compiler_config.json`。

### 直接运行

```powershell
# 编译并运行
.\cxxforge.ps1 .\main.cpp

# 只编译
.\cxxforge.ps1 --no-run .\main.cpp

# 使用 debug 配置
.\cxxforge.ps1 --profile debug .\main.cpp

# 向程序传递参数
.\cxxforge.ps1 .\main.cpp -- first second

# 指定输出目录和名称
.\cxxforge.ps1 --out-dir .\build --out-name demo .\main.cpp
```

也可以通过批处理入口调用：

```bat
cxxforge\run_active.bat main.cpp
```

`cxxforge/run_active.ps1` 仅作为旧命令兼容入口转发到内部 `forge.ps1`；新任务和脚本应只调用根目录 `cxxforge.ps1`。

## 编译器配置

模块化运行时始终从 `forge.ps1` 所在目录读取 `compiler_config.json`。portable 安装时，该文件由 `compiler_config.default.json` 初始化；升级和修复默认保留用户配置。

示例：

```json
{
  "gccPath": "D:/Toolchains/MinGW64/bin/gcc.exe",
  "gxxPath": "D:/Toolchains/MinGW64/bin/g++.exe",
  "clangPath": "",
  "clangXxPath": "",
  "compilerBackend": "auto",
  "cFlags": ["-std=c99", "-Wall", "-finput-charset=UTF-8", "-fexec-charset=UTF-8"],
  "cxxFlags": ["-std=c++14", "-Wall", "-finput-charset=UTF-8", "-fexec-charset=UTF-8"],
  "colorFlag": "-fdiagnostics-color=always",
  "includePaths": [],
  "libPaths": [],
  "linkFlags": [],
  "injectCompilerBinToPath": true,
  "forceAsciiTemp": true,
  "autoDiscoverIncludes": true,
  "autoDiscoverLibs": true,
  "activeProfile": "release",
  "profiles": {
    "debug": {
      "cFlags": ["-g", "-O0"],
      "cxxFlags": ["-g", "-O0"],
      "defines": ["_DEBUG"]
    },
    "release": {
      "cFlags": ["-O2"],
      "cxxFlags": ["-O2"],
      "defines": ["NDEBUG"]
    },
    "release-with-debug": {
      "cFlags": ["-O2", "-g"],
      "cxxFlags": ["-O2", "-g"],
      "defines": ["NDEBUG"]
    }
  }
}
```

### 字段说明

| 字段 | 类型 | 作用 |
|---|---|---|
| `gccPath` | string | GCC C 编译器路径；为空时从 `PATH` 查找 `gcc`。 |
| `gxxPath` | string | GCC C++ 编译器路径；为空时从 `PATH` 查找 `g++`。 |
| `clangPath` | string | Clang C 编译器路径；为空时从 `PATH` 查找 `clang`。 |
| `clangXxPath` | string | Clang C++ 编译器路径；为空时从 `PATH` 查找 `clang++`。 |
| `compilerBackend` | string | `gcc`、`clang` 或 `auto`。命令行 `--backend` 优先。 |
| `cFlags` | string[] | 所有 C 翻译单元的基础编译参数。 |
| `cxxFlags` | string[] | 所有 C++ 翻译单元的基础编译参数。 |
| `colorFlag` | string | 开启编译器彩色诊断时附加的参数。 |
| `includePaths` | string[] | 转换为 `-I<path>` 的头文件目录。 |
| `libPaths` | string[] | 转换为 `-L<path>` 的库目录。 |
| `linkFlags` | string[] | 链接阶段追加的库或链接器参数。 |
| `injectCompilerBinToPath` | bool | 将编译器目录加入当前进程 `PATH`，帮助定位 `cc1`、链接器和 DLL。 |
| `forceAsciiTemp` | bool | TEMP/TMP 含非 ASCII 字符时切换到 ASCII 临时目录。 |
| `autoDiscoverIncludes` | bool | `includePaths` 为空时尝试发现 MinGW 常见 include 目录。 |
| `autoDiscoverLibs` | bool | `libPaths` 为空时尝试发现 MinGW 常见 lib 目录。 |
| `activeProfile` | string | 未指定命令行 profile 时使用的配置。 |
| `profiles` | object | profile 名称到编译参数与宏定义的映射。 |

配置优先级：

1. 命令行 `--backend`、`--profile` 或 `--debug`。
2. `compiler_config.json`。
3. `PATH` 中可发现的工具链。

当 `compilerBackend` 为 `auto` 时，当前实现优先选择可用的 GCC，否则选择 Clang。

## 构建模式

### 单文件模式

直接传入源文件：

```powershell
.\cxxforge.ps1 .\src\main.cpp
```

默认输出为源文件同目录下的 `main.exe`。单文件模式每次调用都会执行一次完整编译链接，不使用项目增量对象缓存。

### Sidecar 模式

若主源文件旁存在同名 JSON，runner 会自动读取它：

```text
src/
  main.cpp
  main.json
  helper.cpp
```

`main.json`：

```json
{
  "sources": ["main.cpp", "helper.cpp"],
  "flags": ["-DMY_FEATURE=1"],
  "link": ["-lws2_32"]
}
```

Sidecar 中的源文件路径相对于主源文件目录解析。该模式最终仍执行一次完整编译链接，不使用 `cxxforge.json` 的对象级增量构建。

### 项目模式

可以传入 `cxxforge.json`，也可以传入包含该文件的目录：

```powershell
.\cxxforge.ps1 .\my-project\cxxforge.json
.\cxxforge.ps1 .\my-project
```

示例：

```json
{
  "sources": [
    "src/main.cpp",
    "src/network.c",
    "lib/helper.cpp"
  ],
  "outName": "my-app",
  "outDir": "build",
  "includes": ["include"],
  "links": ["-lws2_32"]
}
```

| 字段 | 必需 | 说明 |
|---|---|---|
| `sources` | 是 | 非空源文件数组，路径相对于 `cxxforge.json`。不存在的文件会警告；全部无效时构建失败。 |
| `outName` | 否 | 输出文件基本名，不包含 `.exe`；默认使用项目目录名。 |
| `outDir` | 否 | 输出和缓存根目录，相对于项目目录。 |
| `includes` | 否 | 附加 include 目录，相对于项目目录。 |
| `links` | 否 | 追加到链接阶段的参数。 |

当前实现会在参数解析之后加载项目文件，因此项目中的 `outDir` 和 `outName` 会覆盖同名命令行设置；项目未提供相应字段时，命令行值才会生效。维护者若调整此优先级，必须同步更新缓存和测试说明。

### 源文件魔法注释

为兼容简单练习文件，runner 会扫描主源文件前 50 行：

```cpp
// ra-flags: -DLOCAL_TEST -Wextra
// ra-link: -lws2_32
```

参数按空白拆分，不支持复杂 shell 引号语义。长期项目应优先使用 JSON 配置。

## 增量构建

增量构建只用于 `cxxforge.json` 项目模式。状态位于输出目录下：

```text
build/
  my-app.exe
  .cxxforge/
    link.meta.json
    obj/
      main.<path-hash>.o
      main.<path-hash>.o.d
      main.<path-hash>.o.meta.json
```

每个对象文件名包含源文件绝对路径的稳定哈希，因此不同目录下的同名文件不会冲突。

以下情况触发重新编译：

- 使用 `--rebuild`。
- 对象文件、依赖文件或 metadata 缺失。
- 源文件或 `.d` 中记录的头文件比对象文件新。
- 编译器身份、语言、源文件路径或有效编译参数指纹发生变化。
- metadata 无法读取。

以下情况触发重新链接：

- 可执行文件缺失。
- 任一对象文件重新生成或晚于可执行文件。
- 链接器、对象列表、库路径、链接参数或输出路径指纹变化。
- 链接 metadata 缺失或无效。

查看具体原因：

```powershell
.\cxxforge.ps1 --no-run --explain .\my-project
```

强制全量重建：

```powershell
.\cxxforge.ps1 --no-run --rebuild .\my-project
```

清理项目产物：

```powershell
.\cxxforge.ps1 --clean .\my-project
```

编译和链接先写入带 PID 的临时文件，成功后再替换正式对象或可执行文件。失败时会删除临时文件并保留上一次有效产物。

## Watch 模式

```powershell
.\cxxforge.ps1 --watch .\main.cpp
.\cxxforge.ps1 --watch .\my-project
.\cxxforge.ps1 --watch --no-run .\my-project
```

Watch 使用 `FileSystemWatcher` 监视：

- `.c`、`.cpp`、`.cc`、`.cxx`、`.c++`。
- `.h`、`.hpp`、`.hh`、`.hxx`。
- `cxxforge.json`。
- `compiler_config.json`。

编辑器保存文件通常会产生多个事件，因此事件会先等待约 350 ms，再合并为一次重建。

### 原生终端输入模型

在真实交互终端中，程序运行时直接拥有控制台输入。这保证 `cin`、`scanf` 等行为与直接运行 `.exe` 一致：

```text
[WATCH] Input backend: native console handoff
[WATCH] Program started ...
4
4 1 3 2
1 2 3 4
[WATCH] Program exited with code 0; monitoring continues.
cxxforge>
```

程序运行期间：

- 普通输入直接进入程序。
- Watch 仍在后台监视文件，保存源文件会停止当前程序、构建并重启。
- Watch 命令暂不可用。
- `Ctrl+C` 是 Windows 控制台广播信号，会同时终止子程序和 Watch 会话。

程序退出后可使用：

| 命令 | 作用 |
|---|---|
| `run [args...]` | 再次运行当前可执行文件，可替换保存的参数。 |
| `build` | 增量构建。 |
| `rebuild` | 强制全量构建。 |
| `restart` | 构建并运行。 |
| `status` | 显示目标、进程状态和保存的参数。 |
| `args [args...]` | 修改后续运行参数。 |
| `clear` | 清屏。 |
| `help` | 显示命令。 |
| `quit` / `exit` | 离开 Watch。 |

重定向输入环境使用兼容命令层，可用 `--watch-shell` 强制开启，或用 `--no-watch-shell` 禁用。该路径主要供自动化测试使用。

`--watch-clear` 会在每次重建前清屏；默认保留终端历史。

## 诊断输出

- `--pretty`：结构化、彩色输出，默认启用。
- `--raw`：保留编译器原始输出，适合 VS Code problem matcher。
- `--normalized-diag`：额外输出 `[ERROR] file:line:column: message` 风格诊断。
- `--color` / `--no-color`：控制彩色输出。
- `--force-ansi`：强制 ANSI 转义颜色，通常不需要。

若工具链存在中文路径或 DLL 搜索问题，可保留：

```json
{
  "injectCompilerBinToPath": true,
  "forceAsciiTemp": true
}
```

## VS Code 集成

安装器创建四个任务：

- `Run Active (PS)`：格式化诊断并运行当前文件。
- `Compile Active (PS)`：只编译，使用原始诊断。
- `Debug Active (PS)`：以 debug profile 编译。
- `Watch Active (PS)`：启动 Watch。

同时管理：

- `settings.json` 中 Code Runner C/C++ 映射。
- `c_cpp_properties.json` 中名为 `CXXForge` 的 IntelliSense 配置。
- `launch.json` 中名为 `CXXForge: Debug Active File` 的调试配置。

安装器使用 `// CXXForge:<MARKER>:BEGIN/END` JSONC 管理块。已有用户任务、配置、注释和无关设置不会被整体覆盖。若检测到用户自有的 Code Runner C/C++ 映射，安装器会保留它们并给出警告。

## Portable 安装器生命周期

### 指定工作区和安装目录

```powershell
.\install.ps1 -Workspace D:\work\demo -TargetDir tools\cxxforge
```

`Workspace` 默认为安装器所在目录，`TargetDir` 默认为 `cxxforge`。根目录 `cxxforge.ps1` 会根据实际 `TargetDir` 指向内部 `forge.ps1`。`TargetDir` 必须解析到工作区内部；根目录若已有非 CXXForge 管理的同名入口，安装器会拒绝覆盖，除非显式使用 `-Force` 并先创建备份。

### 预演

```powershell
.\install.ps1 -WhatIf
```

显示将执行的操作，但不写入工作区。

### 升级

```powershell
.\install.ps1 -Upgrade
```

- 未修改的 `forge.ps1`、模块和兼容入口会更新。
- 已修改的受管文件会保留，新版本写入 `.cxxforge-new` 候选文件。
- `compiler_config.json` 默认保留。

从 schema 1 的旧 `files` 布局升级且未显式指定 `TargetDir` 时，安装器会自动迁移到 `cxxforge`：复制旧机器配置、删除哈希未变化的旧受管文件，并保留所有已修改的旧文件。迁移来源记录在 schema 2 manifest 的 `migratedFrom` 字段。

### 修复

```powershell
.\install.ps1 -Repair
```

- 恢复受管 `forge.ps1`、模块和兼容入口。
- 默认仍保留 `compiler_config.json`。
- 使用 `-Force` 时允许覆盖原有内容，并先在 `.cxxforge/backups` 中备份。

### 卸载

```powershell
.\install.ps1 -Uninstall
```

卸载依据 `.cxxforge/manifest.json` 中的路径和哈希进行：未修改的受管文件可删除，已修改文件会保留；CXXForge 的 VS Code 管理块会移除。没有有效 manifest 时拒绝执行不安全卸载。

### 不集成 VS Code

```powershell
.\install.ps1 -NoVSCode
```

仅安装模块化运行时、兼容入口、batch 和编译器配置。

`-Upgrade`、`-Repair`、`-Uninstall` 三种模式互斥。

## 命令行参考

```text
cxxforge.ps1 [options] <source-file|project-directory|cxxforge.json> [-- <program-args>]
```

| 参数 | 说明 |
|---|---|
| `-r`, `--run` | 编译并运行，默认行为。 |
| `-n`, `--no-run` | 只编译。 |
| `-d`, `--debug` | 选择 debug profile，除非已显式指定 `--profile`。 |
| `-p`, `--profile <name>` | 选择构建 profile。 |
| `-b`, `--backend <name>` | 选择 `gcc`、`clang` 或 `auto`。 |
| `-w`, `--watch` | 启用 Watch。 |
| `--watch-clear` | Watch 重建前清屏。 |
| `--watch-shell` | 强制启用兼容命令层。 |
| `--no-watch-shell` | 禁用 Watch 命令层。 |
| `-R`, `--rebuild` | 强制项目全量重建。 |
| `--clean` | 删除 CXXForge 构建输出后退出。 |
| `--explain` | 输出增量决策原因。 |
| `--raw` | 原始诊断。 |
| `--pretty` | 结构化诊断。 |
| `--normalized-diag` | 输出标准化诊断行。 |
| `--color`, `--no-color` | 开关颜色。 |
| `--force-ansi` | 强制 ANSI 颜色。 |
| `--out-dir <dir>` | 指定输出目录。 |
| `--out-name <name>` | 指定输出基本名。 |
| `--utf8-init` | 将当前控制台初始化为 UTF-8。 |
| `-h`, `--help` | 显示帮助。 |
| `--` | 后续参数传给被编译程序。 |

## 退出码

| 退出码 | 含义 |
|---:|---|
| `0` | 成功。 |
| `2` | 参数错误、项目 JSON 无效或缺少必要字段。 |
| `3` | 源文件不存在或项目没有有效源文件。 |
| `4` | 找不到所需编译器。 |
| `5` | 无法启动编译器或链接器。 |
| `10` | 不支持的源文件扩展名。 |
| 其他 | 通常为编译器、链接器或被运行程序返回的退出码。 |

## 常见问题

### 找不到编译器

填写绝对路径，或将工具链 `bin` 加入 `PATH`：

```json
{
  "gccPath": "D:/Toolchains/MinGW64/bin/gcc.exe",
  "gxxPath": "D:/Toolchains/MinGW64/bin/g++.exe"
}
```

### 编译器退出但没有诊断

常见原因是 MinGW DLL、`cc1` 或链接器不在搜索路径。检查 `injectCompilerBinToPath`，并确认工具链目录完整。

### 中文乱码

使用 `--utf8-init`，或通过安装器生成的 VS Code 任务运行；任务会设置代码页和 PowerShell 输入输出编码。

### 项目没有重新编译

使用 `--explain` 查看决策；必要时使用 `--rebuild`。若缓存损坏，可执行 `--clean` 后重建。

### Watch 中程序等待输入

直接输入即可，不要先输入 `run`。程序运行期间终端属于程序，程序退出后才会出现 `cxxforge>`。

## 测试与发布

快速集成测试：

```powershell
.\tests\integration.ps1
```

完整回归测试：

```powershell
.\tests\comprehensive.ps1
```

版本和 portable 载荷同步：

```powershell
# 只修改 VERSION，然后运行：
.\tools\sync-installer-payload.ps1
```

`VERSION` 是版本号唯一人工来源。同步工具会更新 Core 模块与 installer 的版本常量，并把公开入口、内部 `forge.ps1`、四个模块、兼容入口、batch 与默认配置嵌入 `install.ps1`。发布前必须确认同步连续执行两次不会改变文件，并运行完整回归测试。

## 当前边界

- 目前仅针对 Windows 和 PowerShell 进行设计。
- 项目描述文件不是完整构建系统，不支持目标图、生成器表达式或跨平台工具链文件。
- Sidecar 模式不使用对象级增量缓存。
- Watch 的原生控制台模式无法在程序运行期间同时提供 Watch 命令。
- `Ctrl+C` 会结束整个 Watch 会话，这是共享 Windows 控制台的默认行为。
- Clang/MSVC 风格以外的诊断格式可能无法被 pretty parser 完整识别。

这些限制是当前稳定架构的一部分，不应在没有交互终端回归测试的情况下“顺手优化”。

## 贡献者

贡献者与协作说明见 [CONTRIBUTORS.md](CONTRIBUTORS.md)。

## 许可证

CXXForge 使用 [Mozilla Public License 2.0](LICENSE) 发布。
