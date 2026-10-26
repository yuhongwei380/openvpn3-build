# 详细构建说明

从 [openvpn3-client](https://github.com/yuhongwei380/openvpn3-client) 获取源码，将其中的 `config/client.ovpn` 替换成自己的配置，然后调用上游脚本，在本机构建私有客户端安装包。

默认使用仓库根目录的 `node install.mjs`，自动识别 OS、准备依赖并打包。Windows 和 macOS 脚本分别位于 `scripts/windows/`、`scripts/macos/`；旧入口也默认自动选择当前平台。Windows 安装包需要在 Windows 上构建，macOS 安装包需要在 Mac 上构建。

## 目录

```text
config/upstream.json         上游地址和固定的源码提交
private/client.ovpn         自己的配置，需自行放入，不提交 Git
install.mjs                总入口：自动识别 OS、准备依赖并构建
scripts/build.ps1           PowerShell 兼容入口，调用总入口
scripts/build.sh            Bash 兼容入口，调用总入口
scripts/build.mjs           底层构建流程，默认自动选择平台
scripts/windows/setup.ps1   准备 Git 和 Rust MSVC
scripts/macos/setup.sh      准备 Homebrew 依赖、Rust 和库搜索路径
scripts/windows/build.ps1   直接构建 Windows x64
scripts/macos/build.sh      直接构建当前 Mac 架构的应用和 DMG
scripts/lib/                源码获取、配置替换和安装包归集
.work/<平台>/source/        上游源码、依赖及构建缓存，不提交 Git
dist/<平台>/<构建编号>/     本次安装包及 build-info.json，不提交 Git
```

## 构建前准备

总入口需要 **Node.js 22+（包含 npm）**，无需先执行 `npm install`。Windows 缺少 Git 或 Rust 时通过 winget 安装，CMake、Visual Studio C++、OpenSSL 和头文件交给上游引擎脚本准备。macOS 使用已安装的 Homebrew 补齐原生依赖，缺少 rustup 时通过官方安装脚本安装；根据 Node.js 架构选择 Rust 工具链并配置 CMake/pkg-config 路径。环境路径只传递给当前构建进程，不写入 shell 配置文件；包管理器和安装器可能自行注册系统 PATH。首次构建会下载 npm、Cargo、OpenVPN 3 和驱动等依赖，需要网络。

自动安装的工具会保留在系统中。`--no-auto-install-deps` 跳过总入口的环境安装，也关闭 Windows 上游的自动依赖安装。`--prepare-only` 完全跳过环境安装和编译，此时 Git 需要已安装。下面的手动准备步骤适用于自行管理环境的情况。

将自己的、包含完整内嵌证书的配置放到 `private/client.ovpn`，也可以使用 `--profile` 传入其他文件。`<ca>`、`<cert>`、`<key>`、`<tls-crypt>` 等内容直接写在 `.ovpn` 内；客户端运行时使用临时配置文件，`ca ca.crt`、`key client.key` 等外部文件引用不可用，入口会报错。账号密码通过客户端登录界面输入；`auth-user-pass` 不附加密码文件。

配置、源码缓存、安装包均已加入 `.gitignore`。配置会编译进客户端，**本地私有构建不等于配置加密**，请妥善保存安装包及缓存。

### Windows

建议使用 Windows 10/11 x64，安装：

- Node.js 22+、Git、Rust stable MSVC（通过 rustup 安装）。
- Visual Studio 2022 Build Tools，勾选“使用 C++ 的桌面开发”、MSVC x64 工具和 Windows SDK。
- CMake、OpenSSL 开发库，以及 Asio、fmt 头文件。上游默认会尝试安装缺少的工具或下载头文件，可能触发系统授权；使用 `--no-auto-install-deps` 可关闭此行为并自行准备依赖。

可按实际安装位置指定上游依赖：

```powershell
$env:OPENSSL_ROOT_DIR = 'C:\Program Files\OpenSSL-Win64'
$env:ASIO_INCLUDE_DIR = 'D:\dependencies\asio\include' # 内含 asio.hpp
$env:FMT_INCLUDE_DIR = 'D:\dependencies\fmt\include'   # 内含 fmt/core.h
```

在仓库目录执行，会自动选择 Windows：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1
```

直接构建 Windows，或指定其他配置：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1 --platform windows --profile 'D:\vpn\company.ovpn' --no-auto-install-deps
```

入口会调用上游 `build/windows/package.ps1`，按需编译引擎、执行 `npm ci`、打包 NSIS 安装器并校验产物。最终 `.exe` 保存在 `dist/windows/<构建编号>/`。

### macOS

需要 macOS 13.3+、Node.js 22+、Git、Rust stable、Xcode Command Line Tools、CMake 和 OpenVPN 3 原生依赖。Apple Silicon 和 Intel 分别在对应架构的 Mac 环境构建；本入口不提供交叉编译或 universal 合包。

先安装 Xcode 命令行工具。在已安装 Homebrew 的环境中，安装当前固定版本的 OpenVPN 3 依赖，并设置 OpenSSL 的 pkg-config 搜索路径：

```bash
xcode-select --install
# 等待 Xcode 命令行工具安装完成后继续
brew install asio cmake jsoncpp lz4 openssl@3 pkg-config xxhash
export CMAKE_PREFIX_PATH="$(brew --prefix):$(brew --prefix openssl@3)${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
```

安装 Homebrew 依赖时，请使用与当前 Node.js、Rust 一致的架构环境；不要在 Apple Silicon 的原生环境中混用 Intel Homebrew 库。更多选项见[上游构建说明](https://github.com/yuhongwei380/openvpn3-client/blob/9930bb2125e36d0a8be6ecff764d660c58b07ca2/docs/building.md)。

在仓库目录执行，会自动选择 macOS：

```bash
bash scripts/build.sh
```

直接构建 macOS，或指定其他配置：

```bash
bash scripts/macos/build.sh
bash scripts/build.sh --platform macos --profile "$HOME/vpn/company.ovpn"
```

入口会调用上游 `build/macos/package.sh`，执行 `npm ci`、按需编译引擎、验证动态库并生成 `.app` / `.dmg`。DMG 归集到 `dist/macos/<构建编号>/`，`.app` 保留在源码缓存的 `src-tauri/target/release/bundle/macos/`。

签名和公证沿用上游 Tauri 环境配置，例如 `APPLE_SIGNING_IDENTITY`；未配置时沿用上游的本地 ad-hoc 签名流程。

## 参数和常用操作

所有入口共用相同的 `--参数`。平台专用入口已经设置平台，不需要再传 `--platform`。

| 参数 | 作用 |
| --- | --- |
| `--platform windows` / `macos` | 显式指定平台；实际编译仍要求对应操作系统 |
| `--platform auto` | 根据当前操作系统选择平台，默认行为 |
| `--profile PATH` | 指定私有配置；相对路径相对于执行命令时的目录 |
| `--prepare-only` | 只获取固定版本源码并替换配置，不安装依赖、不编译；允许在其他系统准备源码 |
| `--force-engine` | 强制重新编译 OpenVPN 3 引擎 |
| `--skip-engine` | 复用已有且通过上游版本、提交、哈希校验的引擎；缺失或不匹配会失败 |
| `--no-auto-install-deps` | 跳过总入口环境安装；Windows 还会关闭上游自动安装依赖 |
| `--help` | 查看帮助 |

`--force-engine` 和 `--skip-engine` 不能同时使用。引擎选项不影响上游的 `npm ci`。无参数自动识别当前系统，交互终端和非交互执行的行为相同，不显示平台选择菜单。

仅准备源码并检查替换结果：

```bash
node install.mjs --prepare-only --profile /path/to/company.ovpn
```

也可以通过 npm 调用（无需安装本仓库依赖）：

```bash
npm run build
npm test
```

默认固定到 `config/upstream.json` 中的完整提交，以便重复构建。更新上游时，先核对目标版本，再修改该文件的 `commit`；下一次执行会获取并切换到新提交。已有提交会直接使用本地缓存，无需重复下载源码。固定提交不代表所有第三方依赖均可离线重建，具体下载和锁定规则沿用上游。

每次构建会先完整替换配置，保留未变化配置的时间戳以复用编译缓存。源码目录除托管的 `config/client.ovpn` 外如有本地改动，脚本会停止；请保存改动并将 `.work/<平台>/source` 移到其他位置，再重新执行。更换 `repository` 地址时也需移开原源码缓存。

同平台构建通过 `.work/<平台>/build.lock` 防止并发替换配置；若进程被强制终止，确认原构建进程已退出后，删除该锁文件再重试。

每次成功构建使用单独输出目录，验证上游产物的大小及 SHA-256，并生成 `build-info.json`，记录源码提交、配置 SHA-256 和安装包哈希，不记录配置正文。构建失败会返回非零退出码，不将旧安装包归集为本次产物。需要清理缓存时可自行删除 `.work/` 和不再需要的 `dist/` 构建目录。

## 验证范围

`npm test` 使用本地 Git 和打包夹具验证自动 OS 选择、总入口调度、安装选项、环境传递、源码获取、配置替换、固定版本升级、缓存保护、失败退出和安装包哈希归集，不下载依赖、不安装系统软件或驱动、不连接 VPN。完整 Windows 安装包、macOS 环境准备和应用仍需在各自系统上使用真实配置验证。
