# MateBook 14s (Arch Linux) 音频修复配置文档

> 脚本参考引用自 [Smoren/huawei-ubuntu-sound-fix](https://github.com/Smoren/huawei-ubuntu-sound-fix.git)

## 1. 环境与问题概述

| 项目   | 内容                                                    |
| ------ | ------------------------------------------------------- |
| 设备   | 华为 MateBook 14s                                       |
| 系统   | Arch Linux                                              |
| 桌面   | Niri + DMS (DankMaterialShell)                          |
| 音频栈 | PipeWire 1.6.10 + WirePlumber 0.5+                      |
| 声卡   | `sof-hda-dsp`（`skl_hda_dsp_generic`，Conexant CX8070） |

**原始症状**：插耳机后声音仍从扬声器输出；系统音量条超过约 10% 后扬声器响度不再增加；拔耳机后扬声器音量变轻，需手动把 `Speaker` 拉到 100% 才恢复。

**根本原因**：

- 该声卡上耳机与扬声器的内部 widget 存在交叉耦合（`0x16` / `0x17`），需要直接写 `hda-verb` 才能正确切换。
- `Speaker` 滑块对扬声器响度几乎无效，真正的增益级是 `Headphone` 滑块，但 PipeWire 默认把系统音量映射到了失效的 `Speaker` 控件上。

**解决方案组合**：

1. WirePlumber 启用 `soft-mixer`，让软件音量接管响度控制。
2. 守护脚本在每次插拔时用 `hda-verb` 切换硬件端口，并把 `Speaker` / `Headphone` 硬件增益锁定在 100%。
3. 系统级 systemd 服务以 root 运行脚本，通过 `su - zhou_` 降级执行 `pactl` 切换 PipeWire 端口。

------

## 2. 文件清单

| 文件             | 路径                                                         | 作用                                  |
| ---------------- | ------------------------------------------------------------ | ------------------------------------- |
| WirePlumber 配置 | `~/.config/wireplumber/wireplumber.conf.d/51-soft-mixer.conf` | 启用软件音量，忽略硬件 dB 映射        |
| 守护脚本         | `/usr/local/bin/huawei-soundcard-headphones-monitor.sh`      | 监听耳机插拔，切换硬件端口并锁定增益  |
| systemd 服务     | `/etc/systemd/system/huawei-soundcard-headphones-monitor.service` | 开机以 root 启动守护脚本              |
| ALSA 状态        | `/var/lib/alsa/asound.state`                                 | 由 `alsactl store` 保存的硬件初始状态 |

------

## 3. WirePlumber 配置

**路径**：`~/.config/wireplumber/wireplumber.conf.d/51-soft-mixer.conf`

```json
monitor.alsa.rules = [
  {
    matches = [
      {
        device.name = "alsa_card.pci-0000_00_1f.3-platform-skl_hda_dsp_generic"
      }
    ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
        api.alsa.ignore-dB = true
        api.alsa.enable-hw-volume = false
      }
    }
  }
]
```



**说明**：

- 用 `device.name` 匹配整张声卡，而不是匹配单个 Sink 节点。
- `soft-mixer = true` 让 PipeWire 绕过硬件混音器的音量控制。
- `ignore-dB = true` 忽略驱动上报的 dB 缩放，使音量条线性可控。
- `enable-hw-volume = false` 彻底禁用硬件音量路径。
- 文件名以 `51-` 开头，确保在默认配置之后加载。

------

## 4. 守护脚本

**路径**：`/usr/local/bin/huawei-soundcard-headphones-monitor.sh`
**权限**：`755`，属主 `root:root`

```bash
#!/bin/bash
#set -e

# [COMMENTS]
#
# Looks like there is some weird hardware design, because from my prospective, the interesting widgets are:
# 0x01 - Audio Function Group
# 0x10 - Headphones DAC (really both devices connected here)
# 0x11 - Speaker DAC
# 0x16 - Headphones Jack
# 0x17 - Internal Speaker
#
# And:
#
# widgets 0x16 and 0x17 simply should be connected to different DACs 0x10 and 0x11, but Internal Speaker 0x17 ignores the connection select command and use the value from Headphones Jack 0x16.
# Headphone Jack 0x16 is controlled with some weird stuff so it should be enabled with GPIO commands for Audio Group 0x01.
# Internal Speaker 0x17 is coupled with Headphone Jack 0x16 so it should be explicitly disabled with EAPD/BTL Enable command.
#

# ensures script can run only once at a time
pidof -o %PPID -x $0 >/dev/null && echo "Script $0 already running" && exit 1

function move_output() {
   hda-verb /dev/snd/hwC0D0 0x16 0x701 "$@" > /dev/null 2> /dev/null
}

function move_output_to_speaker() {
    move_output 0x0001
}

function move_output_to_headphones() {
    move_output 0x0000
}

function switch_to_speaker() {
    move_output_to_speaker

    # enable speaker
    hda-verb /dev/snd/hwC0D0 0x17 0x70C 0x0002 > /dev/null 2>&1 || true

    # disable headphones
    hda-verb /dev/snd/hwC0D0 0x1 0x715 0x2 > /dev/null 2>&1 || true

    # 软件音量模式下，硬件增益级固定为 100%
    amixer -c"${card_index}" sset Speaker 100% unmute > /dev/null 2>&1 || true
    amixer -c"${card_index}" sset Headphone 100% unmute > /dev/null 2>&1 || true
}

function switch_to_headphones() {
    move_output_to_headphones

    # disable speaker
    hda-verb /dev/snd/hwC0D0 0x17 0x70C 0x0000 > /dev/null 2>&1 || true

    # pin output mode
    hda-verb /dev/snd/hwC0D0 0x1 0x717 0x2 > /dev/null 2>&1 || true

    # pin enable
    hda-verb /dev/snd/hwC0D0 0x1 0x716 0x2 > /dev/null 2>&1 || true

    # clear pin value
    hda-verb /dev/snd/hwC0D0 0x1 0x715 0x0 > /dev/null 2>&1 || true

    # 软件音量模式下，硬件增益级固定为 100%
    amixer -c"${card_index}" sset Speaker 100% unmute > /dev/null 2>&1 || true
    amixer -c"${card_index}" sset Headphone 100% unmute > /dev/null 2>&1 || true

    # 切换 PipeWire 端口到耳机（降级为用户身份执行）
    su - zhou_ -c 'pactl set-sink-port alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Headphones__sink "[Out] Headphones"' 2>/dev/null || true
}

function get_sound_card_index() {
    card_index=$(cat /proc/asound/cards | grep sof-hda-dsp | head -n1 | grep -Eo "^\s*[0-9]+")
    card_index="${card_index#"${card_index%%[![:space:]]*}"}"
    echo $card_index
}

sleep 2

card_index=$(get_sound_card_index)
if [ -z "$card_index" ]; then
    echo "sof-hda-dsp card is not found in /proc/asound/cards"
    exit 1
fi

# 用 numid=14 (Headphone Jack) 判断物理插拔
# values=off 表示拔出，values=on 表示插入
get_jack_state() {
    amixer -c"${card_index}" cget numid=14 2>/dev/null \
        | grep '^ *: values=' \
        | grep -o 'values=on\|values=off' \
        | cut -d= -f2
}

old_status=0

while true; do
    jack_state=$(get_jack_state)

    if [ "$jack_state" = "off" ]; then
        status=1
    elif [ "$jack_state" = "on" ]; then
        status=2
    else
        sleep 0.5
        continue
    fi

    if [ ${status} -ne ${old_status} ]; then
        case "${status}" in
            1)
                message="Headphones disconnected"
                switch_to_speaker
                ;;
            2)
                message="Headphones connected"
                switch_to_headphones
                ;;
        esac
        echo "${message}"
        old_status=$status
    fi

    sleep 0.3
done
```



**关键点说明**：

- `set -e` 已注释，守护循环需要容错。
- `hda-verb` 仍硬编码 `/dev/snd/hwC0D0`（当前声卡为 card 0；若索引变化需同步修改）。
- `get_jack_state` 只匹配 `: values=` 行，避免误匹配 `type=BOOLEAN` 那行的 `values=1`。
- `su - zhou_` 中的用户名需与你的实际登录用户一致。
- `switch_to_speaker` 和 `switch_to_headphones` 都会把 `Speaker` / `Headphone` 锁定到 100%，这是解决“拔耳机后变轻”的关键。

------

## 5. systemd 服务

**路径**：`/etc/systemd/system/huawei-soundcard-headphones-monitor.service`

```ini
[Unit]
Description=Huawei soundcard headphones monitor

[Service]
ExecStart=/usr/local/bin/huawei-soundcard-headphones-monitor.sh
Restart=always
RestartSec=3s
User=root

[Install]
WantedBy=multi-user.target
```



**说明**：

- 必须是**系统级**服务（`User=root`），因为 `hda-verb` 需要写 `/dev/snd/hwC0D0`。
- `pactl` 通过 `su - zhou_` 降级到用户会话执行。
- 不要用 `systemctl --user` 启用此服务，否则 `hda-verb` 会因权限不足失败。

------

## 6. 完整部署步骤（从零复现）

```bash
# 1. 写入 WirePlumber 配置
mkdir -p ~/.config/wireplumber/wireplumber.conf.d/
cat > ~/.config/wireplumber/wireplumber.conf.d/51-soft-mixer.conf <<'EOF'
monitor.alsa.rules = [
  {
    matches = [
      {
        device.name = "alsa_card.pci-0000_00_1f.3-platform-skl_hda_dsp_generic"
      }
    ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
        api.alsa.ignore-dB = true
        api.alsa.enable-hw-volume = false
      }
    }
  }
]
EOF

# 2. 写入守护脚本
sudo tee /usr/local/bin/huawei-soundcard-headphones-monitor.sh > /dev/null <<'SCRIPT'
# （粘贴第 4 节的完整脚本内容）
SCRIPT
sudo chmod 755 /usr/local/bin/huawei-soundcard-headphones-monitor.sh

# 3. 写入 systemd 服务
sudo tee /etc/systemd/system/huawei-soundcard-headphones-monitor.service > /dev/null <<'UNIT'
[Unit]
Description=Huawei soundcard headphones monitor

[Service]
ExecStart=/usr/local/bin/huawei-soundcard-headphones-monitor.sh
Restart=always
RestartSec=3s
User=root

[Install]
WantedBy=multi-user.target
UNIT

# 4. 手动把硬件增益拉到 100% 并保存 ALSA 状态
amixer -c0 sset Speaker 100% unmute
amixer -c0 sset Headphone 100% unmute
sudo alsactl store

# 5. 重启音频栈
systemctl --user restart wireplumber pipewire pipewire-pulse

# 6. 启动并启用服务
sudo systemctl daemon-reload
sudo systemctl enable --now huawei-soundcard-headphones-monitor.service

# 7. 验证
sudo journalctl -u huawei-soundcard-headphones-monitor.service -f
# 插拔耳机，应看到 Headphones connected / disconnected
```



------

## 7. 更新后的自检清单

以下包更新并重启后，建议花一分钟跑一遍：

- 内核（`linux` / `linux-lts`）
- `alsa-ucm-conf`
- `alsa-lib`
- `alsa-tools`（`hda-verb` 来源）
- `wireplumber`
- `pipewire`
- `sof-firmware`

### 7.1 确认 `Headphone Jack` 的 numid 未变

```bash
amixer -c0 contents | grep -A1 "Headphone Jack"
```



预期看到 `numid=14,iface=CARD,name='Headphone Jack'`。如果 numid 变了，把脚本中 `cget numid=14` 改为新的 numid。

### 7.2 确认 Sink 名称未变

```bash
pactl list short sinks
```



检查 `pactl set-sink-port` 中硬编码的 `...HiFi__Headphones__sink` 是否仍存在。若名称变化，同步更新脚本中的字符串。

### 7.3 确认 `soft-mixer` 仍生效

```bash
wpctl status | grep -A2 "Sinks:"
# 记下当前 Speaker Sink 的 ID（例如 57）
wpctl inspect 57 | grep -E "soft-mixer|ignore-dB|enable-hw"
```



应看到 `api.alsa.soft-mixer = "true"` 等属性。若缺失，检查 WirePlumber 配置语法是否随版本变化。

### 7.4 确认 `hda-verb` 仍生效

插拔耳机，观察 `alsamixer -c0` 中 `Speaker` / `Headphone` 是否保持 100%，声音是否正确切换。若打印正常但声音不切换，说明 widget 地址可能需要根据新内核拓扑重新核对。

### 7.5 确认服务运行正常

```bash
systemctl status huawei-soundcard-headphones-monitor.service
journalctl -u huawei-soundcard-headphones-monitor.service -b --no-pager | tail -30
```



不应出现 `Connection refused`、频繁 `Scheduled restart job` 或 `already running`。

------

## 8. 故障排查

| 症状                                      | 可能原因                                       | 处理                                                         |
| ----------------------------------------- | ---------------------------------------------- | ------------------------------------------------------------ |
| 服务反复重启，日志有 `Connection refused` | 服务被装成了用户级，或 `su - zhou_` 用户名错误 | 确认是 `/etc/systemd/system/` 下的系统级服务，`User=root`，用户名正确 |
| 插拔无打印                                | `numid` 变化或 `get_jack_state` 解析失败       | 运行 `amixer -c0 cget numid=14` 确认插拔时 `values=` 在 `on`/`off` 间切换 |
| 打印正常但声音不切换                      | `hda-verb` 权限不足或 widget 地址变化          | 检查 `journalctl` 是否有 `Permission denied`；用 `hda-verb /dev/snd/hwC0D0 0x16 0x701 0x0000` 手动测试 |
| 音量条 10% 后不再增加                     | `soft-mixer` 未生效                            | 检查 `wpctl inspect <SinkID> | grep soft-mixer`，确认 `device.name` 匹配正确 |
| 拔耳机后音量变轻                          | 硬件增益未锁定                                 | 确认脚本两个 `switch_to_*` 函数里都有 `amixer sset Speaker/Headphone 100%` |
| 耳机无声、扬声器有声                      | `pactl set-sink-port` 的 Sink 名不匹配         | 用 `pactl list short sinks` 核对名称并更新脚本               |
| 声卡索引不是 0                            | `hda-verb` 硬编码 `hwC0D0` 失效                | 把脚本中 6 处 `/dev/snd/hwC0D0` 改为 `/dev/snd/hwC${card_index}D0` |

------

## 9. 已知局限与后续优化建议

1. **`hda-verb` 硬编码 card 0**：当前声卡索引为 0，若未来拓扑变化导致 `sof-hda-dsp` 不再是 card 0，需同步修改脚本中的 `/dev/snd/hwC0D0`。
2. **`su - zhou_` 硬编码用户名**：若希望可移植，可在服务文件加 `Environment=AUDIO_USER=zhou_`，脚本读 `$AUDIO_USER` 并用 `runuser -u "$AUDIO_USER" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$AUDIO_USER")" pactl ...` 替代。
3. **UCM 更新风险**：华为 MateBook 系列的 UCM 映射历史上被反复修正。若未来 `alsa-ucm-conf` 更新“修正”了 `Headphone`/`Speaker` 的映射，脚本中“把 `Headphone` 固定在 100% 作为扬声器增益级”的前提可能不再成立，届时需重新用 `alsamixer` 确认哪个控件真正控制响度。
4. **`alsactl store` 的持久性**：`alsactl store` 保存的硬件状态在部分内核/驱动更新后可能被重置。若发现开机后 `Speaker`/`Headphone` 不是 100%，重新执行一次 `amixer sset ... 100% && sudo alsactl store` 即可；脚本本身也会在每次切换时重新锁定。
