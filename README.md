# envkit — 通用 ROS / 开发环境一键安装套件

单文件、纯 Bash 的交互式环境安装工具。多发行版、支持 ARM（Jetson / 树莓派），密钥强制指纹校验，幂等可重复执行。

灵感来自 [鱼香 ROS](https://fishros.com/) 一键安装，但为单文件 Bash 实现，并修复了原脚本中若干已确认的缺陷。

## 一行启动

```bash
source <(wget -qO- https://raw.githubusercontent.com/dongguatanglinux/ros-env-installer/main/envkit.sh)
```

或：

```bash
source <(curl -fsSL https://raw.githubusercontent.com/dongguatanglinux/ros-env-installer/main/envkit.sh)
```

执行后打开菜单，选 `0` 退出。**退出后会回到你原来的终端**，不会被关闭。

> 采用 `source <(...)` 而非 `bash <(...)`：后者会在子 shell 中执行，`exit` 只结束子 shell；
> 前者在本 shell 执行，脚本已针对此做了适配（不 `exit`、还原 `set` 选项与 trap）。

URL 直接指向 GitHub 的 raw 内容，不经过任何第三方短链服务。

> **安全提示**：`source <(wget -qO- URL)` 的语义是「URL 返回什么就原样执行什么」，
> 而本脚本会执行 sudo 装包、写 `/etc` 等特权操作。若在意安全，建议先下载审阅再执行：
>
> ```bash
> wget -qO envkit.sh https://raw.githubusercontent.com/dongguatanglinux/ros-env-installer/main/envkit.sh
> less envkit.sh
> bash envkit.sh
> ```
>
> 也可以固定指纹校验后再执行（**脚本每次变更后此指纹都会改变**，需重新计算：
> `sha256sum envkit.sh`）：
>
> ```bash
> EXP=ebc6805963401b681108fb418c73616f8ccd0ccc050e049fc3c35d00ea657b0f
> GOT=$(wget -qO- https://raw.githubusercontent.com/dongguatanglinux/ros-env-installer/main/envkit.sh | sha256sum | cut -d' ' -f1)
> [ "$GOT" = "$EXP" ] && source <(wget -qO- https://raw.githubusercontent.com/dongguatanglinux/ros-env-installer/main/envkit.sh) || echo "指纹不符，已中止"
> ```

也支持下载后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/dongguatanglinux/ros-env-installer/main/envkit.sh -o envkit.sh
chmod +x envkit.sh
./envkit.sh
```

## 常用参数

| 命令 | 作用 |
|---|---|
| `envkit` | 打开交互菜单 |
| `envkit --doctor` | 只读输出系统诊断报告，不改动任何东西 |
| `envkit --dry-run` | 预演：打印将要执行的操作，但不实际执行、不调用 sudo |
| `envkit --fix-key` | 修复 ROS 密钥与源配置（应对 `apt update` 报 `NO_PUBKEY`） |
| `envkit -m ustc` | 指定镜像偏好（`tsinghua` / `ustc` / `huawei` / `mirrorz` / `packages.ros`） |

## 功能菜单

| 分类 | 工具 |
|---|---|
| ROS / 机器人 | 安装 ROS / ROS2（源 + 密钥指纹校验）、rosdep、环境变量、Gazebo、Cartographer、卸载 ROS |
| 开发环境 | 开发基础工具（git/cmake/gcc/python3 等）、pip 国内镜像、git 用户名邮箱 |
| 系统配置与优化 | **inotify 文件监听上限**（修复 Obsidian/VSCode 的 ENOSPC）、时区与 locale |
| 网络与镜像 | APT 系统源更换（自动备份）、ROS 源配置 / 修复 / 切镜像 |
| 其它 | Docker、系统诊断报告、回滚所有改动 |

每个工具都会先检查是否已满足条件，**已满足则干净跳过**，可安全重复执行。

## 关键设计

### 密钥永不静默失败，且必须验指纹

ROS 源密钥的安装是本脚本重点加固的部分：

- `curl -fsSL --retry 3`——`-f` 让 HTTP 错误立即返回非零，不会把 404 错误页当成密钥内容
- **强制指纹比对**（Open Robotics `F42ED6FBAB17C654`），不匹配即丢弃该源并换下一个
- 拦截 0 字节产物——`gpg --dearmor` 失败时仍会生成空文件，这种情况必须拦下
- 安装到 `/usr/share/keyrings/ros-archive-keyring.gpg` 并在源中用 `signed-by=` 精确授权
- 全部源失败时**立即停止**，并打印可手动执行的修复命令，而不是继续往下走到 `apt update` 才报出无关错误

### apt 作为版本事实来源

不维护硬编码的「发行版 × ROS 版本」表。配置好源并 `apt update` 之后，用
`apt-cache search` 查询实际可用的版本，再据此安装或提示可选版本。

### 按 codename 过滤镜像

不同镜像收录的发行版不同，因此先按 codename 过滤出真正携带该版本的镜像，再测速选择。
ARM 平台上会**重排**而非排除——国内镜像通常不含 ARM deb，故优先官方源，但保留回落可能。

### 只写自己的文件

- 换源前先把 `/etc/apt/sources.list.d/` 整目录备份到带时间戳的目录
- **只删除自己写出的那个文件名**，绝不 `rm -rf` 整个目录（该做法会摧毁 NVIDIA CUDA 等第三方源）
- `~/.bashrc` 用标记块管理，重复执行只替换不追加，并会自动清理历史遗留的重复 `source` 行

### 明确区分发行版与架构

- **ROS1 / ROS2 支持判定**：先看发行版 ID（衍生版用 `ID_LIKE`），再看 codename。
  ROS 1 只对 Ubuntu 本身开放。ROS 2 在 Mint 等衍生版上使用 `UBUNTU_CODENAME`
  （jammy/noble），而不是衍生版自己的代号。
  Ubuntu 22.04+ 装不了 ROS1（ROS1 从未为该版本发布，且已于 2025-05 停止支持），
  此时给出明确原因与替代方案，而不是让用户对着一个注定失败的菜单反复输入
- **32 位 ARM 不做架构伪装**：如实判定并说明后果。32 位系统里不存在 arm64 仓库，
  伪装成 arm64 只会把「必然失败」变成「莫名其妙地失败」

### 其它

- 外部命令统一经 `run()` 执行，`2>&1` 合并输出流——避免 stdout/stderr 分别捕获造成的管道死锁
- 预演模式**绝不调用 sudo**，可在无人值守场景下安全使用
- 无任何遥测与联网上报

## 环境要求

Bash 4+（需要关联数组）。CentOS 7 / RHEL 7 等自带 Bash 4.2 以下版本的系统不在支持范围内。

| 发行族 | 可用功能 |
|---|---|
| Debian / Ubuntu（含 Mint、树莓派 OS、Jetson's L4T） | 全部 16 项 |
| Fedora / RHEL、Arch、openSUSE | 开发工具、inotify、pip、git、时区、诊断；ROS 相关功能会提示改用官方文档或容器 |

## 免责声明

本脚本会修改系统配置（apt 源、bashrc、sysctl 等）。所有写操作都通过 `--dry-run` 可先预览。
工具 15 回滚本脚本写入的配置文件，不卸载软件包。
工具 16 会卸载所选 ROS 发行版的软件包，并删除对应的 `/opt/ros/<发行版>`。
请先理解脚本内容再使用。

## License

MIT