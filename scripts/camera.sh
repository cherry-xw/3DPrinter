#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# camera.sh — USB 摄像头 (UVC) 开关控制   [Klipper / Armbian sunxi64]
#
#   on / off            开 / 关摄像头（off = 停推流 + 卸载 uvcvideo 模块）
#   stream-off/on       只停 / 启推流（不动内核，最安全，打印中可用）
#   suspend/resume      USB 软断电（空闲自动挂起 / 唤醒）
#   status              状态总览
#   snapshot [out]      抓一张图验证
#   boot off|on         开机是否自动加载 uvcvideo
#   install             安装免密 sudo 规则（Klipper 宏调用必需）
#
# 兼容旧接口: enable/disable/start/stop/state/reload/detect/list/list-all/help
# ---------------------------------------------------------------------------

CAM_MOD="uvcvideo"                     # 摄像头内核模块
CAM_VID="0c45"                         # Microdia / Sonix USB 2.0 Camera
CAM_PID="64a1"
CROWSNEST_SVC="crowsnest"              # 负责跑 ustreamer 的服务
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/camera-ctl"
PORT_FILE="$STATE_DIR/port"            # 记住 USB 端口号(如 1-1)，模块卸载后也能找回
SUDOERS_FILE="/etc/sudoers.d/camera-ctl"
BLACKLIST_FILE="/etc/modprobe.d/00-camera-blacklist.conf"

info() { printf '[信息] %s\n' "$*"; }
ok()   { printf '[成功] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*"; }
err()  { printf '[错误] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------- root 执行 --
# 优先级: 已是 root > 免密 sudo > （仅交互时）输入密码的 sudo
# 注意: 不能用 `sudo -n true` 探测——sudoers 只放行了具体命令，没有 true
as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
    if _out="$(sudo -n "$@" 2>&1)"; then return 0; fi
    case "$_out" in
        *"password is required"*|*"no tty present"*|*"terminal is required"*|*"askpass"*)
            if [ -t 0 ]; then sudo "$@"; return $?; fi
            err "需要 root 权限但当前非交互（Klipper 宏调用）"
            printf '     请先在终端执行一次: %s install\n' "$0" >&2
            return 1 ;;
    esac
    printf '%s\n' "$_out" >&2      # 其它真实错误原样透出
    return 1
}

# 是否具备获取 root 的可能（已是 root / 免密 sudo / 有交互终端）
can_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    sudo -n -l >/dev/null 2>&1 && return 0
    [ -t 0 ] && return 0
    return 1
}

no_root_hint() {
    err "没有 root 权限，无法执行模块/供电相关操作"
    if [ ! -t 0 ]; then
        printf '     当前非交互（Klipper 宏调用），请先在终端执行一次: %s install\n' "$0" >&2
    fi
}

# ------------------------------------------------------------------ 设备探测 --
usbdev() { printf '%s' "/sys/bus/usb/devices/${1}"; }
portname() { basename "${1%/}"; }

# 已绑定 uvcvideo 的 USB 设备（模块在时最准）
scan_bound() {
    for i in /sys/bus/usb/devices/*/; do
        for f in "$i"[0-9]*:*; do
            [ -e "$f/driver" ] || continue
            if readlink -f "$f/driver" 2>/dev/null | grep -q "/${CAM_MOD}\$"; then
                portname "${i%/}"; return 0
            fi
        done
    done
    return 1
}

# 按 VID:PID 找（模块卸载、USB 设备仍在时用）
scan_vidpid() {
    for i in /sys/bus/usb/devices/*/; do
        [ -r "$i/idVendor" ] || continue
        if [ "$(cat "$i/idVendor" 2>/dev/null)" = "$CAM_VID" ] &&
           [ "$(cat "$i/idProduct" 2>/dev/null)" = "$CAM_PID" ]; then
            portname "${i%/}"; return 0
        fi
    done
    return 1
}

cam_port() {
    p="$(scan_bound 2>/dev/null || true)"
    [ -z "$p" ] && p="$(scan_vidpid 2>/dev/null || true)"
    if [ -z "$p" ] && [ -r "$PORT_FILE" ]; then
        p="$(cat "$PORT_FILE" 2>/dev/null)"
        [ -d "$(usbdev "$p")" ] || p=""
    fi
    [ -n "$p" ] || return 1
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s' "$p" > "$PORT_FILE" 2>/dev/null
    printf '%s' "$p"
}

video_nodes() { ls /dev/video* 2>/dev/null | tr '\n' ' '; }
mod_loaded()  { lsmod 2>/dev/null | grep -q "^${CAM_MOD} "; }
stream_on()   { systemctl is-active --quiet "$CROWSNEST_SVC" 2>/dev/null; }
has_streamer(){ pgrep -f "ustreamer.bin" >/dev/null 2>&1; }

# 等设备节点出现（udev 建节点最多等 N 轮 × 0.3s）
wait_nodes() {
    i=0
    while [ $i -lt "${1:-30}" ]; do
        [ -n "$(video_nodes)" ] && return 0
        sleep 0.3; i=$((i + 1))
    done
    return 1
}

cam_pwr_state() {
    p="$(cam_port 2>/dev/null)" || { echo "未找到"; return; }
    d="$(usbdev "$p")/power"
    [ -r "$d/runtime_status" ] || { echo "n/a"; return; }
    echo "$(cat "$d/runtime_status")/$(cat "$d/control" 2>/dev/null)"
}

cam_desc() {
    p="$(cam_port 2>/dev/null)" || { echo "未检测到"; return; }
    d="$(usbdev "$p")"
    # 优先 sysfs 的 product/manufacturer，为空则读 USB 字符串描述符
    prod="$(cat "$d/product" 2>/dev/null)"
    man="$(cat "$d/manufacturer" 2>/dev/null)"
    [ -z "$prod" ] && prod="$(cat "$d/strings/0x02" 2>/dev/null)"
    [ -z "$man" ]  && man="$(cat "$d/strings/0x01" 2>/dev/null)"
    printf '%s %s [%s:%s] %sMbps' "$prod" "$man" "$CAM_VID" "$CAM_PID" "$(cat "$d/speed" 2>/dev/null)"
}

crow_port() {
    grep -A20 '^\[cam 1\]' "$HOME/printer_data/config/crowsnest.conf" 2>/dev/null \
        | grep -m1 '^port:' | sed 's/#.*//' | cut -d: -f2 | tr -d ' \r'
}

# -------------------------------------------------------------------- 命令 --
cmd_status() {
    p="$(cam_port 2>/dev/null || true)"
    echo "======== USB 摄像头状态 ========"
    if [ -n "$p" ]; then
        printf '  端口/型号 : %s  (%s)\n' "$(portname "$p")" "$(cam_desc)"
    else
        printf '  端口/型号 : 未检测到\n'
    fi
    if mod_loaded; then
        printf '  内核模块  : 已加载\n'
    else
        printf '  内核模块  : 已卸载\n'
    fi
    nodes="$(video_nodes)"
    printf '  设备节点  : %s\n' "${nodes:-无}"
    printf '  USB 供电  : %s\n' "$(cam_pwr_state)"
    if stream_on && has_streamer; then
        printf '  推流服务  : 运行中  端口: %s\n' "$(crow_port)"
    elif stream_on; then
        printf '  推流服务  : 启动中\n'
    else
        printf '  推流服务  : 已停止\n'
    fi
    first_node="$(printf '%s' "$nodes" | awk '{print $1}')"
    if [ -n "$first_node" ]; then
        busy="$(fuser "$first_node" 2>/dev/null | tr -s ' ' | cut -d' ' -f2-)"
        [ -n "$busy" ] && printf '  占用进程  : %s\n' "$busy"
    fi
    echo "==============================="
}

cmd_on() {
    info "开启摄像头..."
    if mod_loaded; then
        ok "模块已加载"
    else
        as_root modprobe "$CAM_MOD" || die "modprobe $CAM_MOD 失败"
        wait_nodes 30 || warn "30s 内未生成 /dev/video*，请检查 USB 插拔"
    fi
    ok "节点: $(video_nodes)"
    if [ "${1:-}" != "--no-service" ]; then
        if stream_on; then
            as_root systemctl restart "$CROWSNEST_SVC" && ok "$CROWSNEST_SVC 已重启"
        else
            as_root systemctl start "$CROWSNEST_SVC" && ok "$CROWSNEST_SVC 已启动"
        fi
        # crowsnest 启动 ustreamer 需要 ~8s，等它就绪再返回（Klipper 宏 timeout 30s 够用）
        i=0
        while [ $i -lt 30 ]; do
            has_streamer && { ok "ustreamer 已就绪 (端口 $(crow_port))"; break; }
            sleep 0.5; i=$((i + 1))
        done
        [ $i -ge 30 ] && warn "30s 内 ustreamer 未启动，查: tail ~/printer_data/logs/crowsnest.log"
    fi
}

cmd_off() {
    soft=0; nosvc=0
    for a in "$@"; do
        case "$a" in
            --soft)    soft=1 ;;
            --no-service) nosvc=1 ;;
        esac
    done

    if [ "$soft" -eq 1 ]; then
        can_root || { no_root_hint; return 1; }
        info "停止推流（不动内核模块）..."
        as_root systemctl stop "$CROWSNEST_SVC" 2>/dev/null || true
        i=0
        while has_streamer && [ $i -lt 10 ]; do sleep 0.3; i=$((i + 1)); done
        has_streamer && as_root pkill -f "ustreamer.bin" 2>/dev/null
        ok "推流已停止，模块保持加载（摄像头不再采集）"
        return 0
    fi

    info "关闭摄像头（停止推流 + 卸载 uvcvideo）..."
    can_root || { no_root_hint; return 1; }
    if [ "$nosvc" -eq 0 ]; then
        as_root systemctl stop "$CROWSNEST_SVC" 2>/dev/null || true
        i=0
        while has_streamer && [ $i -lt 10 ]; do sleep 0.3; i=$((i + 1)); done
        has_streamer && { as_root pkill -f "ustreamer.bin" 2>/dev/null; sleep 1; }
    fi
    if ! mod_loaded; then ok "模块本来就没加载，已是关闭状态"; return 0; fi

    if ! as_root modprobe -r "$CAM_MOD" 2>/dev/null; then
        warn "模块仍被占用，尝试强制释放..."
        as_root fuser -k /dev/video0 >/dev/null 2>&1
        sleep 1
        as_root modprobe -r "$CAM_MOD" || die "卸载 $CAM_MOD 失败（可能有进程占用；用 'fuser -v /dev/video*' 查看）"
    fi
    sleep 0.3
    ok "已关闭: uvcvideo 已卸载，无 /dev/video* 节点"
    i=0
    while [ $i -lt 10 ]; do
        st="$(cam_pwr_state)"
        case "$st" in suspended*) break ;; esac
        sleep 0.5; i=$((i + 1))
    done
    info "USB 供电状态: $(cam_pwr_state)  （suspended = 已进入 USB 低功耗，基本不耗电）"
}

cmd_stream() {
    if [ "$1" = "on" ]; then cmd_on; else cmd_off --soft; fi
}

cmd_suspend() {
    can_root || { no_root_hint; return 1; }
    p="$(cam_port)" || die "找不到摄像头"
    d="$(usbdev "$p")/power"
    as_root sh -c "echo auto > $d/control && echo 1000 > $d/autosuspend_delay_ms" \
        || die "设置自动挂起失败（需要 root）"
    ok "已设置空闲 1s 自动挂起（无推流时 USB 断电）"
    info "当前状态: $(cat "$d/runtime_status")（有推流时不会挂起）"
}

cmd_resume() {
    can_root || { no_root_hint; return 1; }
    p="$(cam_port)" || die "找不到摄像头"
    d="$(usbdev "$p")/power"
    as_root sh -c "echo on > $d/control" || die "恢复失败"
    ok "已恢复供电管理（control=on）"
}

cmd_snapshot() {
    out="${1:-/tmp/camera-snap.png}"; size="${2:-1280x720}"
    first_node="$(ls /dev/video0 2>/dev/null || ls /dev/video* 2>/dev/null | head -1)"
    [ -n "$first_node" ] || { cmd_on; first_node="/dev/video0"; }

    restore=0
    if fuser "$first_node" >/dev/null 2>&1; then
        if can_root; then
            warn "设备被占用，先临时停推流..."
            as_root systemctl stop "$CROWSNEST_SVC" 2>/dev/null; restore=1
            sleep 1.5
        else
            warn "设备被 $CROWSNEST_SVC 占用且无 root 权限，无法抢占；先执行 '$0 stream-off'"
        fi
    fi

    tmp="$(mktemp /tmp/camXXXXXX.yuv)"
    if v4l2-ctl -d "$first_node" \
        --set-fmt-video="width=${size%x*},height=${size#*x},pixelformat=yuyv" \
        --stream-mmap=4 --stream-count=1 --stream-to="$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        ffmpeg -y -loglevel error -f rawvideo -pixel_format yuyv422 \
            -video_size "$size" -i "$tmp" "$out" 2>/dev/null \
            && ok "已保存 $out ($(du -h "$out" | cut -f1))" \
            || warn "已抓到 YUV，但转 PNG 失败（ffmpeg）：$tmp"
    else
        err "抓帧失败（设备忙？）"; rm -f "$tmp"
        [ "$restore" -eq 1 ] && as_root systemctl start "$CROWSNEST_SVC" 2>/dev/null
        return 1
    fi
    [ "$restore" -eq 1 ] && { as_root systemctl start "$CROWSNEST_SVC" 2>/dev/null; info "推流已恢复"; }
    rm -f "$tmp"
}

cmd_install() {
    info "安装免密 sudo 规则 -> $SUDOERS_FILE"
    can_root || { no_root_hint; return 1; }
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
# 由 camera.sh install 生成 —— 仅允许摄像头开关所需的具体命令
$(id -un) ALL=(root) NOPASSWD: /usr/sbin/modprobe $CAM_MOD, /usr/sbin/modprobe -r $CAM_MOD, /usr/bin/systemctl start $CROWSNEST_SVC, /usr/bin/systemctl stop $CROWSNEST_SVC, /usr/bin/systemctl restart $CROWSNEST_SVC, /usr/bin/fuser -k /dev/video0, /usr/bin/fuser -k /dev/video*, /usr/bin/pkill -f ustreamer.bin
EOF
    sudo install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE" || { rm -f "$tmp"; die "写入失败"; }
    rm -f "$tmp"
    as_root visudo -c -q -f "$SUDOERS_FILE" >/dev/null 2>&1 || { as_root rm -f "$SUDOERS_FILE"; die "sudoers 语法错误，已回滚"; }
    ok "完成。现在 Klipper/Mainsail 里的 CAMERA 宏可以直接用"
    info "别忘了把 A4__shell_command.cfg 里的 timeout: 2. 改成 timeout: 30."
}

cmd_boot() {
    can_root || { no_root_hint; return 1; }
    case "$1" in
        off)
            as_root sh -c "echo 'blacklist $CAM_MOD' > $BLACKLIST_FILE" \
                || die "需要 root：写 $BLACKLIST_FILE 失败"
            ok "已设置：下次开机不加载 $CAM_MOD（摄像头不会被识别）"
            warn "建议同时在 crowsnest.conf 里注释掉 [cam 1]，避免开机日志刷报错"
            ;;
        on)
            as_root rm -f "$BLACKLIST_FILE"
            ok "已取消开机屏蔽（重启后恢复）"
            ;;
        *) echo "用法: $0 boot on|off"; exit 1 ;;
    esac
}

cmd_reload() { cmd_off "$@"; sleep 1; cmd_on; }

cmd_detect() {
    if p="$(cam_port 2>/dev/null)"; then
        ok "端口: $p"; ok "型号: $(cam_desc)"; ok "已记录到 $PORT_FILE"
    else
        die "未检测到摄像头 (VID:PID=$CAM_VID:$CAM_PID)"
    fi
}

cmd_list() {
    echo "== USB 上的视频设备 =="
    lsusb | grep -iE "camera|webcam|video" || echo "  (无)"
    echo "== /dev 节点 =="
    video_nodes || true
    for d in /dev/video*; do
        [ -e "$d" ] || continue
        echo "  $d : $(v4l2-ctl -d "$d" --info 2>/dev/null | grep -m1 'Card type' | cut -d: -f2- | sed 's/^ *//')"
    done
    echo "== by-id =="
    ls -l /dev/v4l/by-id/ 2>/dev/null
}

usage() {
cat <<EOF
USB 摄像头开关 (camera.sh)

  status              查看状态
  on [--no-service]   开启（加载模块 + 拉起 crowsnest 推流）
  off [--soft]        关闭（卸载 uvcvideo，停止采集）；--soft 只停推流
  stream-on/off       stream-on = on，stream-off = off --soft
  suspend / resume    USB 自动挂起 / 唤醒（软断电）
  snapshot [out.png]  抓一张图（默认 /tmp/camera-snap.png）
  reload              关闭再开启
  boot off|on         开机是否加载模块
  detect              重新检测并记录端口
  list / list-all     列出摄像头 / 全部 USB 设备
  install             安装免密 sudo（Klipper 宏调用前需要做一次）
  help                本帮助

示例:
  $0 on && $0 snapshot      # 开机后确认能拍到
  $0 off                    # 打印时关摄像头省电
EOF
}

# ------------------------------------------------------------------ main --
case "${1:-help}" in
    on|enable|start)        shift; cmd_on "$@" ;;
    off|disable|stop)       shift; cmd_off "$@" ;;
    stream-on|streamon)     cmd_stream on ;;
    stream-off|streamoff)   cmd_stream off ;;
    suspend)                cmd_suspend ;;
    resume)                 cmd_resume ;;
    status|state)           cmd_status ;;
    snapshot|shot)          shift; cmd_snapshot "$@" ;;
    reload|restart)         shift; cmd_reload "$@" ;;
    boot)                   shift; cmd_boot "$@" ;;
    detect|scan)            cmd_detect ;;
    list)                   cmd_list ;;
    list-all)               echo "== 全部 USB 设备 =="; lsusb; echo; lsusb -t ;;
    install)                cmd_install ;;
    help|--help|-h)         usage ;;
    *) err "未知命令: $1"; echo; usage; exit 1 ;;
esac