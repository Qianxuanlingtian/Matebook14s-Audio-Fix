#!/usr/bin/env bash
# MateBook 14s (HKD-WXX) 音频诊断脚本
# 用法: ./diagnose-audio.sh          (只读诊断)
#       ./diagnose-audio.sh --try    (诊断 + 尝试拉高 EAPD 让扬声器出声)
#
# 背景: Conexant CX11880 @ SOF 驱动, 扬声器引脚 0x17 报 NO_PRESENCE,
#       内核 autoconfig 把 0x17 当作 line_out 而非 speaker_out,
#       怀疑 EAPD/功放使能未真正拉起。Windows 下正常 -> 硬件无故障。
set -uo pipefail

CARD_ID=sofhdadsp
CODEC_HW=/dev/snd/hwC0D0
SPK_PIN=0x17     # 扬声器引脚 [Fixed] Speaker at Int Rear
HP_PIN=0x16      # 耳机引脚  [Jack] HP Out at Ext Left

hdr() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
bad() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m  ! %s\033[0m\n' "$*"; }

TRY=0
[[ "${1:-}" == "--try" ]] && TRY=1

hdr "1. 机器与内核"
echo "  机型:   $(cat /sys/class/dmi/id/product_name 2>/dev/null) / $(cat /sys/class/dmi/id/board_name 2>/dev/null)"
echo "  内核:   $(uname -r)"
echo "  驱动:   $(lspci -nnk 2>/dev/null | grep -A3 'Multimedia audio' | grep 'driver in use' | sed 's/.*: //')"

hdr "2. 声卡与配置文件"
echo "  声卡:   $(cat /proc/asound/card0/id 2>/dev/null)"
echo "  编解码: $(grep -m1 '^Codec:' /proc/asound/card0/codec#0 2>/dev/null | sed 's/Codec: //')"
if command -v pactl >/dev/null; then
  echo "  Profile: $(pactl list cards 2>/dev/null | grep -m1 'Active Profile' | sed 's/.*Active Profile: //')"
  echo "  默认输出: $(pactl get-default-sink 2>/dev/null)"
  echo "  音量:    $(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -m1 Volume)"
  echo "  静音:    $(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null)"
fi

hdr "3. 关键引脚状态 (对照 Windows 正常时的差异)"
for pin in "$SPK_PIN:扬声器" "$HP_PIN:耳机"; do
  p="${pin%%:*}"; label="${pin##*:}"
  echo "  --- $label ($p)"
  sed -n "/^Node $p /,/^Node /p" /proc/asound/card0/codec#0 2>/dev/null \
    | grep -E "Pin Default|Pin-ctls|EAPD|Amp-Out vals" | sed 's/^/      /'
done

hdr "4. 系统识别的输出引脚 (重点看 speaker_outs)"
journalctl -b -k --no-pager 2>/dev/null | grep -E "autoconfig for|speaker_outs|hp_outs|line_outs" | sed 's/.*kernel: /  /'

hdr "5. 是否存在 Jack 检测控件 (决定 UCM 能否自动切换)"
if grep -qE 'name="(Headphone Jack|Speaker Phantom Jack)"' /proc/asound/card0/codec#0 2>/dev/null; then
  ok "存在 Jack 控件"
else
  bad "缺少 Headphone Jack / Speaker Phantom Jack 控件"
  warn "UCM 的 HiFi-analog.conf 依赖这些控件做路由切换, 缺失会导致 Speaker 初始化分支走不到"
fi

hdr "6. 固件与拓扑"
journalctl -b -k --no-pager 2>/dev/null | grep -E "Firmware info|loading topology|Topology: ABI" | sed 's/.*kernel: /  /'

hdr "7. 内核报错"
ERRS=$(journalctl -b -k --no-pager 2>/dev/null | grep -iE "(sof|snd|hda).*(error|fail|timeout|cannot)" | head -20)
if [[ -z "$ERRS" ]]; then ok "无 SOF/HDA 相关报错"; else echo "$ERRS" | sed 's/.*kernel: /  /'; fi

hdr "结论"
cat <<'EOF'
  数据流能建立(stream=1)、功放寄存器未静音, 但无声 —— 说明信号到达了
  未上电的功放。根因是 CX11880 在本机上缺少 EAPD/GPIO 上电 quirk:
    - 0x17 引脚带 Misc = NO_PRESENCE (ACPI 未声明扬声器存在检测)
    - 内核 autoconfig 把 0x17 归为 line_out, speaker_outs=0
    - 无 Jack 控件, UCM 无法正确初始化 Speaker 通路
EOF

if [[ $TRY -eq 1 ]]; then
  hdr "8. 尝试强制拉高 EAPD (需要 root)"
  if [[ $EUID -ne 0 ]]; then
    bad "请用 sudo 运行: sudo $0 --try"
    exit 1
  fi
  if [[ ! -e "$CODEC_HW" ]]; then
    bad "$CODEC_HW 不存在, 请确认声卡编号"
    exit 1
  fi

  echo "  [1/3] $HP_PIN EAPD on"
  hda-verb "$CODEC_HW" "$HP_PIN" SET_EAPD_BTLENABLE 0x02 2>&1 | sed 's/^/      /'

  echo "  [2/3] $SPK_PIN EAPD on"
  hda-verb "$CODEC_HW" "$SPK_PIN" SET_EAPD_BTLENABLE 0x02 2>&1 | sed 's/^/      /'

  echo "  [3/3] $SPK_PIN 强制 OUT 使能"
  hda-verb "$CODEC_HW" "$SPK_PIN" SET_PIN_WIDGET_CONTROL 0x40 2>&1 | sed 's/^/      /'

  echo
  echo "  现在播放一个测试音, 仔细听扬声器:"
  if command -v paplay >/dev/null && [[ -f /tmp/t.wav ]]; then
    paplay /tmp/t.wav && ok "已播放 /tmp/t.wav"
  else
    warn "无 /tmp/t.wav, 请手动播放任意音频测试"
  fi
  echo
  echo "  >>> 如果这次出声了: 把上面 3 条 hda-verb 做成开机服务即可固化 <<<"
  echo "  >>> 如果还是没声: 说明功放由主板 GPIO 经 ACPI 控制, 需要 DSDT 层面的 quirk <<<"
fi
