#!/bin/bash
# MateBook 14s 音频修复 —— 一键安装
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=/usr/local/bin/huawei-audio-fix.sh
SERVICE=/etc/systemd/system/huawei-audio-fix.service
RESUME=/etc/systemd/system/huawei-audio-fix-resume.service

die() { echo "错误: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 sudo 运行: sudo $0"

echo "==> 检查依赖"
for c in hda-verb amixer pactl; do
    command -v "$c" >/dev/null || die "缺少 $c, 请先安装: pacman -S alsa-tools alsa-utils"
done
echo "    hda-verb ✓  amixer ✓  pactl ✓"

[[ -e /dev/snd/hwC0D0 ]] || die "/dev/snd/hwC0D0 不存在, 请确认声卡编号"
echo "    /dev/snd/hwC0D0 ✓"

# 若存在旧的错误版本(带周期性重应用), 先停止避免干扰
systemctl stop huawei-audio-fix.service 2>/dev/null || true

echo "==> 安装脚本到 $TARGET"
install -m 755 "$SCRIPT_DIR/huawei-audio-fix.sh" "$TARGET"

echo "==> 安装 systemd 服务"
install -m 644 "$SCRIPT_DIR/huawei-audio-fix.service" "$SERVICE"
install -m 644 "$SCRIPT_DIR/huawei-audio-fix-resume.service" "$RESUME"
systemctl daemon-reload
systemctl enable huawei-audio-fix.service
systemctl enable huawei-audio-fix-resume.service
systemctl restart huawei-audio-fix.service

sleep 3
echo
echo "==> 服务状态"
systemctl status huawei-audio-fix.service --no-pager -l | head -15

echo
echo "==> 最近日志 (应只出现一次切换记录)"
journalctl -u huawei-audio-fix.service --no-pager -n 10

cat <<'EOF'

安装完成。常用命令:
  systemctl status  huawei-audio-fix
  systemctl restart huawei-audio-fix
  journalctl -u huawei-audio-fix -f

验证要点:
  * 不插耳机 -> 扬声器有声
  * 插入耳机 -> 耳机有声, 且扬声器静音
  * 日志中切换记录不应每 30 秒重复出现

卸载:  sudo ./uninstall.sh
EOF
