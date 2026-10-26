# openvpn3-build

在本机获取 [openvpn3-client](https://github.com/yuhongwei380/openvpn3-client) 源码，替换自己的 VPN 配置，生成私有客户端安装包。

## 快速开始

1. 安装 **Node.js 22 或更新版本（包含 npm）**。
2. 将自己的配置保存为仓库里的 **`private/client.ovpn`**。
3. 打开 Windows PowerShell 或 macOS 终端，在仓库目录执行同一条命令：

```sh
node install.mjs
```

根目录的 [install.mjs](install.mjs) 是统一安装与构建入口，会自动识别 OS 和架构，无需选择菜单或传入平台参数：

| 当前环境 | 自动执行的方案 | 安装包位置 |
| --- | --- | --- |
| Windows x64 | 准备 Git、Rust MSVC、OpenSSL x64 开发包；调用上游脚本准备其余原生工具链，构建 NSIS 安装包 | `dist/windows/<构建编号>/*.exe` |
| macOS Apple Silicon / Intel | 通过 Homebrew 准备原生依赖，准备对应架构的 Rust，配置库路径，构建应用和 DMG | `dist/macos/<构建编号>/*.dmg` |

流程为：**检查配置 → 准备依赖 → 获取固定版本源码 → 替换配置 → 编译打包 → 校验并输出安装包**。已有依赖和源码缓存会复用。

默认读取本仓库的 `private/client.ovpn`，替换下载源码中的 `config/client.ovpn`。Windows 安装包必须在 Windows 上构建，macOS 安装包必须在 Mac 上构建；总入口自动选择当前系统对应的方案，不执行跨系统编译。

首次准备环境时，Windows 自动安装缺失工具需要 **winget**（Microsoft App Installer）；macOS 需要先安装 **[Homebrew](https://brew.sh/)**。若 Mac 缺少 Xcode Command Line Tools，脚本会启动系统安装提示，完成后重新执行同一条命令。系统安装程序可能要求管理员授权。

这里的“安装”是准备构建环境并生成安装包，生成的 VPN 客户端由你自行安装。

Windows 会复用已有的完整 OpenSSL 3 x64 SDK；缺失时下载固定版本的免安装 SDK，校验 SHA-256 后解压至 `.work/windows/deps/`，自动传递 `OPENSSL_ROOT_DIR`。版本和校验值保存在 `config/windows-openssl.json`，不通过 winget 安装 OpenSSL。若曾报 `ShiningLight.OpenSSL` 未找到包，或 `ShiningLight.OpenSSL.Dev` 显示“已安装、无更新”却找不到 SDK，更新本仓库后重新运行 `node install.mjs` 即可，无需卸载系统里的 Light/4.x，也无需修改源码缓存。

## 其他用法

配置在其他位置：

```sh
node install.mjs --profile /path/to/company.ovpn
```

Windows 路径示例：`node install.mjs --profile "D:\vpn\company.ovpn"`。包含空格的路径请加引号。

只获取源码、替换配置，不安装依赖或编译（需要已安装 Git）：

```sh
node install.mjs --prepare-only
```

工具链已自行准备，希望跳过自动安装：

```sh
node install.mjs --no-auto-install-deps
```

原有 `scripts/build.ps1`、`scripts/build.sh` 和 `npm run build` 也会进入同一个自动流程。Windows、macOS 的环境准备及独立构建脚本仍分别保存在 `scripts/windows/`、`scripts/macos/`。

请使用内嵌证书的完整 `.ovpn`，不要引用旁边的证书或密码文件。私有配置、源码缓存和安装包均被 Git 忽略；配置会编译进客户端，不会被加密。

更多依赖说明、引擎选项、源码版本更新及故障处理见 [详细构建说明](docs/building.md)。运行 `npm test` 可执行本地测试；测试不安装系统依赖、不连接 VPN。

本地自动化测试覆盖构建调度、源码与配置替换、OpenSSL SDK 检测、下载校验及环境传递；真实上游源码的配置替换流程也已验证。Windows SDK 已通过实际 CMake 编译、链接和运行验证。完整安装包编译、macOS 实机环境安装和 VPN 连接仍需在目标系统上验证。
