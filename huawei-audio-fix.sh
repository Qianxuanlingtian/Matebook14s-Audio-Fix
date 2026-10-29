#!/bin/bash
# MateBook 14s (HKD-WXX / HKD-WXX-PCB-B1) 音频切换守护进程
# 适用于 kernel 7.2.11+ (sof-audio-pci-intel-tgl + Conexant CX11880)
#
# ============================================================================
# 本机音频机制 —— 全部来自 2026-10-29 的隔离实测，非推测
# ============================================================================
#
# 节点拓扑:
#   0x10 [Audio Output]   DAC  —— 耳机与扬声器的【总闸】
#   0x11 [Audio Output]   DAC  —— 实测【与输出无关】，怎么改都不影响声音
#   0x16 [Pin Complex]    耳机插孔（[Jack] HP Out at Ext Left，带 Detect）
#   0x17 [Pin Complex]    内置扬声器（[Fixed] Speaker at Int Rear，只有 EAPD）
#
# 实测确认的两条规律:
#
#   1) DAC 0x10 的 mute 位是【总闸】，耳机和扬声器共用它：
#        0x10 = 0x4a  (mute=0, gain=74)  ->  有声音
#        0x10 = 0xbb  (mute=1, gain=59)  ->  耳机、扬声器【一起】无声
#
#   2) 扬声器引脚 0x17 的开关【只由 EAPD 控制】，Pin-ctls 对它无效：
#        0x17 EAPD = 0x2  ->  扬声器响
#        0x17 EAPD = 0x0  ->  扬声器静音，耳机不受影响
#
#      注意: 音频引脚(0x04)的 Pin-ctls 写入 0x00/0x40 对 0x17【完全没有作用】，
#            0x17 的 Pincap 只有 "OUT EAPD"，没有 OUT/HP 位，所以只能靠 EAPD 关。
#
# 由此得到唯一正确的切换方案:
#
#   扬声器模式（未插耳机）:  0x10 = 0x4a (总闸开)  +  0x17 EAPD = 0x2 (分闸开)
#   耳机模式（已插耳机）  :  0x10 = 0x4a (总闸开)  +  0x17 EAPD = 0x0 (分闸关)
#
#   【关键】0x10 在任何模式下都必须保持 0x4a。插耳机时把 0x10 静音，会把耳机
#   本身也弄哑（这是上一版脚本失败的根因）。
#
# ============================================================================
# 内核缺了什么 —— 本脚本要补的就是这两点
# ============================================================================
#
#   插耳机时:  内核会把 0x17 EAPD 置 0x2（保持扬声器开），且不做任何关闭动作。
#              本脚本需要主动关掉 0x17 EAPD，否则扬声器与耳机同时出声。
#
#   拔耳机时:  内核会切回 Speaker profile、把 0x17 EAPD 置 0x2，
#              但【不会解除 0x10 的静音】(实测停在 0xbb)，所以扬声器不响。
#              本脚本需要把 0x10 改回 0x4a。
#
#   其余一切（profile、default-sink、0x16 连接、Pin-ctls、0x11）都交给内核，
#   脚本【完全不碰】—— 实测中所有对这些项的写入要么无效，要么破坏耳机通路。
#
# ============================================================================
set -uo pipefail

# 可覆盖的环境变量（测试用）
CODEC_HW="${CODEC_HW:-/dev/snd/hwC0D0}"
DAC_NODE="${DAC_NODE:-0x10}"
SPK_PIN="${SPK_PIN:-0x17}"

# verb 0x300 = SET_AMP_GAIN_MUTE，作用于 0x10 的输出功放
#   0xb04a: bit15=输出功放, bit13/12=左右声道, bit7 mute=0, bit6-0 gain=0x4a(74, 0dB)
DAC_AMP_ON=0xb04a
DAC_TARGET_GAIN=0x4a

# verb 0x70C = SET_EAPD_BTL_ENABLE（只作用于 0x17 这类没有 OUT/HP 位的引脚）
EAPD_ON=0x0002
EAPD_OFF=0x0000

POLL_INTERVAL=0.5      # 轮询间隔（秒）

log() { echo "[$(date '+%F %T')] $*"; }

# ---- 从 /proc 读取某节点的第一个 Amp-Out 值，输出形如 "0x4a" ----
read_amp_out() {
    local node="$1"
    awk -v n="$node" '
        $1=="Node" && $2==n { inside=1; next }
        inside && $1=="Node" { exit }
        inside && /Amp-Out vals:/ {
            if (match($0, /\[0x[0-9a-fA-F]+/)) {
                print substr($0, RSTART+1, RLENGTH-1);
                exit
            }
        }
    ' /proc/asound/card0/codec#0 2>/dev/null
}

# ---- 从 /proc 读取某节点的 EAPD 值，输出形如 "0x2" ----
read_eapd() {
    local node="$1"
    awk -v n="$node" '
        $1=="Node" && $2==n { inside=1; next }
        inside && $1=="Node" { exit }
        inside && /EAPD 0x/ {
            if (match($0, /EAPD (0x[0-9a-fA-F]+)/, a)) {
                print a[1];
                exit
            }
        }
    ' /proc/asound/card0/codec#0 2>/dev/null
}

# ---- 总闸 0x10 是否已开（不静音 且 增益满） ----
dac_ok() {
    local v
    v="$(read_amp_out "$DAC_NODE")"
    [[ -z "$v" ]] && return 1
    (( (v >> 7 & 1) == 0 && (v & 0x7f) == DAC_TARGET_GAIN ))
}

# ---- 打开总闸 0x10 ----
dac_on() {
    hda-verb "$CODEC_HW" "$DAC_NODE" 0x300 "$DAC_AMP_ON" >/dev/null 2>&1
}

# ---- 扬声器分闸 0x17 EAPD 是否处于期望状态 ----
# 参数: "on" | "off"
eapd_ok() {
    local want v
    want="$1"
    v="$(read_eapd "$SPK_PIN")"
    [[ -z "$v" ]] && return 1
    if [[ "$want" == "on" ]]; then (( (v & 0x2) != 0 )); else (( (v & 0x2) == 0 )); fi
}

# ---- 设置扬声器分闸 0x17 EAPD ----
# 参数: "on" | "off"
eapd_set() {
    local val
    [[ "$1" == "on" ]] && val="$EAPD_ON" || val="$EAPD_OFF"
    hda-verb "$CODEC_HW" "$SPK_PIN" 0x70C "$val" >/dev/null 2>&1
}

# ============================================================================
# 耳机插拔检测
#   /dev/input/eventN，name 含 "Headphone"（实测为 "sof-hda-dsp Headphone"）
#   开关位 SW_HEADPHONE_INSERT = bit2 (值 4)
#   read_jack 退出码: 0 = 未插入, 1 = 已插入, 2 = 无法读取
# ============================================================================
find_jack_event() {
    local d ev
    for d in /sys/class/input/input*/; do
        [[ -r "$d/name" ]] || continue
        [[ "$(cat "$d/name" 2>/dev/null)" == *Headphone* ]] || continue
        ev=$(basename "$(ls -d "$d"event* 2>/dev/null | head -1)" 2>/dev/null)
        [[ -n "$ev" && -e "/dev/input/$ev" ]] && { echo "/dev/input/$ev"; return 0; }
    done
    return 1
}

read_jack() {
    python3 - "$1" 4 <<'PY' 2>/dev/null
import sys, os, fcntl, struct
EVIOCGSW = 0x8008451b
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
except OSError:
    sys.exit(2)
try:
    sw = struct.unpack('Q', fcntl.ioctl(fd, EVIOCGSW, b'\x00' * 8))[0]
finally:
    os.close(fd)
sys.exit(1 if (sw & int(sys.argv[2])) else 0)
PY
}

# ============================================================================
# 主循环
# ============================================================================
main() {
    log "服务启动 (DAC $DAC_NODE 保持不静音; 扬声器由 $SPK_PIN EAPD 控制)"
    sleep 2

    local jackdev="" hp rc last_mode=""

    while true; do
        [[ -n "$jackdev" && -e "$jackdev" ]] || jackdev="$(find_jack_event)" || jackdev=""

        hp=0
        if [[ -n "$jackdev" ]]; then
            read_jack "$jackdev"; rc=$?
            [[ $rc -eq 1 ]] && hp=1
            # 读取失败(rc=2)时按"未插耳机"处理，保证扬声器可用
        fi

        # ---- 1) 总闸: 任何模式下 0x10 都必须不静音 ----
        if ! dac_ok; then
            dac_on
            sleep 0.1
        fi

        # ---- 2) 分闸: 按耳机状态设置 0x17 EAPD ----
        if [[ $hp -eq 0 ]]; then
            # 扬声器模式：扬声器要响
            if ! eapd_ok on; then
                eapd_set on
            fi
            if [[ "$last_mode" != "speaker" ]]; then
                log "扬声器模式: DAC $(read_amp_out "$DAC_NODE") / EAPD $(read_eapd "$SPK_PIN")"
                last_mode="speaker"
            fi
        else
            # 耳机模式：关掉扬声器
            if ! eapd_ok off; then
                eapd_set off
            fi
            if [[ "$last_mode" != "headphone" ]]; then
                log "耳机模式: DAC $(read_amp_out "$DAC_NODE") / EAPD $(read_eapd "$SPK_PIN")"
                last_mode="headphone"
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

main
