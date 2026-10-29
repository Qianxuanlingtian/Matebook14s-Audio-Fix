#!/bin/bash
# MateBook 14s (HKD-WXX) 音频守护进程
#
# 硬件机制 (经本机寄存器实测确认, 非推测):
#
#   数据流:  PipeWire -> DAC 0x11 (两个输出共用这一个 DAC)
#   输出脚:  0x16 = 耳机插孔 [Jack] HP Out at Ext Left
#            0x17 = 内置扬声器 [Fixed] Speaker at Int Rear
#
#   关键结论:
#     1) 无论哪个 profile, 数据流都在 DAC 0x11 (stream=1), 0x10 恒为空。
#        (早期误以为 0x10 是耳机DAC —— 实测 stream 始终为 0, 不参与输出)
#     2) 切换输出的真正开关是【引脚的 EAPD】(verb 0x70C), 不是 Pin-ctls。
#        已实测: 0x17 Pin-ctls=0x00 时扬声器仍响, 而 EAPD=0x0 时才静音。
#     3) 切到 Headphones profile 后 UCM 移除 'Speaker Playback Switch' 控件,
#        但 DAC 0x11 的硬件静音位会保持置位, 且再无控件可解除 ->
#        必须用 hda-verb 0x11 0x300 0xb04a 显式解除, 否则【全程无声】。
#
#   最终有效组合 (已实测出声):
#     耳机:  0x11 amp=0xb04a(静音解除+满增益) + 0x16 EAPD=0x2 + 0x17 EAPD=0x0
#     扬声器: 0x11 amp=0xb04a(静音解除+满增益) + 0x16 EAPD=0x0 + 0x17 EAPD=0x2
#
# 插拔检测: /dev/input/eventN (name="sof-hda-dsp Headphone") 的
#           SW_HEADPHONE_INSERT 位 (bit2=4), 由 codec unsolicited 事件驱动。
#           (不用 amixer 'Headphone' 控件 —— 那是输出开关, 非插拔传感器)
set -uo pipefail

CODEC_HW="${CODEC_HW:-/dev/snd/hwC0D0}"
XUSER="${XUSER:-zhou_}"
XUID="${XUID:-1000}"

CARD=alsa_card.pci-0000_00_1f.3-platform-skl_hda_dsp_generic
PROFILE_SPEAKER="HiFi (HDMI1, HDMI2, HDMI3, Mic1, Mic2, Speaker)"
PROFILE_HEADPHONES="HiFi (HDMI1, HDMI2, HDMI3, Headphones, Mic1, Mic2)"

log() { echo "[$(date '+%F %T')] $*"; }

as_user() {
    sudo -u "$XUSER" XDG_RUNTIME_DIR="/run/user/$XUID" "$@" 2>/dev/null
}

find_sink() {
    as_user pactl list sinks short \
        | awk -v k="$1" '$2 ~ ("HiFi__" k "__sink") {print $2; exit}'
}

# DAC 0x11 功放: 解除静音 + 增益拉满。
#
# 这一条同时承担【两个职责】, 不可只当作"解除静音":
#   1. 清除 mute 位 (bit7) —— 否则全程无声
#   2. 设置 gain (bit6-0)  —— 这是【硬件音量】, 直接决定音量上限
#
# 寄存器格式 (verb 0x300, SET_AMP_GAIN_MUTE):
#   bit15    = 1  输出功放
#   bit14    = 0  index 0
#   bit13/12 = 1  左/右声道
#   bit7     = mute
#   bit6-0   = gain    该 codec 有效范围 0..74 (0x4a), dBscale -74dB..0dB
#
# => 0xb04a = 输出功放 + 左右声道 + 未静音 + gain=74(满值, 0dB)
#
# 历史教训: 早期版本硬编码 0xb033 (gain=51 -> -23dB), 导致音量明显偏小。
#           51 只是当时从寄存器抄来的值, 并非音量上限。
AMP_UNMUTE_MAX=0xb04a    # gain=74 (0x4a) = 0dB = 最大

unmute_dac() {
    hda-verb "$CODEC_HW" 0x11 0x300 "$AMP_UNMUTE_MAX" >/dev/null 2>&1
}

set_eapd() {
    hda-verb "$CODEC_HW" "$1" 0x70C "$2" >/dev/null 2>&1
}

# 连接选择: 让引脚 0x16 指向 DAC 0x11 (唯一有数据流的 DAC)。
#
# 这一条【必须存在】。codec 复位(冷启动)后 0x16 默认指向 DAC 0x10,
# 而 0x10 恒为静音(amp=0xbb)且通常无流 —— 缺这一条会导致
# 【运行时正常、重启后无声】(已实测踩中)。
set_conn() {
    hda-verb "$CODEC_HW" 0x16 0x701 0x0001 >/dev/null 2>&1
}

# 等待 PipeWire / pactl 真正可用。
# 服务可能在 PipeWire 就绪前启动, 此时 set-card-profile 会"成功"但 sink 不会出现,
# 导致 switch_profile 轮询耗尽、default sink 设不上 -> 开机后无声。
# (已实测踩中: 开机后首次切换轮询 21 次全部失败)
wait_for_pipewire() {
    local i
    for i in $(seq 1 150); do      # 最多等 30 秒
        as_user pactl info >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    return 1
}

# 切 profile 并等待目标 sink 出现
switch_profile() {
    local profile="$1" want="$2" i
    as_user pactl set-card-profile "$CARD" "$profile"
    for i in $(seq 1 50); do       # 最多等 10 秒
        [[ -n "$(find_sink "$want")" ]] && return 0
        # 若 PipeWire 中途重启, 重新等待
        as_user pactl info >/dev/null 2>&1 || wait_for_pipewire
        sleep 0.2
    done
    log "警告: $want sink 未在超时内出现"
    return 1
}

# 只写 codec 寄存器 (不含 profile/sink 操作), 可安全重复调用
apply_codec() {
    local want="$1"
    if [[ "$want" == Speaker ]]; then
        set_eapd 0x16 0x0000        # 关耳机
        set_eapd 0x17 0x0002        # 开扬声器
    else
        set_eapd 0x16 0x0002        # 开耳机
        set_eapd 0x17 0x0000        # 关扬声器
    fi
    set_conn                        # 0x16 -> DAC 0x11
    unmute_dac                      # 解除 DAC 0x11 静音
}

# 读回当前实际路由状态, 判断 codec 是否仍符合目标模式。
#
# 注意: 不要用 `grep -A2 'Connection:' | tail -1`, 那样会取到
# awk 范围多带的 "Node 0x17 ..." 行。必须只匹配连接值那一行。
conn_on_11() {
    awk '/^Node 0x16 /,/^Node 0x17 \[/' /proc/asound/card0/codec#0 2>/dev/null \
        | grep -E '^[[:space:]]+0x1[01]' | head -1 | grep -q '0x11\*'
}

# 校验 DAC 0x11 的静音位与增益是否达到要求。
# 只检查"未静音"是不够的 —— 增益被压低同样会导致音量偏小,
# 且这种故障不会让声音完全消失, 容易被忽视。
dac_amp_ok() {
    local v
    v=$(awk '/^Node 0x11 /,/^Node 0x12 /' /proc/asound/card0/codec#0 2>/dev/null \
        | grep -oP 'Amp-Out vals:\s+\[0x\K[0-9a-fA-F]+' | head -1)
    [[ -z "$v" ]] && return 1
    # 要求: mute 位为 0 且 gain == 74
    (( (0x$v >> 7 & 1) == 0 && (0x$v & 0x7f) == 0x4a ))
}

# 返回 0 表示切换成功
apply_output() {
    local want="$1" sink ok=0

    if [[ "$want" == Speaker ]]; then
        switch_profile "$PROFILE_SPEAKER" Speaker || ok=1
    else
        switch_profile "$PROFILE_HEADPHONES" Headphones || ok=1
    fi
    sink="$(find_sink "$want")"
    if [[ -n "$sink" ]]; then
        as_user pactl set-default-sink "$sink" || ok=1
    else
        ok=1
    fi
    # codec 写入放在 profile/sink 操作【之后】: 切 profile 会重置 codec。
    apply_codec "$want"
    return $ok
}

# 校验两个引脚的 EAPD 是否与目标模式一致
eapd_is() {
    local want="$1" hp spk
    hp=$(awk '/^Node 0x16 /,/^Node 0x17 \[/' /proc/asound/card0/codec#0 2>/dev/null \
         | grep -oP 'EAPD 0x\K\w+' | head -1)
    spk=$(awk '/^Node 0x17 \[/,/^Node 0x18 /' /proc/asound/card0/codec#0 2>/dev/null \
         | grep -oP 'EAPD 0x\K\w+' | head -1)
    if [[ "$want" == Speaker ]]; then
        [[ "$hp" == "0" && "$spk" == "2" ]]
    else
        [[ "$hp" == "2" && "$spk" == "0" ]]
    fi
}

detect_card() {
    awk 'NR==1 && $1 ~ /^[0-9]+$/ {print $1; exit}' /proc/asound/cards 2>/dev/null
}

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

# 0 = 未插入, 1 = 已插入, 2 = 读取失败
read_jack() {
    python3 - "$1" 4 <<'PY' 2>/dev/null
import sys, os, fcntl, struct
dev, bit = sys.argv[1], int(sys.argv[2])
EVIOCGSW = 0x8008451b
try:
    fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
except OSError:
    sys.exit(2)
try:
    sw = struct.unpack('Q', fcntl.ioctl(fd, EVIOCGSW, b'\x00'*8))[0]
finally:
    os.close(fd)
sys.exit(1 if (sw & bit) else 0)
PY
}

# 回读寄存器验证切换结果
verify() {
    local hp spk
    hp=$(awk '/^Node 0x16 /,/^Node 0x17 /' /proc/asound/card0/codec#0 2>/dev/null \
         | grep -oP 'EAPD 0x\K\w+' | head -1)
    spk=$(awk '/^Node 0x17 /,/^Node 0x18 /' /proc/asound/card0/codec#0 2>/dev/null \
         | grep -oP 'EAPD 0x\K\w+' | head -1)
    echo "hp_eapd=0x${hp:-?} spk_eapd=0x${spk:-?}"
}

main() {
    log "服务启动, 等待 PipeWire 就绪..."
    wait_for_pipewire || log "警告: PipeWire 等待超时, 仍继续尝试"
    sleep 1

    local jackdev="" old=0 status rc name want retry mode

    while true; do
        [[ -n "$jackdev" && -e "$jackdev" ]] || jackdev="$(find_jack_event)" || jackdev=""
        if [[ -z "$jackdev" ]]; then sleep 2; continue; fi

        read_jack "$jackdev"; rc=$?
        if   [[ $rc -eq 0 ]]; then status=1
        elif [[ $rc -eq 1 ]]; then status=2
        else sleep 1; continue
        fi

        if [[ $status -eq 1 ]]; then want=Speaker;    name="扬声器 (耳机未插)"
        else                         want=Headphones; name="耳机 (已插入)"
        fi

        if [[ $status -ne $old ]]; then
            # 插拔变化 -> 完整切换 (切 profile + 设 sink + 写 codec)
            retry=0
            until apply_output "$want"; do
                retry=$((retry+1))
                if (( retry >= 5 )); then
                    log "错误: 切到$name 连续失败 $retry 次"
                    break
                fi
                log "重试切到$name (第 $retry 次)"
                sleep 2
            done
            if (( retry < 5 )); then
                log "切到$name $(verify)"
                old=$status
            fi
        else
            # ---- 持续自愈 ----
            # 不做任何"时间窗"假设, 而是每轮都校验 codec 是否符合目标模式。
            # 无论 codec 因何原因(启动收尾/UCM 重配/挂起恢复)被重置,
            # 都会在 0.5 秒内被自动纠正。
            if ! (conn_on_11 && eapd_is "$want" && dac_amp_ok); then
                log "检测到 codec 状态被重置, 重新应用 ($name)"
                apply_codec "$want"
            fi
        fi

        sleep 0.5
    done
}

main
