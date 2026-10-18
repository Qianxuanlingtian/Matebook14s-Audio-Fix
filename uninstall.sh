#!/bin/bash
# MateBook 14s 音频修复 —— 卸载
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行: sudo $0" >&2; exit 1; }

echo "==> 停止并禁用服务"
systemctl stop huawei-audio-fix.service 2>/dev/null || true
systemctl disable huawei-audio-fix.service 2>/dev/null || true
systemctl disable huawei-audio-fix-resume.service 2>/dev/null || true

echo "==> 删除文件"
rm -f /etc/systemd/system/huawei-audio-fix.service
rm -f /etc/systemd/system/huawei-audio-fix-resume.service
rm -f /usr/local/bin/huawei-audio-fix.sh

systemctl daemon-reload
echo "卸载完成。声卡将回到系统默认(可能仍然无声)状态。"
