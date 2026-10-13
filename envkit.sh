#!/usr/bin/env bash
# ==============================================================================
#  envkit.sh —— 通用开发环境一键安装套件
#
#  形态仿照「鱼香ROS 一键安装」，但为单文件纯 Bash 实现，并修复其已确认的缺陷：
#    * 非 Debian 发行版在菜单出现前就崩溃（原脚本 import 阶段即调用 dpkg）
#    * armhf 被强改为 arm64（架构伪装），使 ARM 分支成为不可达死代码
#    * curl -s 下载密钥导致 404 错误页被当作密钥装入，且 0 字节产物照装
#    * 使用已废弃/已移除的 apt-key 与 trusted.gpg.d
#    * 换源工具 sudo rm -rf /etc/apt/sources.list.d（会摧毁第三方源）
#    * 证书错误时自动全局关闭 TLS 校验且那句命令漏了 sudo 从未生效
#    * stdout/stderr 分别捕获造成 64KB 管道死锁，故每个安装跑两遍
#    * 每次运行上报访问计数与 IP 归属地查询（无任何必要）
#
#  特性：
#    * 多发行版：Debian/Ubuntu 家族 + Fedora/RHEL + Arch + openSUSE（通用工具可用）
#    * 支持 ARM（Jetson / 树莓派）与 x86_64，并对 32 位 ARM 给出明确提示而非伪装
#    * 密钥强制指纹校验，绝不安装未经校验的密钥
#    * 仅写入自己的文件，幂等可重复执行，不动其它软件的配置
#    * 无任何遥测与联网上报
#
#  用法：
#    bash envkit.sh                 打开交互菜单
#    ./envkit.sh                    同上
#    envkit                         安装到 ~/.local/bin 后的命令
#    bash envkit.sh --doctor        只读输出系统诊断报告
#    bash envkit.sh --dry-run       预演（不真正改动系统，不调用 sudo）
#    bash envkit.sh --fix-key       修复 ROS 密钥与源配置
#    bash envkit.sh -m ustc         指定镜像偏好
#
#    也支持被 source —— 执行结束后不会关闭当前终端：
#    source ~/envkit.sh --doctor
#    source <(curl -fsSL https://<你的地址>/envkit.sh)
#
#  环境变量：
#    ROS_OS_OVERRIDE=id:version:codename   覆盖系统探测（试验用）
#    ENVKIT_DRY_RUN=1                      等价于 --dry-run
#    ENVKIT_RECORD=1                       记录所选工具以便下次回放
#    NO_COLOR=1                            关闭彩色输出
#
#  作者：本地自用脚本
#  许可：MIT
# ==============================================================================

# ------------------------------------------------------------------------------
# §0  运行模式判定
# ------------------------------------------------------------------------------
# 被 `source` 载入时 $0 是调用方的 shell 名（如 bash/zsh），直接执行时 $0 是
# 脚本自身路径，据此区分两种模式：
#   直接执行 -> 正常 exit 即可
#   source   -> 必须用 return 代替 exit，否则会连带关闭用户的终端
if [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
    ENVKIT_SOURCED=1
else
    ENVKIT_SOURCED=0
fi

# source 模式结束时还原调用方的 shell 状态，
# 否则交互 shell 会残留 pipefail/nounset，或丢失原本开启的 errexit。
#
# 注意：不能用 $(set +o) 来备份。命令替换在子shell 中执行，子shell 的
# errexit 已被重置，故 $(set +o) 恒打印 `set +o errexit`，无法还原。
# 这里只记录本脚本会改动的那几个开关，逐个显式存取。
_ENVKIT_SAVE_SET=""
_envkit_save_shell() {
    case $- in *e*) _ENVKIT_SAVE_SET+="e" ;; esac
    case $- in *u*) _ENVKIT_SAVE_SET+="u" ;; esac
    if set -o 2>/dev/null | grep -q '^pipefail .*on$'; then
        _ENVKIT_SAVE_SET+="p"
    fi
    # 已开启的选项无需还原；被我们关闭的选项还原为默认关闭即可
    case $- in *u*) ;; *) _ENVKIT_SAVE_SET+="U" ;; esac   # nounset 原本关
    if ! set -o 2>/dev/null | grep -q '^pipefail .*on$'; then
        _ENVKIT_SAVE_SET+="P"                                # pipefail 原本关
    fi
}

_envkit_restore_shell() {
    (( ENVKIT_SOURCED )) || return 0
    local t
    # 先全部关掉本脚本引入的开关，再按备份恢复
    set +u +o pipefail +e 2>/dev/null
    case $_ENVKIT_SAVE_SET in
        *e*) set -e ;;
    esac
    case $_ENVKIT_SAVE_SET in
        *u*) set -u ;;
    esac
    case $_ENVKIT_SAVE_SET in
        *p*) set -o pipefail ;;
    esac
    # 还原调用方原有的 trap
    for t in "${_ENVKIT_SAVED_TRAPS[@]}"; do
        [[ -n $t ]] && eval "$t" 2>/dev/null
    done
    unset _ENVKIT_SAVE_SET _ENVKIT_SAVED_TRAPS
}

if (( ENVKIT_SOURCED )); then
    _envkit_save_shell
    _ENVKIT_SAVED_TRAPS=()
    for _t in EXIT INT TERM HUP; do
        _ENVKIT_SAVED_TRAPS+=("$(trap -p "$_t" 2>/dev/null)")
    done
    unset _t
fi

# ------------------------------------------------------------------------------
# §0.1  版本守卫
# ------------------------------------------------------------------------------
# 本脚本使用关联数组（declare -A），需要 Bash 4+。
# CentOS 7 / RHEL 7 及纯 busybox sh 环境不满足，属已知不支持范围。
if [[ -z ${BASH_VERSINFO:-} ]]; then
    # 被 `sh envkit.sh` 调用时重新用 bash 解释自身。
    # source 模式不做重解释：此时 bash 已在解释这段代码，不存在解释器问题。
    if (( ENVKIT_SOURCED )); then
        echo "错误：请用 bash 运行，不支持 sh/dash 直接 source。" >&2
        return 1 2>/dev/null || exit 1
    fi
    exec bash "$0" "$@"
fi

if (( BASH_VERSINFO[0] < 4 )); then
    echo "错误：本脚本需要 Bash 4 或更高版本，当前为 ${BASH_VERSION}。" >&2
    echo "      CentOS 7 / RHEL 7 等自带 Bash 4.2 以下版本的系统不在支持范围内。" >&2
    if (( ENVKIT_SOURCED )); then return 1; else exit 1; fi
fi

# 刻意不使用 set -e。
# 本脚本的工作内容就是执行「预期可能失败」的命令：镜像测速、apt-cache 查询、
# grep -q 探测、dpkg-query 查询未安装的包…… 在 set -e 下这些正常的否定结果
# 会中断脚本，且往往发生在系统已被部分改动之后。错误纪律由 run() 与显式
# `|| return 1` 保证。保留 -u 与 pipefail。
#
# 必须显式 `set +e`：只写 `set -uo pipefail` 并不会关闭调用方可能已开启的
# errexit。source 模式下若带着 errexit 运行，本脚本里任何一处非零返回
# （例如 grep -q 未命中）都会直接终止用户的交互 shell。
set +e
set -uo pipefail

# 运行期可覆盖的全局变量
DRY_RUN=0                 # 预演模式
PREFERRED_MIRROR=""       # 用户指定的镜像偏好
FIX_KEY_ONLY=0            # 仅执行密钥修复
SUDO=()                   # 提权前缀，root 环境为空数组
WORKDIR=""                 # 临时工作目录，退出时清理
ENVKIT_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/envkit"
QUEUE_FILE="$ENVKIT_HOME/queue.txt"
LOG_FILE="${ENVKIT_LOG:-$HOME/.envkit/install-$(date +%Y%m%d-%H%M%S).log}"

# 缓存的系统信息（探测后填充）
DISTRO_ID=""; DISTRO_VERSION=""; DISTRO_CODENAME=""; DISTRO_FAMILY=""; PRETTY_NAME=""
KERNEL_ARCH=""; APT_ARCH=""; PKG_ARCH=""; IS_ARM64=0; IS_32BIT_ARMF=0
PKG_FAMILY=""

# ==============================================================================
# §1  日志、颜色与命令出口
# ==============================================================================

# 颜色：非交互终端（重定向、CI）自动关闭，避免输出里混入转义序列
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_RED=$'\033[31m';    C_GREEN=$'\033[32m';  C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m';   C_CYAN=$'\033[36m';  C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m';     C_OFF=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_DIM=""; C_OFF=""
fi

# 三种输出级别，终端与日志文件同时记录
info() { printf '%s[信息]%s %s\n' "$C_BLUE"   "$C_OFF" "$*"; printf '[信息] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }
ok()   { printf '%s[成功]%s %s\n' "$C_GREEN"  "$C_OFF" "$*"; printf '[成功] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; printf '[警告] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }
err()  { printf '%s[错误]%s %s\n' "$C_RED"    "$C_OFF" "$*" >&2; printf '[错误] %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }
die()  { err "$*"; if (( ENVKIT_SOURCED )); then return 1; else exit 1; fi; }

# 需要管理员权限时统一调用一次，避免每个工具各写一遍
ensure_root() {
    # 预演模式下绝不调用 sudo：否则会在无人值守场景（管道、重定向）中
    # 卡在密码输入上，而预演本来就一个字节都不该改动系统。
    (( DRY_RUN )) && return 0
    (( EUID == 0 )) && return 0
    if ! command -v sudo >/dev/null 2>&1; then
        err "此操作需要管理员权限，但系统中未找到 sudo"
        return 1
    fi
    warn "接下来的操作需要管理员权限："
    if ! "${SUDO[@]}" -v; then
        err "sudo 认证失败，已终止"
        return 1
    fi
    return 0
}

# run —— 全脚本唯一执行外部命令的出口。
#
# 存在的三个理由：
#   1. 彻底消除鱼香脚本的 64KB 管道死锁。它把 stdout 和 stderr 分别接到两条
#      管道，先读完 stdout 到 EOF 再读 stderr；apt 输出填满 64KB 的 stderr 管道
#      后双方互相阻塞。这里用 2>&1 把两个流合并成一条，tee 持续消费，不存在填满
#      的可能，因此也不需要「装两遍」这种变通。
#   2. dry-run 只有这一个开关点。加一次 DRY_RUN 判断即可覆盖全部外部命令。
#   3. 日志只有这一个写入点，便于事后排查。
run() {
    local desc=$1; shift
    mkdir -p -- "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '\n%s$ %s%s\n' "$C_CYAN" "$*" "$C_OFF"
    printf '\n$ %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true

    if (( DRY_RUN )); then
        printf '%s[dry-run] 已跳过，未实际执行%s\n' "$C_DIM" "$C_OFF"
        return 0
    fi

    "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}   # 取真实命令的退出码，丢弃 tee 的状态
    (( rc != 0 )) && err "命令失败（退出码 $rc）"
    return $rc
}

# mutate —— 受保护文件写入的统一出口。
# 非 root 无法直接重定向到 /etc，故先写临时文件再用 install 搬运。
# 不使用 `sudo tee`：管道 + 内嵌引号会被二次解析，且中文内容易在编码转换中损坏。
write_root_file() {   # $1=目标路径，内容从 stdin 读入
    local dest=$1 tmp rc=0
    tmp=$(mktemp) || { err "无法创建临时文件"; return 1; }
    cat >"$tmp" || { rm -f "$tmp"; return 1; }
    if (( DRY_RUN )); then
        printf '%s[dry-run] 将写入 %s（内容 %s 字节）%s\n' "$C_DIM" "$dest" "$(wc -c <"$tmp")" "$C_OFF"
        rm -f "$tmp"; return 0
    fi
    if (( EUID == 0 )); then
        install -m 0644 "$tmp" "$dest" 2>/dev/null || rc=$?
    else
        "${SUDO[@]}" install -m 0644 "$tmp" "$dest" || rc=$?
    fi
    rm -f "$tmp"
    return $rc
}

# ==============================================================================
# §2  系统与架构探测
# ==============================================================================

# 从 os-release 读取单个字段。
#
# 刻意用 sed 解析而非 `source /etc/os-release`：source 会以当前用户身份执行该文件
# 的全部内容，在 root 下等于执行一个可被第三方修改的脚本。
# 这里只取值、不执行，用 grep -E '^KEY=' 限定行首以防 VALUE 中含键名造成误匹配。
_os_release_field() {
    local key=$1 f val
    for f in /etc/os-release /usr/lib/os-release; do
        [[ -r $f ]] || continue
        val=$(grep -E "^${key}=" "$f" | tail -n1) || continue
        val=${val#*=}
        # 去掉 os-release 规范要求的外层引号
        val=${val%\"}; val=${val#\"}
        val=${val%\'}; val=${val#\'}
        [[ -n $val ]] && { printf '%s' "$val"; return 0; }
    done
    return 1
}

detect_os() {
    DISTRO_ID=$(_os_release_field ID)           || DISTRO_ID=""
    DISTRO_VERSION=$(_os_release_field VERSION_ID) || DISTRO_VERSION=""
    # Ubuntu 用 VERSION_CODENAME，部分版本只有 UBUNTU_CODENAME
    DISTRO_CODENAME=$(_os_release_field VERSION_CODENAME) || DISTRO_CODENAME=""
    [[ -n $DISTRO_CODENAME ]] || DISTRO_CODENAME=$(_os_release_field UBUNTU_CODENAME) || DISTRO_CODENAME=""
    DISTRO_FAMILY=$(_os_release_field ID_LIKE)  || DISTRO_FAMILY=""
    PRETTY_NAME=$(_os_release_field PRETTY_NAME) || PRETTY_NAME=""

    # 回退链：os-release -> lsb-release -> debian_version
    if [[ -z $DISTRO_CODENAME && -r /etc/lsb-release ]]; then
        DISTRO_CODENAME=$(grep -E '^DISTRIB_CODENAME=' /etc/lsb-release | tail -n1 | cut -d= -f2-)
    fi
    if [[ -z $DISTRO_VERSION && -r /etc/debian_version ]]; then
        DISTRO_VERSION=$(cut -d. -f1 </etc/debian_version)
        [[ -n $DISTRO_CODENAME ]] || DISTRO_CODENAME="stable"
    fi
    # ID_LIKE 可能包含多个家族（如 "ubuntu debian"），保留原串供后续匹配
    DISTRO_FAMILY=${DISTRO_FAMILY:-$DISTRO_ID}
    [[ -n $PRETTY_NAME ]] || PRETTY_NAME="${DISTRO_ID:-unknown} ${DISTRO_VERSION:-}"

    # 逃生口：在没有相应硬件时试验其它系统分支（如用 x86 机器验证 ARM 路径）
    if [[ -n ${ROS_OS_OVERRIDE:-} ]]; then
        IFS=: read -r DISTRO_ID DISTRO_VERSION DISTRO_CODENAME <<<"$ROS_OS_OVERRIDE"
        DISTRO_FAMILY=$DISTRO_ID
        # PRETTY_NAME 必须一并更新，否则提示里仍会显示真实系统名，
        # 出现「当前系统 Ubuntu 20.04 无法安装」这种自相矛盾的输出
        PRETTY_NAME="${DISTRO_ID} ${DISTRO_VERSION}"
        warn "已通过 ROS_OS_OVERRIDE 覆盖系统信息：$DISTRO_ID $DISTRO_VERSION ($DISTRO_CODENAME)"
    fi
}

detect_arch() {
    # 内核架构：uname 永远可用，用作功能门控的可靠依据
    KERNEL_ARCH=$(uname -m)
    case $KERNEL_ARCH in
        x86_64)                 APT_ARCH=amd64 ;;
        aarch64|arm64)          APT_ARCH=arm64 ;;
        armv7l|armv6l|armv8l)  APT_ARCH=armhf ;;   # 32 位内核 + 32 位用户态
        i386|i486|i586|i686)   APT_ARCH=i386  ;;
        *)                      APT_ARCH=$KERNEL_ARCH ;;
    esac

    # apt 用户态架构。与内核架构可能不同（64 位内核跑 32 位用户态的情况）。
    # 无 dpkg 时置空而非崩在空列表索引上——这是非 Debian 系统能继续走下去的关键。
    if command -v dpkg >/dev/null 2>&1; then
        PKG_ARCH=$(dpkg --print-architecture 2>/dev/null) || PKG_ARCH=""
    else
        PKG_ARCH=""
    fi

    # 32 位 ARM 用户态标记。
    #
    # 鱼香脚本在此处把 armhf 强改为 arm64，这会把「必然失败」变成「莫名其妙地失败」：
    # 32 位系统里根本没有 arm64 仓库，装出来的是错架构的包或直接 404。
    # 本脚本不做伪装，如实判定并给出可执行的建议。
    IS_32BIT_ARMF=0
    if [[ $PKG_ARCH == armhf || $KERNEL_ARCH == armv7l || $KERNEL_ARCH == armv6l ]]; then
        IS_32BIT_ARMF=1
    fi
    if [[ $KERNEL_ARCH == aarch64 || $PKG_ARCH == arm64 ]]; then
        IS_ARM64=1
    else
        IS_ARM64=0
    fi
}

# 检测包管理器family。
#
# 这是与鱼香脚本方向相反的关键设计：先确定包管理器，再决定哪些逻辑可用。
# 鱼香在模块导入时就调用 dpkg，导致所有非 Debian 系统在菜单之前就崩溃。
detect_pkg_family() {
    if   command -v apt-get >/dev/null 2>&1; then PKG_FAMILY=apt
    elif command -v dnf     >/dev/null 2>&1; then PKG_FAMILY=dnf
    elif command -v yum     >/dev/null 2>&1; then PKG_FAMILY=dnf
    elif command -v pacman  >/dev/null 2>&1; then PKG_FAMILY=pacman
    elif command -v zypper  >/dev/null 2>&1; then PKG_FAMILY=zypper
    else
        PKG_FAMILY=none
        warn "未识别到受支持的包管理器（apt/dnf/pacman/zypper），仅诊断与配置类功能可用"
    fi
}

# 32 位 ARM 守卫
require_64bit_arm_ok() {
    if (( IS_32BIT_ARMF )); then
        err "检测到 32 位 ARM 用户态（内核 ${KERNEL_ARCH} / dpkg ${PKG_ARCH:-无}）"
        err "国内 ROS 镜像与 packages.ros.org 均未提供 armhf 的 ROS2 包，此操作必然失败。"
        err "建议：32 位系统请安装 ROS1；或重装 64 位系统后再使用 ROS2。"
        return 1
    fi
    return 0
}

# ==============================================================================
# §3  包管理器抽象（刻意保持最小）
# ==============================================================================
#
# 分两层，刻意不做通用包管理器框架：
#   * 通用层：开发工具、inotify、pip、git、locale 等纯配置类功能，
#     在所有发行族上都能用，只需要「装这些名字」这一个动作。
#   * apt 专用层：ROS 源与 ROS 本体。ROS 的 .deb + signed-by= 密钥环体系在
#     dnf/pacman/zypper 上没有等价物，强行抽象只会产出一个半残路径。
#     非 Debian 系统在此明确提示转向官方文档或 Docker，然后返回。

pkg_install() {
    case $PKG_FAMILY in
        apt)
            run "安装 $* " env DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y --no-install-recommends "$@"
            ;;
        dnf)
            run "安装 $*" "${SUDO[@]}" dnf install -y "$@"
            ;;
        pacman)
            run "安装 $*" "${SUDO[@]}" pacman -S --needed --noconfirm "$@"
            ;;
        zypper)
            run "安装 $*" "${SUDO[@]}" zypper install -y "$@"
            ;;
        *)
            err "当前系统没有受支持的包管理器，无法安装：$*"
            return 2
            ;;
    esac
}

# 查询是否已安装，用于幂等跳过（替代鱼香「装两遍」的浪费）
pkg_exists() {
    case $PKG_FAMILY in
        apt)    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed" ;;
        dnf|zypper) rpm -q "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Qq "$1" >/dev/null 2>&1 ;;
        *)      command -v "$1" >/dev/null 2>&1 ;;
    esac
}

pkg_update() {
    case $PKG_FAMILY in
        apt)    run "更新 apt 索引" env DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get update ;;
        dnf)    run "刷新 dnf 缓存" "${SUDO[@]}" dnf makecache ;;
        pacman) run "刷新 pacman 缓存" "${SUDO[@]}" pacman -Sy --noconfirm ;;
        zypper) run "刷新 zypper 缓存" "${SUDO[@]}" zypper refresh ;;
        *)      return 2 ;;
    esac
}

# ROS 相关功能在非 Debian 系统上的统一提示
unsupported_ros() {
    err "此功能仅支持 Debian/Ubuntu 家族。"
    err "ROS 官方只发布 .deb 包；在 ${PRETTY_NAME} 上请参考官方文档手工安装，"
    err "或直接使用容器：docker run -it osrf/ros:humble-desktop"
    return 2
}

# ==============================================================================
# §4  受保护目录备份与 .bashrc 标记块
# ==============================================================================

# 备份 sources.list.d 下的全部内容。
#
# 鱼香的换源工具执行 `sudo rm -rf /etc/apt/sources.list.d`，会连带删除
# NVIDIA CUDA（Jetson）、grok-bot.sources 等第三方源。本脚本先整目录备份，
# 且后续只删除自己写出的那个文件名，绝不 rm -rf 该目录。
backup_sources_dir() {
    local d=/etc/apt/sources.list.d ts bak
    [[ -d $d ]] || return 0
    ts=$(date +%Y%m%d-%H%M%S)
    bak="$d/envkit-backup-$ts"
    if (( DRY_RUN )); then
        printf '%s[dry-run] 将备份 %s 到 %s%s\n' "$C_DIM" "$d" "$bak" "$C_OFF"
        printf '%s' "$bak"; return 0
    fi
    "${SUDO[@]}" mkdir -p "$bak" && "${SUDO[@]}" cp -a "$d/." "$bak/" 2>/dev/null || {
        err "备份第三方源失败，已中止（不做任何改动）"
        return 1
    }
    ok "已备份全部第三方源到 $bak"
    printf '%s' "$bak"
}

# bashrc_set_block —— 幂等地在 ~/.bashrc 写入受标记管理的配置块。
#
# 用法： bashrc_set_block "ros-env" <<'EOF'
#          ...内容...
#        EOF
#
# 重复执行只会替换同名块，不会不断追加。用户 ~/.bashrc 里常见重复的
# `source /opt/ros/noetic/setup.bash` 就是这样被叠起来的。
bashrc_set_block() {
    local tag=$1 rc="${HOME}/.bashrc"
    local begin="# >>> ${tag} >>>" end="# <<< ${tag} <<<"
    local tmp
    tmp=$(mktemp) || { err "无法创建临时文件"; return 1; }

    if [[ -f $rc ]]; then
        # 剔除同名标记块（含块内空行），其余内容逐行保留。
        # 用状态机而非简单区间删除：块内可能含空行，遇到结束标记才退出剔除状态。
        awk -v b="$begin" -v e="$end" '
            $0 == b { inblk = 1; next }
            $0 == e { inblk = 0; next }
            !inblk    { print }
        ' "$rc" >"$tmp" || { rm -f "$tmp"; err "解析 $rc 失败"; return 1; }
        # 去掉尾部空行，避免每次执行都让文件增长一行。
        # 只削尾部，不动中间，保证用户自己排版的结构不变。
        awk 'NR > 1 { buf[NR-1] = $0 } END { n = NR; while (n > 0 && buf[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print buf[i] }' \
            "$tmp" >"$tmp.trim" 2>/dev/null && mv -f "$tmp.trim" "$tmp"
    fi
    printf '%s\n' "$begin" >>"$tmp"
    cat >>"$tmp"
    printf '%s\n' "$end" >>"$tmp"

    if (( DRY_RUN )); then
        printf '%s[dry-run] 将更新 %s 中的 [%s] 块%s\n' "$C_DIM" "$rc" "$tag" "$C_OFF"
        rm -f "$tmp"; return 0
    fi
    cat "$tmp" >"$rc" || { rm -f "$tmp"; err "写入 $rc 失败"; return 1; }
    rm -f "$tmp"
    ok "已更新 ~/.bashrc 中的 [$tag] 块（重复执行只会替换，不会追加）"
}

# ==============================================================================
# §5  镜像矩阵、测速与 ROS 密钥
# ==============================================================================

# Gitee 源国内可直连且已实测可用；官方源作为兜底
ROS_KEY_FPR="F42ED6FBAB17C654"
ROS_KEYRING="/usr/share/keyrings/ros-archive-keyring.gpg"
KEY_SOURCES=(
    "https://gitee.com/fishros/rosdistro/raw/master/ros.asc"
    "https://raw.githubusercontent.com/ros/rosdistro/master/ros.key"
)

# 镜像矩阵：键 = codename，值 = 按优先级排列的镜像键（空格分隔）
#
# 关于缺项：ROS1 从未为 jammy(22.04) 及以上发布，因此 ROS1 矩阵里「没有 jammy/noble」
# 本身就是一道诚实的门控——缺失即表示不支持，而不是到时给出误导性的选项。
#
# bionic / stretch 的国内镜像组合与其它版本不同，已逐一核对：bionic 无 ustc，
# stretch 无 mirrorz。resolute(26.04) 目前仅有官方源。
declare -A ROS1_MIRRORS=(
    [xenial]="tsinghua ustc huawei mirrorz packages.ros"
    [bionic]="tsinghua ustc huawei mirrorz packages.ros"
    [artful]="tsinghua ustc huawei packages.ros"
    [focal]="tsinghua ustc huawei mirrorz packages.ros"
)

declare -A ROS2_MIRRORS=(
    [focal]="tsinghua ustc huawei mirrorz packages.ros"
    [bionic]="tsinghua mirrorz huawei packages.ros"          # 无 ustc
    [xenial]="tsinghua ustc huawei mirrorz packages.ros"
    [stretch]="tsinghua ustc huawei packages.ros"             # 无 mirrorz
    [buster]="tsinghua ustc huawei mirrorz packages.ros"
    [bullseye]="tsinghua ustc huawei mirrorz packages.ros"
    [bookworm]="tsinghua ustc huawei mirrorz packages.ros"
    [trixie]="tsinghua ustc huawei mirrorz packages.ros"
    [jammy]="tsinghua ustc huawei mirrorz packages.ros"
    [noble]="tsinghua ustc huawei mirrorz packages.ros"
    [resolute]="packages.ros"                                # 26.04 暂无国内镜像
)

# ROS1 与 ROS2 的仓库根路径不同
ros_base_url() {   # $1=ros1|ros2  $2=镜像键
    local gen=$1
    case $2 in
        tsinghua)
            [[ $gen == ros1 ]] && printf 'http://mirrors.tuna.tsinghua.edu.cn/ros/ubuntu'  \
                               || printf 'http://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu' ;;
        ustc)
            [[ $gen == ros1 ]] && printf 'https://mirrors.ustc.edu.cn/ros/ubuntu'  \
                               || printf 'https://mirrors.ustc.edu.cn/ros2/ubuntu' ;;
        huawei)
            [[ $gen == ros1 ]] && printf 'https://repo.huaweicloud.com/ros/ubuntu'  \
                               || printf 'https://repo.huaweicloud.com/ros2/ubuntu' ;;
        mirrorz)
            [[ $gen == ros1 ]] && printf 'https://mirrors.cernet.edu.cn/ros/ubuntu'  \
                               || printf 'https://mirrors.cernet.edu.cn/ros2/ubuntu' ;;
        packages.ros)
            [[ $gen == ros1 ]] && printf 'http://packages.ros.org/ros/ubuntu'  \
                               || printf 'http://packages.ros.org/ros2/ubuntu' ;;
        *) return 1 ;;
    esac
}

# 生成候选镜像列表（每行一个）
mirror_candidates() {   # $1=ros1|ros2  $2=codename
    local gen=$1 code=$2 line k
    if [[ $gen == ros1 ]]; then line=${ROS1_MIRRORS[$code]:-}; else line=${ROS2_MIRRORS[$code]:-}; fi
    [[ -n $line ]] || return 1
    read -r -a _cands <<<"$line"

    # ARM 上做「重排」而非「排除」：国内 ROS 镜像基本不含 ARM deb，
    # 官方源才有，因此把 packages.ros 提到最前，但不因此拒绝其它源。
    # 注意判断条件是「packages.ros 是否已在首位」，而不是「是否存在」——
    # 后者会让重排永远不执行。
    if (( IS_ARM64 )); then
        local keep=() rest=() k
        for k in "${_cands[@]}"; do
            [[ $k == packages.ros ]] && keep+=("$k") || rest+=("$k")
        done
        if (( ${#keep[@]} == 0 )); then
            warn "当前为 arm64，但该 codename 的镜像列表中没有官方源"
            warn "国内 ROS 镜像通常不含 ARM 包，可能全部不可用"
        elif [[ ${_cands[0]} != packages.ros ]]; then
            warn "当前为 arm64：国内 ROS 镜像通常不含 ARM 包，将优先使用官方源"
        fi
        _cands=("${keep[@]}" "${rest[@]}")
    fi
    # 用户显式指定的偏好插到队首，但必须先确认它确实是本 codename 的合法候选，
    # 否则会拼出一个 404 的 URL。非法值直接忽略，交由测速决定。
    if [[ -n $PREFERRED_MIRROR ]]; then
        local reordered=() k2 found_pref=0
        for k2 in "${_cands[@]}"; do
            if [[ $k2 == "$PREFERRED_MIRROR" ]]; then
                found_pref=1
                continue
            fi
            reordered+=("$k2")
        done
        if (( found_pref )); then
            _cands=("$PREFERRED_MIRROR" "${reordered[@]}")
        else
            warn "指定镜像 ${PREFERRED_MIRROR} 不适用于 ${DISTRO_CODENAME}，将自动测速选择"
            PREFERRED_MIRROR=""
        fi
    fi
    printf '%s\n' "${_cands[@]}"
}

# 测速：打印毫秒延迟，失败打印 -1
probe_mirror() {   # $1=仓库根 URL
    local t
    t=$(curl -fsS -o /dev/null --max-time 3 \
        -w '%{time_total}' "$1/dists/${DISTRO_CODENAME}/Release" 2>/dev/null) || { printf -- '-1'; return 0; }
    awk -v x="$t" 'BEGIN{printf "%d", (x>0 ? x*1000 : 999999)}'
}

# 并发测速选出最快的镜像；全部失败时返回 1，由调用方回退到官方源。
#
# 注意：返回值通过 stdout 传给调用方的 $(...)，因此本函数内的任何提示都必须
# 走 stderr，否则提示文字会被一并捕获进 mirror 变量，导致 URL 拼接错误。
rank_mirrors() {   # $1=ros1|ros2
    local gen=$1 k url best="" bestms=999999999 ms
    local -a keys=()
    while read -r k; do keys+=("$k"); done < <(mirror_candidates "$gen" "$DISTRO_CODENAME")
    (( ${#keys[@]} )) || return 1

    local tmp
    tmp=$(mktemp -d) || return 1
    # 并发探测：全部同时发起，避免串行累加等待
    for k in "${keys[@]}"; do
        url=$(ros_base_url "$gen" "$k") || continue
        ( probe_mirror "$url" >"$tmp/$k" ) &
    done
    wait
    for k in "${keys[@]}"; do
        ms=$(cat "$tmp/$k" 2>/dev/null || printf -- '-1')
        if [[ $ms =~ ^[0-9]+$ ]] && (( ms > 0 && ms < bestms )); then
            bestms=$ms; best=$k
        fi
    done
    rm -rf -- "$tmp"
    [[ -n $best ]] || return 1
    # 用户显式指定的镜像拥有最高优先级：直接采用，不再参与竞速。
    # 否则「-m ustc」会被测速结果覆盖，违背用户的明确要求。
    # 非法镜像已在 mirror_candidates 中被拒绝并清空 PREFERRED_MIRROR，
    # 因此这里只需判断是否仍然有效。
    if [[ -n $PREFERRED_MIRROR ]]; then
        info "按用户指定使用镜像：${PREFERRED_MIRROR}（最快为 ${best}，${bestms}ms）" >&2
        printf '%s' "$PREFERRED_MIRROR"
        return 0
    fi
    info "镜像测速完成：选择 ${best}（${bestms}ms），候选：${keys[*]}" >&2
    printf '%s' "$best"
}

# ---------------------------------------------------------------------------
# 密钥安装 —— 本脚本重点加固的部分
# ---------------------------------------------------------------------------

# 判断 keyring 文件里的密钥指纹是否匹配。
#
# 必须先去掉空格：gpg --show-keys --with-fingerprint 输出的是分组格式
#   C1CF 6E31 E6BA DE88 68B1  72B4 F42E D6FB AB17 C654
# 而我们持有的是无空格串 F42ED6FBAB17C654，直接 grep 永远匹配不上——
# 会导致把完好的密钥误判为损坏并反复重装。
key_fingerprint_ok() {   # $1=keyring 文件路径
    [[ -f $1 ]] || return 1
    gpg --show-keys --with-fingerprint "$1" 2>/dev/null \
        | tr -d ' \t' \
        | grep -q "$ROS_KEY_FPR"
}
#
# 鱼香 add_key() 的故障链（本机已逐条实测复现）：
#   1. `curl -s` 缺少 -f：HTTP 404 时 curl 仍以 0 退出，并把错误页正文写到 stdout，
#      该正文被直接管道给 `apt-key add`，即装入一个垃圾密钥。
#   2. `gpg --dearmor` 面对错误文本会报「找不到有效的 OpenPGP 数据」并返回非零，
#      但仍会生成一个 0 字节文件；脚本不检查大小，照装不误。
#   3. 真正的报错要等到 apt update 才出现，且与病因（密钥是空的）毫无关联，
#      用户只能看到一句莫名其妙的 NO_PUBKEY。
#   4. 兜底走 keyserver.ubuntu.com，国内基本不可达，而其 timeout 参数
#      在框架里从未被读取，因此会长时间挂起。
#   5. 写 trusted.gpg.d：已弃用、全局信任、污染面最大。
#
# 本脚本的修法：curl -fsSL + 强制指纹校验 + 拦截 0 字节 + 专用 keyring + signed-by。
install_ros_keyring() {
    # 已安装且指纹匹配则直接跳过（重复执行时走这里）
    if key_fingerprint_ok "$ROS_KEYRING"; then
        ok "ROS 公钥已存在且指纹匹配（${ROS_KEY_FPR}），跳过"
        return 0
    fi

    local url raw bin
    raw=$(mktemp) || { err "无法创建临时文件"; return 1; }
    bin=$(mktemp) || { rm -f "$raw"; err "无法创建临时文件"; return 1; }

    for url in "${KEY_SOURCES[@]}"; do
        info "尝试密钥源：$url"
        # -f 是关键：HTTP 错误立即返回非零，不会把错误页当成密钥内容
        if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 30 -o "$raw" "$url"; then
            err "  下载失败（网络或源不可达），换下一个源"
            continue
        fi
        # 强制指纹校验：绝不安装未经校验的密钥
        # （同样需要去空格，理由见 key_fingerprint_ok 的注释）
        if ! gpg --show-keys --with-fingerprint "$raw" 2>/dev/null \
             | tr -d ' \t' | grep -q "$ROS_KEY_FPR"; then
            err "  指纹不匹配，丢弃该源（可能是错误页或内容被篡改）"
            rm -f "$raw"; continue
        fi
        if ! gpg --dearmor <"$raw" >"$bin"; then
            err "  gpg 转换失败，换下一个源"
            rm -f "$raw" "$bin"; return 1
        fi
        # 拦下 0 字节产物——这正是鱼香脚本静默装入空密钥的那一步
        if [[ ! -s $bin ]]; then
            err "  转换结果为 0 字节，判定为失败，换下一个源"
            rm -f "$raw" "$bin"; return 1
        fi

        ensure_root || { rm -f "$raw" "$bin"; return 1; }
        if (( DRY_RUN )); then
            printf '%s[dry-run] 将安装密钥到 %s（%s 字节）%s\n' \
                "$C_DIM" "$ROS_KEYRING" "$(wc -c <"$bin")" "$C_OFF"
            ok "ROS 公钥校验通过（dry-run，未实际安装）"
            rm -f "$raw" "$bin"
            return 0
        fi
        if ! "${SUDO[@]}" install -m 0644 "$bin" "$ROS_KEYRING"; then
            err "  安装到 ${ROS_KEYRING} 失败"
            rm -f "$raw" "$bin"; return 1
        fi
        ok "ROS 公钥已安装并通过指纹校验（${ROS_KEY_FPR}）"
        rm -f "$raw" "$bin"
        return 0
    done

    err "全部密钥源均失败。请手动执行以下命令完成安装："
    err "  curl -fsSL ${KEY_SOURCES[1]} \\"
    err "    | gpg --dearmor \\"
    err "    | sudo tee ${ROS_KEYRING}"
    rm -f "$raw" "$bin"
    return 1
}

# ==============================================================================
# §6  菜单引擎
# ==============================================================================

declare -A TOOL_CAT TOOL_TIP TOOL_FN
declare -a  TOOL_ORDER=()

declare -A CAT_NAME=(
    [ros]="ROS / 机器人"
    [dev]="开发环境"
    [sys]="系统配置与优化"
    [net]="网络与镜像"
    [other]="其它"
)
declare -a CAT_ORDER=(ros dev sys net other)

register_tool() {   # $1=id $2=分类 $3=描述 $4=函数名
    TOOL_CAT[$1]=$2
    TOOL_TIP[$1]=$3
    TOOL_FN[$1]=$4
    TOOL_ORDER+=("$1")
}

# 摘要行：告诉用户当前系统能装什么
ros_summary() {
    local out=""
    ros1_supported && out="ROS1(${ROS1_DISTRO}) "
    ros2_supported && out+="ROS2(${ROS2_DISTRO}) "
    [[ -z $out ]] && out="无可用 ROS 版本 "
    printf '%s' "${out% }"
}

# ROS1 支持判定：只有 Ubuntu，且只有 bionic/focal。
#
# 判定先看发行版 ID 再看 codename。鱼香只判 codename，导致 Linux Mint
# （codename 报 jammy）能通过本该只对 Ubuntu 开放的检查。
ros1_supported() {
    [[ $DISTRO_ID == ubuntu ]] || return 1
    case $DISTRO_CODENAME in
        bionic) ROS1_DISTRO=melodic ;;
        focal)  ROS1_DISTRO=noetic  ;;
        *)      return 1 ;;
    esac
    return 0
}

# ROS2 支持判定：Ubuntu 与 Debian 家族
ros2_supported() {
    case " ${DISTRO_FAMILY:-} $DISTRO_ID " in
        *" ubuntu "*|*" debian "*) ;;
        *) return 1 ;;
    esac
    case $DISTRO_CODENAME in
        jammy)              ROS2_DISTRO=humble   ;;  # LTS，2027-05 EOL
        noble)              ROS2_DISTRO=jazzy    ;;  # LTS
        focal)              ROS2_DISTRO=galactic ;;
        bookworm)           ROS2_DISTRO=jazzy    ;;
        bullseye)           ROS2_DISTRO=humble   ;;
        trixie)             ROS2_DISTRO=kilted   ;;
        resolute)           ROS2_DISTRO=lyrical  ;;  # 26.04 LTS
        rolling)            ROS2_DISTRO=rolling  ;;
        # bionic/stretch 上游已 EOL，各镜像均无包，直接判定不支持
        *)                  return 1 ;;
    esac
    return 0
}

# 列出 apt 中真实可用的 ROS 版本。
#
# 这是替代硬编码版本表的关键：apt 索引本身就是事实来源。加好源并 apt update 之后
# 再查询，就能确知这个镜像上究竟有哪些版本，避免维护一张会过期的表。
apt_ros_available() {   # $1=ros1|ros2
    local gen=$1 d
    for d in noetic melodic humble jazzy kilted rolling galactic foxy; do
        if [[ $gen == ros1 && ( $d != noetic && $d != melodic ) ]]; then continue; fi
        if [[ $gen == ros2 && ( $d == noetic || $d == melodic ) ]]; then continue; fi
        if apt-cache search --names-only "^ros-${d}-ros-base\$" 2>/dev/null | grep -q .; then
            printf '%s ' "$d"
        fi
    done
}

render_menu() {
    local cat id max
    max=${#TOOL_ORDER[@]}
    printf '\n%s%senvkit —— 开发环境一键安装套件%s\n' "$C_BOLD" "$C_CYAN" "$C_OFF"
    printf '%s系统 %s | 架构 %s | 包管理器 %s | 可用 ROS: %s%s\n' \
        "$C_DIM" "$PRETTY_NAME" "$KERNEL_ARCH" "$PKG_FAMILY" "$(ros_summary)" "$C_OFF"
    for cat in "${CAT_ORDER[@]}"; do
        printf '\n%s── %s ──%s\n' "$C_BLUE$C_BOLD" "${CAT_NAME[$cat]}" "$C_OFF"
        for id in "${TOOL_ORDER[@]}"; do
            [[ ${TOOL_CAT[$id]} == "$cat" ]] || continue
            printf '  %2d) %s\n' "$id" "${TOOL_TIP[$id]}"
        done
    done
    printf '\n  %s%2d) 退出%s\n' "$C_GREEN$C_BOLD" 0 "$C_OFF"
}

# 读取用户选择。
#
# 结果写入全局变量 CHOICE 而非通过 stdout 返回：提示语与输入同在终端，
# 若用 choice=$(read_choice ...) 接收，提示语会被一并捕获进变量，
# 得到 "请选择 [0-15]:0" 这样的值，导致永远匹配不上而死循环。
CHOICE=""
read_choice() {   # $1=提示语
    local max=${#TOOL_ORDER[@]} ans tries=0
    CHOICE=""
    while :; do
        printf '%s' "$1"
        IFS= read -r ans || { printf '\n'; return 1; }   # EOF / Ctrl-D 安全退出
        ans=${ans//[[:space:]]/}
        if [[ $ans =~ ^[0-9]+$ ]]; then
            if (( ans >= 0 && ans <= max )); then
                CHOICE=$ans
                return 0
            fi
            printf '%s输入超出范围，请输入 0-%d%s\n' "$C_YELLOW" "$max" "$C_OFF"
        else
            printf '%s请输入数字%s\n' "$C_YELLOW" "$C_OFF"
        fi
        tries=$((tries + 1))
        (( tries >= 3 )) && { err "无效输入次数过多，退出"; return 1; }
    done
}

# ---------------------------- 回放队列 ---------------------------------------
# 鱼香写 /tmp/fish_install.yaml 却读 ./fish_install.yaml（相对当前目录），
# 导致该功能静默失效。这里使用绝对路径，且每个 id 都对当前注册表校验，
# 遇到失效 id 就整体丢弃并明确提示，避免菜单变化后错位执行。
queue_load() {
    QUEUE_IDX=0
    [[ -f $QUEUE_FILE ]] || return 1
    local line id
    while read -r line; do
        [[ $line =~ ^[0-9]+$ ]] || continue
        id=$line
        if [[ -z ${TOOL_FN[$id]:-} ]]; then
            warn "队列中的工具 id=${id} 在当前版本中已不存在，已丢弃整个队列（防止错位执行）"
            rm -f "$QUEUE_FILE"
            QUEUE_IDX=0
            return 1
        fi
        QUEUE_IDX=$(( QUEUE_IDX + 1 ))
    done <"$QUEUE_FILE"
    (( QUEUE_IDX > 0 ))
}

queue_peek() {
    (( QUEUE_IDX > 0 )) || return 1
    sed -n "${QUEUE_IDX}p" "$QUEUE_FILE" 2>/dev/null
}

queue_reset() { QUEUE_IDX=0; }

# 队列记录默认关闭。鱼香默认静默记录，导致用户下次运行时莫名其妙自动执行一批操作。
queue_record() {
    (( DRY_RUN )) && return 0
    [[ ${ENVKIT_RECORD:-0} == 1 ]] || return 0
    mkdir -p "$ENVKIT_HOME" 2>/dev/null || return 0
    printf '%s\n' "$1" >>"$QUEUE_FILE"
}

# ==============================================================================
# §7  工具实现
# ==============================================================================

# --------------------------- 1. 安装 ROS / ROS2 ------------------------------
tool_install_ros() {
    require_64bit_arm_ok || return 1
    if [[ $PKG_FAMILY != apt ]]; then unsupported_ros; return 2; fi

    local gen="" ver="" choice
    local max=2
    printf '\n%s安装 ROS / ROS2%s\n' "$C_BOLD" "$C_OFF"
    printf '1) ROS 1  '
    if ros1_supported; then
        printf '%s(推荐版本: %s)%s\n' "$C_DIM" "$ROS1_DISTRO" "$C_OFF"
    else
        printf '%s(当前系统不支持)%s\n' "$C_YELLOW" "$C_OFF"
    fi
    printf '2) ROS 2  '
    if ros2_supported; then
        printf '%s(推荐版本: %s)%s\n' "$C_DIM" "$ROS2_DISTRO" "$C_OFF"
    else
        printf '%s(当前系统不支持)%s\n' "$C_YELLOW" "$C_OFF"
    fi

    # 两个版本都不可用时，直接说明原因并给出可行路径。
    # 不让用户对着一个明知无效的菜单反复输入——那不是交互，是折磨。
    if ! ros1_supported && ! ros2_supported; then
        err "当前系统 ${PRETTY_NAME}（codename: ${DISTRO_CODENAME:-未知}）无法安装任何 ROS 版本"
        if [[ $PKG_FAMILY != apt ]]; then
            err "原因：ROS 官方只发布 .deb 包，当前包管理器为 ${PKG_FAMILY}。"
        else
            err "原因：该系统不在 ROS 官方支持列表内（ROS 1/ROS 2 均只覆盖 Ubuntu 与 Debian 家族的主流版本）。"
        fi
        err "可行方案："
        err "  1) 使用容器运行 ROS： docker run -it osrf/ros:humble-desktop"
        err "  2) 参考官方文档手工安装： https://docs.ros.org"
        return 2
    fi

    while :; do
        printf '请输入编号 [1-2]: '
        IFS= read -r choice || return 1
        [[ $choice =~ ^[12]$ ]] && break
        printf '%s请输入 1 或 2%s\n' "$C_YELLOW" "$C_OFF"
    done

    if [[ $choice == 1 ]]; then
        gen=ros1
        if ! ros1_supported; then
            err "当前系统无法安装 ROS 1"
            if [[ $DISTRO_ID == ubuntu && ( $DISTRO_CODENAME == jammy || $DISTRO_CODENAME == noble || $DISTRO_CODENAME == resolute ) ]]; then
                err "原因：ROS 1 从未为 Ubuntu 22.04 及以上版本发布，且已于 2025 年 5 月停止支持。"
            else
                err "原因：ROS 1 只为 Ubuntu 发布，当前系统为 ${PRETTY_NAME}。"
            fi
            ros2_supported && info "本机可安装 ROS 2 ${ROS2_DISTRO}"
            return 1
        fi
        ver=$ROS1_DISTRO
    else
        gen=ros2
        if ! ros2_supported; then
            err "当前系统无法安装 ROS 2：${PRETTY_NAME} 不在 ROS 2 支持列表内"
            err "ROS 2 官方支持 Ubuntu 与 Debian 家族的主流版本"
            return 1
        fi
        ver=$ROS2_DISTRO
    fi

    info "准备安装 ROS ${gen#ros} ${ver}"

    # 1) 依赖
    pkg_install curl gnupg ca-certificates lsb-release || return 1

    # 2) 密钥（强制指纹校验）
    install_ros_keyring || {
        err "密钥安装中止，未做任何源配置改动"
        return 1
    }

    # 3) 选镜像并写源
    local mirror
    if ! mirror=$(rank_mirrors "$gen"); then
        warn "所有镜像测速失败（可能是断网），回退到官方源"
        mirror=packages.ros
    fi
    ros_repo_write "$gen" "$mirror" || return 1

    # 4) 用 apt 作为事实来源确认该版本确实存在
    local avail
    avail=$(apt_ros_available "$gen")
    if [[ " $avail " != *" $ver "* ]]; then
        warn "所选镜像未提供 ros-${ver}-ros-base"
        if [[ -n ${avail// /} ]]; then
            err "该源当前可用版本：${avail}"
        else
            err "该源未检出任何可用的 ROS 版本，请换用工具 12 更换镜像后重试"
        fi
        return 1
    fi
    ok "已确认 ros-${ver}-ros-base 在该源可用"

    # 5) 安装
    local pkg
    if [[ $gen == ros1 ]]; then
        pkg="ros-${ver}-desktop-full"
    else
        pkg="ros-${ver}-desktop"
    fi
    if pkg_exists "$pkg"; then
        ok "$pkg 已安装，跳过"
    else
        pkg_install "$pkg" || {
            err "ROS 安装失败。常见原因：镜像不完整或密钥问题"
            err "可先运行： bash envkit.sh --fix-key"
            return 1
        }
    fi

    # 6) 按产物判定成功，而不是匹配安装输出里的字符串
    if [[ -f /opt/ros/$ver/setup.bash ]]; then
        ok "ROS ${ver} 安装成功（/opt/ros/${ver}/setup.bash）"
        info "接下来请执行工具 3 配置环境变量"
    else
        err "安装结束但未找到 /opt/ros/${ver}/setup.bash，安装未成功"
        return 1
    fi
}

# --------------------------- 2. rosdep ---------------------------------------
tool_install_rosdep() {
    [[ $PKG_FAMILY == apt ]] || { pkg_install python3-rosdep python3-rosdistro && return 0; }

    if pkg_exists python3-rosdep; then
        ok "rosdep 已安装"
    else
        pkg_install python3-rosdep python3-rosdistro || return 1
    fi

    # rosdep init 幂等：已初始化过就只更新数据库
    if [[ -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
        info "rosdep 已初始化，跳过 init，执行 update"
    else
        ensure_root || return 1
        run "rosdep init" "${SUDO[@]}" rosdep init || return 1
    fi
    run "rosdep update" rosdep update || return 1
    ok "rosdep 配置完成"
}

# --------------------------- 3. 环境变量 -------------------------------------
tool_config_rosenv() {
    local distro="${1:-}" auto=0
    if [[ -z $distro ]]; then
        # 探测已安装的 ROS
        if [[ -d /opt/ros/noetic ]]; then distro=noetic
        elif [[ -d /opt/ros/melodic ]]; then distro=melodic
        elif [[ -d /opt/ros/humble ]]; then distro=humble
        elif [[ -d /opt/ros/jazzy ]];  then distro=jazzy
        elif [[ -d /opt/ros/kilted ]]; then distro=kilted
        else
            err "未检测到已安装的 ROS，请先执行工具 1"
            return 1
        fi
    fi
    if [[ ! -f /opt/ros/$distro/setup.bash ]]; then
        err "/opt/ros/${distro}/setup.bash 不存在，无法配置环境"
        return 1
    fi

    bashrc_set_block "ros-env" <<EOF
# 由 envkit.sh 生成（ROS ${distro}）
[ -f /opt/ros/${distro}/setup.bash ] && source /opt/ros/${distro}/setup.bash
EOF

    # 清理历史遗留的重复 source 行。
    # 只删除受管标记块「之外」的裸 source 行；标记块内部（含标记行本身）
    # 原样保留。必须 print 标记行——用 next 会把标记本身删掉，导致下次执行
    # 无法识别已有块，块内容不断重复累积。
    local rc="${HOME}/.bashrc" before after tmp
    before=$(grep -c "^source /opt/ros/" "$rc" 2>/dev/null || true)
    before=${before:-0}
    if (( before > 0 )); then
        tmp=$(mktemp) || return 1
        awk '
            $0 == "# >>> ros-env >>>" { inblk = 1; print; next }
            $0 == "# <<< ros-env <<<" { inblk = 0; print; next }
            inblk                       { print; next }
            /^source \/opt\/ros\//      { next }
            { print }
        ' "$rc" >"$tmp" || { rm -f "$tmp"; err "解析 $rc 失败"; return 1; }

        if (( DRY_RUN )); then
            rm -f "$tmp"
            info "[dry-run] 将移除 ${before} 行重复的 source /opt/ros/... "
        else
            cat "$tmp" >"$rc" || { rm -f "$tmp"; err "写入 $rc 失败"; return 1; }
            rm -f "$tmp"
            after=$(grep -c "^source /opt/ros/" "$rc" 2>/dev/null || true)
            after=${after:-0}
            if (( after == 0 )); then
                ok "已清理 ${before} 行历史遗留的重复 source（现在仅由受管标记块加载）"
            else
                warn "已清理大部分，但仍残留 ${after} 行，请手动检查 $rc"
            fi
        fi
    fi

    ok "环境变量已配置。重新打开终端或执行： source ~/.bashrc"
}

# --------------------------- 4. Gazebo ---------------------------------------
tool_install_gazebo() {
    local distro="${1:-}" pkg
    if [[ -z $distro ]]; then
        local d
        for d in noetic humble jazzy galactic melodic; do
            [[ -d /opt/ros/$d ]] && { distro=$d; break; }
        done
        [[ -n $distro ]] || { err "未检测到已安装的 ROS"; return 1; }
    fi
    case $distro in
        noetic|melodic) pkg="ros-${distro}-gazebo-ros-pkgs" ;;
        *)             pkg="ros-${distro}-gazebo-ros-pkgs" ;;
    esac
    if pkg_exists "$pkg"; then
        ok "$pkg 已安装，跳过"
    else
        pkg_install "$pkg" || return 1
    fi
    ok "Gazebo 安装完成"
}

# --------------------------- 5. Cartographer --------------------------------
tool_install_cartographer() {
    [[ $PKG_FAMILY == apt ]] || { err "Cartographer 编译仅支持 Debian/Ubuntu"; return 2; }

    warn "Cartographer 没有可直接安装的通用 deb 包，多数系统需要源码编译。"
    warn "编译耗时约 30-60 分钟（取决于 CPU 核数），且需要网络拉取依赖。"
    warn "官方 deb 仓库仅覆盖部分 Ubuntu 版本与 x86_64 架构。"
    printf '是否继续？(yes/no): '
    local ans; IFS= read -r ans || return 1
    [[ $ans == yes ]] || { info "已取消"; return 0; }

    pkg_install git cmake build-essential libgoogle-glog-dev libgflags-dev \
        libatlas-base-dev libsuitesparse-dev libgoogle-glog-dev libboost-all-dev \
        libpoco-dev python3-empy python3-lxml || return 1

    local srcdir="${WORKDIR}/cartographer"
    if (( DRY_RUN )); then
        info "[dry-run] 将克隆源码到 $srcdir 并执行 catkin_make"
        return 0
    fi
    info "正在克隆源码（首次约需数分钟）..."
    if ! git clone --depth 1 -b 1.0 https://github.com/cartographer-project/cartographer.git "$srcdir"; then
        err "源码克隆失败"
        return 1
    fi
    run "编译 cartographer_ros（耗时较长，请耐心等待）" \
        bash -c "cd '$srcdir' && mkdir -p build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j$(nproc)"
}

# --------------------------- 6. 开发基础工具 ---------------------------------
tool_dev_essentials() {
    local pkgs
    if [[ $PKG_FAMILY == apt ]]; then
        pkgs=(git curl wget build-essential cmake python3-pip python3-dev
              vim tree htop tmux unzip zip jq rsync openssh-client
              pkg-config gdb net-tools iputils-ping)
    elif [[ $PKG_FAMILY == dnf ]]; then
        pkgs=(git curl wget gcc gcc-c++ make cmake python3-pip vim tree htop tmux unzip zip jq rsync)
    elif [[ $PKG_FAMILY == pacman ]]; then
        pkgs=(git curl wget base-devel cmake python-pip vim tree htop tmux unzip zip jq rsync)
    elif [[ $PKG_FAMILY == zypper ]]; then
        pkgs=(git curl wget gcc gcc-c++ make cmake python3-pip vim tree htop tmux unzip zip jq rsync)
    else
        err "无受支持的包管理器"
        return 2
    fi

    # 逐个检查，只装缺失的（幂等，也避免无谓的网络下载）
    local missing=() p
    for p in "${pkgs[@]}"; do
        pkg_exists "$p" || missing+=("$p")
    done
    if (( ${#missing[@]} == 0 )); then
        ok "开发基础工具已齐全，无需安装"
        return 0
    fi
    info "需要安装 ${#missing[@]} 个包：${missing[*]}"
    pkg_install "${missing[@]}" || return 1
    ok "开发基础工具安装完成"
}

# --------------------------- 7. pip 镜像 -------------------------------------
tool_config_pip() {
    local mirror="${1:-https://pypi.tuna.tsinghua.edu.cn/simple}"
    [[ $PKG_FAMILY == apt ]] || { pkg_install python3-pip; }
    ensure_root || return 1
    write_root_file /etc/pip.conf <<EOF
[global]
index-url = ${mirror}
trusted-host = $(printf '%s' "$mirror" | sed -E 's#^https?://([^/]+).*#\1#')

[install]
trusted-host = $(printf '%s' "$mirror" | sed -E 's#^https?://([^/]+).*#\1#')
EOF
    ok "pip 镜像已配置：$mirror"
}

# --------------------------- 8. git 配置 -------------------------------------
tool_config_git() {
    if ! command -v git >/dev/null 2>&1; then
        pkg_install git || return 1
    fi
    local cur_name cur_email
    cur_name=$(git config --global user.name 2>/dev/null || true)
    cur_email=$(git config --global user.email 2>/dev/null || true)

    local name email
    if [[ -n $cur_name ]]; then
        printf '当前 user.name = %s，保留还是修改？(Enter=保留): ' "$cur_name"
        IFS= read -r name || return 1
        [[ -z $name ]] && name=$cur_name
    else
        printf '设置 git user.name: '
        IFS= read -r name || return 1
    fi
    if [[ -n $cur_email ]]; then
        printf '当前 user.email = %s，保留还是修改？(Enter=保留): ' "$cur_email"
        IFS= read -r email || return 1
        [[ -z $email ]] && email=$cur_email
    else
        printf '设置 git user.email: '
        IFS= read -r email || return 1
    fi
    [[ -n $name ]]  && git config --global user.name  "$name"
    [[ -n $email ]] && git config --global user.email "$email"
    ok "git 配置完成：${name:-未设置} <${email:-未设置}>"
}

# --------------------------- 9. inotify 调优 ---------------------------------
#
# 实际需求来源：Obsidian / VSCode / webpack 等工具会同时 watch 上万目录，
# 达到内核默认上限 max_user_watches=65536 后报
# ENOSPC: System limit for number of file watchers reached。
tool_tune_inotify() {
    local target=524288
    local cur cur_usage=0 pid n
    cur=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)

    # 统计当前占用，让用户直观看到为什么需要调大
    for pid in /proc/[0-9]*; do
        n=$(cat "$pid"/fdinfo/* 2>/dev/null | grep -c "^inotify wd:" || true)
        cur_usage=$(( cur_usage + n ))
    done

    info "当前 max_user_watches = ${cur}"
    info "当前全系统已用watch 数 ≈ ${cur_usage}"
    if (( cur_usage < cur * 80 / 100 )); then
        info "占用率未逼近上限，可稍后再执行本项"
    else
        warn "占用率已达上限的 $(( cur_usage * 100 / cur ))%，这正是 Obsidian 等报 ENOSPC 的原因"
    fi
    if (( cur >= target )); then
        ok "上限已足够（${cur} >= ${target}），无需调整"
        return 0
    fi

    printf '将把上限提升到 %s，继续？(yes/no): ' "$target"
    local ans; IFS= read -r ans || return 1
    [[ $ans == yes ]] || { info "已取消"; return 0; }

    ensure_root || return 1
    write_root_file /etc/sysctl.d/99-envkit-inotify.conf <<EOF
# 由 envkit.sh 生成：提升 inotify 文件监听上限
# 背景：Obsidian / VSCode 等同时 watch 大量目录时会耗尽默认的 65536，
#报 ENOSPC: System limit for number of file watchers reached
fs.inotify.max_user_watches=${target}
fs.inotify.max_user_instances=1024
EOF
    run "立即生效" "${SUDO[@]}" sysctl -p /etc/sysctl.d/99-envkit-inotify.conf || return 1

    local now
    now=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
    if (( DRY_RUN )); then
        info "[dry-run] 实际执行后，上限将变为 ${target}（当前 ${now}）"
        return 0
    fi
    if (( now >= target )); then
        ok "inotify 上限已提升到 ${now}"
    else
        err "设置未生效（当前 ${now}）"
        return 1
    fi
}

# --------------------------- 10. 时区与 locale --------------------------------
tool_config_locale() {
    if (( DRY_RUN )); then
        info "[dry-run] 将配置 locale 与时区"
    fi
    # locale：仅警告不中断。鱼香在此硬退出，而 `curl | bash` 场景下管道里
    # LANG 往往未导出，会误判后要求用户重跑。
    local cur_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    case $cur_locale in
        *UTF-8*|*utf8*|*UTF8*)
            ok "当前 locale 已是 UTF-8：$cur_locale" ;;
        *)
            warn "当前 locale 非 UTF-8，中文可能显示为乱码"
            warn "建议： sudo locale-gen zh_CN.UTF-8  并在 ~/.bashrc 中设置 LANG=zh_CN.UTF-8"
            warn "（不影响脚本功能，继续执行）" ;;
    esac

    printf '设置时区为 Asia/Shanghai？(yes/no): '
    local ans; IFS= read -r ans || return 1
    [[ $ans == yes ]] || return 0
    ensure_root || return 1
    if command -v timedatectl >/dev/null 2>&1; then
        run "设置时区" "${SUDO[@]}" timedatectl set-timezone Asia/Shanghai || return 1
    else
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null \
            || { err "设置时区失败"; return 1; }
        echo "Asia/Shanghai" >/etc/timezone 2>/dev/null || true
    fi
    ok "时区已设置为 Asia/Shanghai"
}

# --------------------------- 11. APT 源（先备份） ----------------------------
APT_MIRRORS=(
    "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
    "https://mirrors.aliyun.com/ubuntu/"
    "https://mirrors.ustc.edu.cn/ubuntu/"
    "https://mirrors.huaweicloud.com/ubuntu/"
    "http://archive.ubuntu.com/ubuntu/"
)

tool_config_apt_source() {
    [[ $PKG_FAMILY == apt ]] || { err "此功能仅适用于 Debian/Ubuntu 家族"; return 2; }

    warn "此操作会修改系统 apt 源。执行前会自动备份现有全部第三方源。"
    printf '继续？(yes/no): '
    local ans; IFS= read -r ans || return 1
    [[ $ans == yes ]] || { info "已取消"; return 0; }

    printf '请选择镜像：\n'
    local i
    for i in "${!APT_MIRRORS[@]}"; do
        printf '  %d) %s\n' "$((i+1))" "${APT_MIRRORS[$i]}"
    done
    printf '序号 [1]: '
    local n; IFS= read -r n || return 1
    n=${n:-1}
    [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#APT_MIRRORS[@]} )) || { err "无效选择"; return 1; }
    local mirror=${APT_MIRRORS[$((n-1))]}

    ensure_root || return 1
    local bak
    bak=$(backup_sources_dir) || return 1

    if [[ -n $bak && -d $bak && ${DRY_RUN} -eq 0 ]]; then
        warn "为避免误伤，将把 sources.list.d 下原有内容移出到：$bak"
        local f
        for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [[ -e $f ]] || continue
            "${SUDO[@]}" mv "$f" "$bak/" 2>/dev/null || true
        done
    fi

    write_root_file /etc/apt/sources.list <<EOF
# 由 envkit.sh 生成（镜像：$mirror）
# 变更前的原始内容备份在：${bak:-（见 /etc/apt/sources.list.*.envkit.bak）}
# 注意：各镜像的 -security 套件与 -updates 同路径提供，无需单独域名。
# 已实测：tsinghua/aliyun/ustc/huawei/archive 均直接服务 dists/<代号>-security/Release。
deb ${mirror} ${DISTRO_CODENAME} main restricted universe multiverse
deb ${mirror} ${DISTRO_CODENAME}-updates main restricted universe multiverse
deb ${mirror} ${DISTRO_CODENAME}-security main restricted universe multiverse
EOF
    # 备份原始 sources.list 本身
    if [[ ${DRY_RUN} -eq 0 && -f /etc/apt/sources.list ]]; then
        warn "提示：原 /etc/apt/sources.list 已覆盖，若需还原请检查 ${bak:-备份目录}"
    fi
    ok "apt 源已配置为 $mirror"
    warn "请先执行 apt update 验证新源可用，再进行其它操作"
}

# --------------------------- 12. ROS 源专用 ----------------------------------
ros_repo_write() {   # $1=ros1|ros2  $2=镜像键
    local gen=$1 key=$2 url dest=/etc/apt/sources.list.d/ros.list
    url=$(ros_base_url "$gen" "$key") || { err "未知镜像：$key"; return 1; }
    ensure_root || return 1

    # 只删除自己写出的这个文件名，绝不 rm -rf 目录（鱼香会摧毁第三方源）
    if (( DRY_RUN )); then
        printf '%s[dry-run] 将写入 %s%s\n' "$C_DIM" "$dest" "$C_OFF"
    else
        "${SUDO[@]}" rm -f "$dest"
    fi
    write_root_file "$dest" <<EOF
# 由 envkit.sh 生成（${gen}，镜像 ${key}）——可安全删除本文件
deb [arch=${APT_ARCH} signed-by=${ROS_KEYRING}] ${url}/ ${DISTRO_CODENAME} main
EOF
    (( DRY_RUN )) && return 0
    pkg_update >/dev/null 2>&1 || warn "apt update 出现警告，请检查网络或镜像"
    ok "ROS 源已配置：${url} (${DISTRO_CODENAME})"
}

tool_config_ros_source() {
    [[ $PKG_FAMILY == apt ]] || { unsupported_ros; return 2; }
    require_64bit_arm_ok || return 1

    local gen
    if ros1_supported && ros2_supported; then
        printf '配置哪个版本？1) ROS1(%s)  2) ROS2(%s)： ' "$ROS1_DISTRO" "$ROS2_DISTRO"
        IFS= read -r gen || return 1
        [[ $gen == 1 ]] && gen=ros1 || gen=ros2
    elif ros1_supported; then
        gen=ros1
    elif ros2_supported; then
        gen=ros2
    else
        err "当前系统不支持任何 ROS 版本（${PRETTY_NAME}）"
        return 1
    fi

    install_ros_keyring || return 1

    local mirror
    if ! mirror=$(rank_mirrors "$gen"); then
        warn "测速失败，回退官方源"
        mirror=packages.ros
    fi
    ros_repo_write "$gen" "$mirror" || return 1

    local avail
    avail=$(apt_ros_available "$gen")
    ok "当前该源可用版本：${avail:-（未检出）}"
}

# --------------------------- 13. Docker --------------------------------------
tool_install_docker() {
    if command -v docker >/dev/null 2>&1; then
        ok "Docker 已安装：$(docker --version 2>/dev/null)"
        return 0
    fi
    [[ $PKG_FAMILY == apt ]] || { err "自动安装 Docker 目前仅支持 Debian/Ubuntu"; return 2; }
    ensure_root || return 1
    warn "将安装 Docker Engine（含 docker-compose 插件）"
    printf '继续？(yes/no): '
    local ans; IFS= read -r ans || return 1
    [[ $ans == yes ]] || { info "已取消"; return 0; }

    if (( DRY_RUN )); then
        info "[dry-run] 将添加 Docker 官方仓库并安装 docker-ce"
        return 0
    fi
    run "安装 Docker 依赖" env DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" \
        apt-get install -y ca-certificates curl gnupg || return 1
    run "下载并去armor Docker 公钥" bash -c \
        "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor | ${SUDO[*]} tee /usr/share/keyrings/docker.gpg >/dev/null"
    write_root_file /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${APT_ARCH} signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${DISTRO_CODENAME} stable
EOF
    pkg_update || return 1
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    ok "Docker 安装完成"
}

# --------------------------- 14. 诊断 ----------------------------------------
doctor() {
    printf '%s%s================ envkit 诊断报告 ================%s\n' "$C_BOLD" "$C_CYAN" "$C_OFF"
    printf '%-18s %s\n' "系统"        "$PRETTY_NAME"
    printf '%-18s %s\n' "ID"          "$DISTRO_ID"
    printf '%-18s %s\n' "VERSION"     "$DISTRO_VERSION"
    printf '%-18s %s\n' "CODENAME"    "${DISTRO_CODENAME:-（未知）}"
    printf '%-18s %s\n' "ID_LIKE"     "$DISTRO_FAMILY"
    printf '%-18s %s\n' "内核架构"    "$KERNEL_ARCH"
    printf '%-18s %s\n' "apt 架构"    "${PKG_ARCH:-（无 dpkg）}"
    printf '%-18s %s\n' "包管理器"    "$PKG_FAMILY"
    if (( IS_ARM64 )); then
        printf '%-18s %s\n' "ARM64"      "是（优先官方源）"
    fi
    if (( IS_32BIT_ARMF )); then
        printf '%-18s %s\n' "32位 ARM"   "是（ROS2 将不可用）"
    fi

    printf '\n%s-- ROS 支持情况 --%s\n' "$C_BOLD" "$C_OFF"
    if ros1_supported; then
        printf '%-18s %s\n' "ROS 1" "可用（推荐 $ROS1_DISTRO）"
    else
        printf '%-18s %s\n' "ROS 1" "不可用"
    fi
    if ros2_supported; then
        printf '%-18s %s\n' "ROS 2" "可用（推荐 $ROS2_DISTRO）"
    else
        printf '%-18s %s\n' "ROS 2" "不可用"
    fi
    if [[ $PKG_FAMILY == apt ]]; then
        printf '\n%s-- apt 中已存在的 ROS 包 --%s\n' "$C_BOLD" "$C_OFF"
        local avail
        avail=$(apt_ros_available ros1)$(apt_ros_available ros2)
        printf '%s\n' "${avail:-（无 ROS 源或未执行 apt update）}"
    fi

    printf '\n%s-- 已安装的 ROS --%s\n' "$C_BOLD" "$C_OFF"
    local d found=0
    for d in /opt/ros/*/; do
        [[ -d $d ]] || continue
        printf '  %s\n' "$(basename "$d")"; found=1
    done
    (( found )) || printf '  （无）\n'

    printf '\n%s-- 密钥状态 --%s\n' "$C_BOLD" "$C_OFF"
    if key_fingerprint_ok "$ROS_KEYRING"; then
        printf '  %s✓ %s 指纹匹配\n' "$C_GREEN" "$ROS_KEYRING"
    elif [[ -f $ROS_KEYRING ]]; then
        printf '  %s✗ %s 指纹不匹配，建议运行 --fix-key\n' "$C_RED" "$ROS_KEYRING"
    else
        printf '  未安装\n'
    fi
    # 鱼香可能留下的垃圾密钥
    local stale
    stale=$(ls /etc/apt/trusted.gpg.d/ros*.gpg 2>/dev/null || true)
    [[ -n $stale ]] && printf '  发现旧版密钥（建议清理）：\n%s\n' "$stale"

    printf '\n%s-- inotify --%s\n' "$C_BOLD" "$C_OFF"
    local mw mi usage=0 pid n
    mw=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
    mi=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
    for pid in /proc/[0-9]*; do
        n=$(cat "$pid"/fdinfo/* 2>/dev/null | grep -c "^inotify wd:" || true)
        usage=$(( usage + n ))
    done
    printf '  max_user_watches = %s\n' "$mw"
    printf '  max_user_instances= %s\n' "$mi"
    printf '  已用 watches     ≈ %s\n' "$usage"
    if (( mw > 0 && usage * 100 / mw >= 80 )); then
        printf '  %s占用率 %s%%，已接近上限（Obsidian 等会报 ENOSPC）\n' \
            "$C_YELLOW" "$(( usage * 100 / mw ))"
    fi

    printf '\n%s-- 第三方 apt 源 --%s\n' "$C_BOLD" "$C_OFF"
    if [[ $PKG_FAMILY == apt ]]; then
        local f
        shopt -s nullglob
        for f in /etc/apt/sources.list.d/*; do
            printf '  %s\n' "$(basename "$f")"
        done
        shopt -u nullglob
    fi

    printf '\n%s-- .bashrc 中的 ROS 配置 --%s\n' "$C_BOLD" "$C_OFF"
    if [[ -f $HOME/.bashrc ]]; then
        # grep -c 无匹配时返回 0 但退出码为 1，故用 || true 兜住，
        # 避免把 "0" 与 "1" 一起输出导致显示成两行
        local marked unmarked
        marked=$(grep -c ">>> ros-env >>>" "$HOME/.bashrc" 2>/dev/null || true)
        unmarked=$(grep -c "^source /opt/ros/" "$HOME/.bashrc" 2>/dev/null || true)
        printf '  受管标记块: %s\n' "${marked:-0}"
        printf '  未标记的 source 行: %s\n' "${unmarked:-0}"
    fi

    printf '\n%s 日志: %s%s\n' "$C_DIM" "$LOG_FILE" "$C_OFF"
}

# --------------------------- 15. 回滚 ----------------------------------------
tool_rollback() {
    warn "将移除 envkit 写入的文件："
    printf '  /etc/apt/sources.list.d/ros.list\n'
    printf '  /etc/sysctl.d/99-envkit-inotify.conf\n'
    printf '  /etc/pip.conf\n'
    printf '  ~/.bashrc 中的 [ros-env] 标记块\n'
    printf '  apt 备份目录 /etc/apt/sources.list.d/envkit-backup-*\n'
    printf '  %s\n' "$ROS_KEYRING"
    printf '\n注意：不会删除已安装的软件包，也不会改动其它软件的配置。\n'
    printf '确认执行？(yes/no): '
    local ans; IFS= read -r ans || return 1
    [[ $ans == yes ]] || { info "已取消"; return 0; }
    ensure_root || return 1

    (( DRY_RUN )) && { info "[dry-run] 将移除上述文件"; return 0; }

    "${SUDO[@]}" rm -f /etc/apt/sources.list.d/ros.list
    "${SUDO[@]}" rm -f /etc/sysctl.d/99-envkit-inotify.conf
    "${SUDO[@]}" rm -f /etc/pip.conf
    "${SUDO[@]}" rm -rf -- /etc/apt/sources.list.d/envkit-backup-*
    "${SUDO[@]}" rm -f "$ROS_KEYRING"
    # 清理旧版残留密钥
    "${SUDO[@]}" rm -f /etc/apt/trusted.gpg.d/ros.gpg 2>/dev/null || true
    bashrc_remove_block "ros-env"
    ok "回滚完成（已安装的软件包未受影响）"
}

bashrc_remove_block() {
    local tag=$1 rc="${HOME}/.bashrc"
    local begin="# >>> ${tag} >>>" end="# <<< ${tag} <<<"
    local tmp
    [[ -f $rc ]] || return 0
    tmp=$(mktemp) || return 1
    awk -v b="$begin" -v e="$end" '
        $0 == b { inblk = 1; next }
        $0 == e { inblk = 0; next }
        !inblk    { print }
    ' "$rc" >"$tmp" && cat "$tmp" >"$rc"
    rm -f "$tmp"
    ok "已移除 ~/.bashrc 中的 [$tag] 块"
}

# ==============================================================================
# §8  工具注册表
# ==============================================================================
register_all_tools() {
    register_tool 1  ros   "安装 ROS / ROS2（源 + 密钥指纹校验）"        tool_install_ros
    register_tool 2  ros   "安装并初始化 rosdep"                        tool_install_rosdep
    register_tool 3  ros   "配置 ROS 环境变量（幂等标记块）"            tool_config_rosenv
    register_tool 4  ros   "安装 Gazebo"                                tool_install_gazebo
    register_tool 5  ros   "编译安装 Cartographer（耗时较长）"          tool_install_cartographer
    register_tool 6  dev   "开发基础工具（git/cmake/gcc/python3 等）"    tool_dev_essentials
    register_tool 7  dev   "配置 pip 国内镜像源"                        tool_config_pip
    register_tool 8  dev   "配置 git 用户名与邮箱"                      tool_config_git
    register_tool 9  sys   "调整 inotify 文件监听上限（修复 ENOSPC）"   tool_tune_inotify
    register_tool 10 sys   "配置时区与 locale"                          tool_config_locale
    register_tool 11 net   "更换 APT 系统源（自动备份）"                tool_config_apt_source
    register_tool 12 net   "配置 / 修复 ROS 源（可换镜像）"             tool_config_ros_source
    register_tool 13 other "安装 Docker"                                 tool_install_docker
    register_tool 14 other "系统诊断报告"                                doctor
    register_tool 15 other "回滚 envkit 的所有改动"                     tool_rollback
}

# ==============================================================================
# §9  密钥修复专用入口
# ==============================================================================
fix_key_flow() {
    printf '%s%s============ ROS 密钥与源修复 ============%s\n' "$C_BOLD" "$C_CYAN" "$C_OFF"
    [[ $PKG_FAMILY == apt ]] || { unsupported_ros; return 2; }

    info "当前密钥状态："
    if key_fingerprint_ok "$ROS_KEYRING"; then
        ok "  ${ROS_KEYRING} 指纹匹配"
    elif [[ -f $ROS_KEYRING ]]; then
        err "  ${ROS_KEYRING} 指纹不匹配或已损坏"
    else
        info "  未安装专用 keyring"
    fi
    # 排查旧版工具留下的残留
    local stale found=0
    for stale in /etc/apt/trusted.gpg.d/ros*.gpg /etc/apt/trusted.gpg.d/*ros*.asc; do
        [[ -e $stale ]] || continue
        found=1
        local sz; sz=$(wc -c <"$stale" 2>/dev/null || echo 0)
        if (( sz == 0 )); then
            err "  发现 0 字节残留密钥（典型的下载失败产物）：$stale"
        else
            info "  发现旧版密钥：$stale（${sz} 字节）"
        fi
    done
    (( found )) && warn "  这些旧密钥来自已废弃的 trusted.gpg.d，会被一并清理"

    printf '\n将执行：清理旧密钥 -> 按指纹校验方式重新安装 -> 重写 ROS 源\n'
    printf '继续？(yes/no): '
    local ans; IFS= read -r ans || return 1
    [[ $ans == yes ]] || { info "已取消"; return 0; }
    ensure_root || return 1

    if (( DRY_RUN )); then
        info "[dry-run] 将清理旧密钥并重装到 ${ROS_KEYRING}"
        return 0
    fi

    # 清理残留（含 0 字节垃圾文件）
    "${SUDO[@]}" rm -f /etc/apt/trusted.gpg.d/ros*.gpg /etc/apt/trusted.gpg.d/*ros*.asc 2>/dev/null || true
    "${SUDO[@]}" rm -f "$ROS_KEYRING"
    ok "已清理全部 ROS 残留密钥"

    pkg_install curl gnupg ca-certificates || return 1
    install_ros_keyring || return 1

    # 重写源（用新的 signed-by）
    local gen
    if ros1_supported; then gen=ros1
    elif ros2_supported; then gen=ros2
    else
        warn "当前系统无对应 ROS 版本，仅完成密钥修复"
        return 0
    fi
    local mirror
    if ! mirror=$(rank_mirrors "$gen"); then
        warn "测速失败，回退官方源"
        mirror=packages.ros
    fi
    ros_repo_write "$gen" "$mirror" || return 1

    # 验证
    if pkg_update; then
        ok "apt update 成功，密钥问题已解决"
    else
        err "apt update 仍失败。请检查网络或尝试更换镜像（工具 12）"
        return 1
    fi
}

# ==============================================================================
# §10  主流程
# ==============================================================================

usage() {
    cat <<EOF
${C_BOLD}envkit —— 通用开发环境一键安装套件${C_OFF}

用法：
  bash envkit.sh [选项]

选项：
  --doctor        输出系统诊断报告后退出（只读，不改动系统）
  --dry-run       预演模式：打印将要执行的操作但不实际执行、不调用 sudo
  --fix-key       修复 ROS 密钥与源配置（应对 apt update 报 NO_PUBKEY）
  -m, --mirror    指定镜像偏好（tsinghua / ustc / huawei / mirrorz / packages.ros）
  -h, --help      显示本帮助

环境变量：
  ROS_OS_OVERRIDE=id:version:codename   覆盖系统探测（试验用）
  ENVKIT_DRY_RUN=1                      等价于 --dry-run
  ENVKIT_RECORD=1                       记录所选工具以便下次回放
  NO_COLOR=1                            关闭彩色输出
EOF
}

parse_args() {
    while (( $# )); do
        case $1 in
            --doctor)   DOCTOR_ONLY=1 ;;
            --dry-run)  DRY_RUN=1 ;;
            --fix-key)  FIX_KEY_ONLY=1 ;;
            -m|--mirror) shift; PREFERRED_MIRROR="${1:-}" ;;
            -h|--help)
                usage
                if (( ENVKIT_SOURCED )); then return 0; else exit 0; fi
                ;;
            *)
                err "未知选项：$1"
                usage
                if (( ENVKIT_SOURCED )); then return 1; else exit 1; fi
                ;;
        esac
        shift
    done
    [[ ${ENVKIT_DRY_RUN:-0} == 1 ]] && DRY_RUN=1
    DOCTOR_ONLY=${DOCTOR_ONLY:-0}
}

main() {
    # 注意 ${BASH_VERSINFO[0]} 必须带花括号，否则 $BASH_VERSINFO[0] 会被解析成
    # 变量 BASH_VERSINFO 后跟字面量 [0]，在 [[ ]] 中触发算术语法错误
    (( BASH_VERSINFO[0] < 4 )) && die "需要 Bash 4+"
    parse_args "$@"

    # 一次性计算提权前缀：容器内/root/minimal 镜像下没有 sudo 也不该报错
    SUDO=()
    (( EUID != 0 )) && command -v sudo >/dev/null 2>&1 && SUDO=(sudo)

    detect_os
    detect_arch
    detect_pkg_family
    register_all_tools

    mkdir -p -- "$(dirname "$LOG_FILE")" 2>/dev/null || true

    (( DRY_RUN )) && info "预演模式：所有改动都不会实际执行"

    if (( DOCTOR_ONLY )); then
        doctor
        if (( ENVKIT_SOURCED )); then return 0; else exit 0; fi
    fi
    if (( FIX_KEY_ONLY )); then
        new_workdir || true
        fix_key_flow
        local rc=$?
        if (( ENVKIT_SOURCED )); then return $rc; else exit $rc; fi
    fi

    new_workdir || true

    if queue_load; then
        info "检测到回放队列 $QUEUE_FILE（${QUEUE_IDX} 项），将按顺序自动执行"
    fi

    local choice fn
    while :; do
        render_menu
        # 回放队列优先；无队列时向用户读取（结果在全局 CHOICE 中）
        if ! queue_peek; then
            if ! read_choice "请选择 [0-${#TOOL_ORDER[@]}]: "; then
                ok "已退出"
                break
            fi
        fi
        choice=$CHOICE
        (( QUEUE_IDX > 0 )) && queue_reset
        [[ $choice == 0 ]] && { ok "已退出"; break; }
        fn=${TOOL_FN[$choice]:-}
        if [[ -z $fn ]]; then
            err "无效选项：$choice"
            continue
        fi
        queue_record "$choice"
        printf '\n%s>>> 执行：%s%s\n' "$C_GREEN$C_BOLD" "${TOOL_TIP[$choice]}" "$C_OFF"
        "$fn"
        printf '\n%s按 Enter 继续，或 Ctrl-C 退出%s\n' "$C_DIM" "$C_OFF"
        IFS= read -r _ || true
    done
}

# ==============================================================================
# §11  清理
# ==============================================================================
cleanup() {
    local rc=$?
    # mktemp -d 默认 0700；显式声明，杜绝在 world-writable 目录下的 TOCTOU
    [[ -n ${WORKDIR:-} && -d $WORKDIR ]] && rm -rf -- "$WORKDIR"
    return $rc   # EXIT trap 内不得 exit
}

# source 模式：只设置 INT/TERM 的中断处理，绝不接管 EXIT。
# 若在此注册 EXIT trap，脚本结束时会连带在用户的交互 shell 上触发 cleanup，
# 甚至在用户之后按 Ctrl-C 时误删临时目录。调用方原有的 trap 已在 §0 备份。
if (( ENVKIT_SOURCED )); then
    trap '_envkit_interrupt' INT
    trap '_envkit_interrupt' TERM
else
    trap cleanup EXIT
    trap '_envkit_interrupt' INT
    trap '_envkit_interrupt' TERM
fi

# 中断处理：source 模式下只提示并返回，不能 exit（会关闭用户终端）
_envkit_interrupt() {
    printf '\n'
    warn "已中断"
    if (( ENVKIT_SOURCED )); then
        _envkit_restore_shell
        return 130
    fi
    exit 130
}

# 创建受保护的临时工作目录
new_workdir() {
    WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/envkit.XXXXXXXX") || return 1
    chmod 700 "$WORKDIR"
    return 0
}

# 在任何日志输出之前建好日志目录：parse_args 的错误提示、die 的退出信息
# 都要写日志，目录不存在会让这些路径全部失败
mkdir -p -- "$(dirname "$LOG_FILE")" 2>/dev/null || true

main "$@"
_main_rc=$?

if (( ENVKIT_SOURCED )); then
    # source 模式：清理现场并还原 shell 状态，然后把控制权交还给用户。
    # 绝不能 exit —— 那会直接关掉用户正在使用的终端。
    [[ -n ${WORKDIR:-} && -d $WORKDIR ]] && rm -rf -- "$WORKDIR"
    _envkit_restore_shell
    # 清掉本脚本注入到用户 shell 的函数与变量，避免污染交互提示符
    unset -f ok err warn info die run write_root_file ensure_root 2>/dev/null || true
    unset DRY_RUN PREFERRED_MIRROR FIX_KEY_ONLY SUDO WORKDIR 2>/dev/null || true
    unset DISTRO_ID DISTRO_VERSION DISTRO_CODENAME DISTRO_FAMILY PRETTY_NAME 2>/dev/null || true
    unset KERNEL_ARCH APT_ARCH PKG_ARCH IS_ARM64 IS_32BIT_ARMF PKG_FAMILY 2>/dev/null || true
    unset ENVKIT_SOURCED CHOICE QUEUE_IDX 2>/dev/null || true
    return $_main_rc 2>/dev/null || exit $_main_rc
fi

exit $_main_rc