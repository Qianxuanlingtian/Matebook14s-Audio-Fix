# Huawei MateBook 14s (HKD-WXX) Linux 音频修复文档

> Conexant CX11880 + Intel Tiger Lake + SOF 驱动下扬声器/耳机无声的完整解决方案

---

## 一、问题现象

| 现象 | 说明 |
|---|---|
| 扬声器无声 | 系统音量正常、DMA 有数据流，但物理无声 |
| 插入耳机也无声 | 与扬声器同时失效，指向同一底层原因 |
| **音量始终偏小** | **软硬件音量都调到 100% 仍很小 —— 硬件 DAC 增益被压低** |
| Windows 下正常 | 硬件完好，排除硬件故障 |
| 内核日志无报错 | 固件/拓扑加载成功，属"驱动正常运行但没做该做的事" |

---

## 二、环境信息

```
机型      HUAWEI HKD-WXX (MateBook 14s) / 主板 HKD-WXX-PCB-B1
系统      Arch Linux, 内核 7.2.9-arch1-1
声卡      Intel Tiger Lake HD Audio 8086:a0c8 (子系统 152d:1346 QUANTA)
驱动      sof-audio-pci-intel-tgl
Codec     Conexant CX11880 (14f11f86 / 152d1350)
音频栈    PipeWire 1.6.9 + WirePlumber 0.5.18
固件      sof-firmware 2026.09.2-1, alsa-ucm-conf 1.2.16.1-1
```

---

## 三、硬件机制（关键）

这是本机音频正常工作的核心模型，全部结论均来自寄存器实测。

### 3.1 节点拓扑

```
DAC 0x10 ─┐
          ├─→ 引脚 0x16  耳机插孔  [Jack] HP Out at Ext Left
DAC 0x11 ─┘
          └─→ 引脚 0x17  内置扬声器 [Fixed] Speaker at Int Rear

Audio Function Group 0x1  （含 GPIO 控制）
```

**重要**：引脚 `0x16` 的 `Connection` 有两个候选（`0x10` 和 `0x11`），可切换。`0x17` 同样。

### 3.2 三条核心结论

**① 数据流只在 DAC `0x11`**

`0x10` 的 `Converter stream` 恒为 `0`（从不参与输出）。观察到的两种状态：

```
Speaker profile:     0x10 stream=0 或 1,  0x11 stream=1
Headphones profile:  0x10 stream=0,       0x11 stream=1
```

无论哪个 profile，`0x11` 始终是有数据的那个。

**② 冷启动时 `0x16` 默认指向被静音的 `0x10`**

```
冷启动后:  Connection: 0x10* 0x11    ← 星号在 0x10
          且 0x10 amp = 0xbb (静音位=1)
正确状态:  Connection: 0x10 0x11*    ← 星号在 0x11
```

**必须显式执行 `hda-verb 0x16 0x701 0x0001` 改指 `0x11`。** 这是"重启后失效"的直接原因。

**③ 真正的输出开关是引脚 EAPD（verb `0x70C`），不是 Pin-ctls（`0x707`）**

实测反例：`0x17 Pin-ctls = 0x00`（输出禁用）时扬声器**仍在发声**；而 `0x17 EAPD = 0x0` 时才真正静音。

### 3.3 DAC 功放：静音位 + 硬件增益（两者合一）

`0x11` 的功放寄存器（`Amp-Out`，verb `0x300`）每声道 8 位：

```
bit7    = mute  (1 = 静音)
bit6-0  = gain  (该 codec 有效范围 0..74，即 0x00..0x4a)
```

**关键：这一个寄存器同时决定"有没有声音"和"声音多大"。**

```
0x4a = 0b01001010   mute=0, gain=74 → 有声，满增益 (0.0 dB)     ← 正确目标
0x33 = 0b00110011   mute=0, gain=51 → 有声，但 -23 dB          ← 音量明显偏小
0xb3 = 0b10110011   mute=1, gain=51 → 无声
0xbb = 0b10111011   mute=1, gain=59 → 无声
```

`gain` 与分贝的换算（`dBscale-min = -74 dB`, `step = 1 dB`）：

```
实际增益 = -74 + gain  (dB)
  gain=74 → 0.0 dB    (满)
  gain=51 → -23.0 dB  (仅 69% 线性值, 但感知上明显偏小)
```

#### 陷阱一：静音位失控

切到 `Headphones` profile 后，UCM 会**移除** `Speaker Playback Switch` 控件（该控件是 `0x11` 静音位的 ALSA 接口）。此时硬件静音位可能保持置位，而**系统中已无任何控件能解除它** → 全程无声。

必须用 `hda-verb 0x11 0x300 0xb04a` 直接写寄存器。

#### 陷阱二：硬编码低增益导致音量偏小

**这是实际踩过的坑。** 早期版本为了解除静音，硬编码写入 `0xb033`（gain=51）。

`51` 只是从当时寄存器抄来的值，**并非音量上限**，结果导致：

- 声音能正常输出，但**始终比 Windows 下小很多**
- 用户在 DMS/浏览器把音量拉到 100% 也无效 —— 因为衰减发生在**硬件层**，软件音量无法补偿
- 这种故障**不会让声音消失**，只表现为"一直偏小"，很容易被误判为"这机器 Linux 下就这样"

**正确值应写满：`0xb04a`**（`0xb000` 输出功放 + 左右声道，`mute=0`，`gain=0x4a=74`）。

#### 音量链路排查

若音量偏小，需逐层核算（任一层的衰减都可能是原因）：

| 层 | 查看命令 | 正常值 |
|---|---|---|
| 应用 sink-input | `pactl list sink-inputs` | 100% |
| PipeWire sink | `pactl get-sink-volume @DEFAULT_SINK@` | 按需 |
| `Master Playback Volume` | `amixer -c0 get 'Master Playback Volume'` | 74/74 |
| `PGA*` 数字增益级 | `amixer -c0 contents \| grep PGA` | 32/32 |
| **硬件 DAC `0x11`** | `awk '/^Node 0x11 /,/^Node 0x12 /' /proc/asound/card0/codec#0 \| grep Amp-Out` | **`0x4a`** |

本机实测：`Master` 与所有 `PGA*` 均为满值，**唯一衰减点就是 DAC `0x11`**。

> 注：`PGA30.0`/`PGA31.0`/`PGA1.0` 等是 SOF 拓扑里的数字增益级，`max=32` 即满值，无需调整。

### 3.4 UCM 的两个 profile 互斥

```
HiFi (HDMI1, HDMI2, HDMI3, Headphones, Mic1, Mic2)   priority 10300   含耳机sink
HiFi (HDMI1, HDMI2, HDMI3, Mic1, Mic2, Speaker)      priority 10200   含扬声器sink
```

**两者互斥**：同一时刻只有一个 sink 存在。因此切换输出**必须同时切换 profile**，只改 `set-default-sink` 会因目标 sink 不存在而静默失败。

### 3.5 插拔检测

真机插拔信号在输入子系统，**不是** ALSA mixer 控件：

```
/sys/class/input/input18/name = "sof-hda-dsp Headphone"
  → /dev/input/event15
  → EV_SW (bit5) / SW_HEADPHONE_INSERT (bit2 = 值 4)
```

读取方式（`EVIOCGSW` ioctl）：

```python
import fcntl, struct, os
fd = os.open('/dev/input/event15', os.O_RDONLY | os.O_NONBLOCK)
sw = struct.unpack('Q', fcntl.ioctl(fd, 0x8008451b, b'\x00'*8))[0]
inserted = bool(sw & 4)
```

**不要用** `amixer get Headphone`：那是脚本自己通过 `hda-verb 0x1 0x715` 写出的**输出开关**，不是插拔传感器，插着耳机时它也不会变 `on`。（上游社区方案正因此在本机失效。）

---

## 四、最终有效命令序列

```bash
CODEC=/dev/snd/hwC0D0

# ---- 共用步骤（两种模式都要）----
hda-verb $CODEC 0x16 0x701 0x0001    # ① 0x16 连接选择 → DAC 0x11
hda-verb $CODEC 0x11 0x300 0xb04a    # ② 解除 DAC 0x11 静音 + 增益拉满(74)

# ---- 扬声器模式 ----
hda-verb $CODEC 0x16 0x70C 0x0000    # 关耳机 EAPD
hda-verb $CODEC 0x17 0x70C 0x0002    # 开扬声器 EAPD
pactl set-card-profile <card> "HiFi (HDMI1, HDMI2, HDMI3, Mic1, Mic2, Speaker)"
pactl set-default-sink <Speaker sink>

# ---- 耳机模式 ----
hda-verb $CODEC 0x16 0x70C 0x0002    # 开耳机 EAPD
hda-verb $CODEC 0x17 0x70C 0x0000    # 关扬声器 EAPD
pactl set-card-profile <card> "HiFi (HDMI1, HDMI2, HDMI3, Headphones, Mic1, Mic2)"
pactl set-default-sink <Headphones sink>
```

**顺序很重要**：`0x701` 和 `0x300` 必须在 profile 切换**之后**执行，因为切 profile 会重置 codec。

**`0x300` 的 payload 不要写成 `0xb033`**：`0xb033` 是 gain=51（-23dB），会导致音量偏小。详见 [3.3 陷阱二](#陷阱二硬编码低增益导致音量偏小)。

---

## 五、交付文件

| 文件 | 说明 |
|---|---|
| `huawei-audio-fix.sh` | 守护进程（持续自愈架构） |
| `huawei-audio-fix.service` | systemd 主服务，开机自启 |
| `huawei-audio-fix-resume.service` | 挂起恢复钩子 |
| `install.sh` | 一键安装 |
| `uninstall.sh` | 卸载 |
| `diagnose-audio.sh` | 诊断脚本（内核升级后排查用） |
| `tone.wav` | 测试音（3 秒 440Hz） |

### 安装

```bash
sudo ./install.sh
```

### 日常命令

```bash
systemctl status  huawei-audio-fix
systemctl restart huawei-audio-fix
journalctl -u huawei-audio-fix -f
```

---

## 六、守护进程设计要点

### 6.1 持续自愈（核心）

**不要**采用"启动后某个时间窗内写完就完事"的思路。实测表明：服务在启动收尾期写入的 codec 状态**会被覆盖**，而覆盖时机不确定（曾在写入后 6 秒之外发生）。

正确做法是**每轮循环都校验并按需重写**：

```bash
while true; do
    # 读取插拔状态 ...
    if [[ $status -ne $old ]]; then
        apply_output "$want"          # 插拔变化 -> 完整切换
    else
        if ! (conn_on_11 && eapd_is "$want" && dac_amp_ok); then
            log "检测到 codec 状态被重置, 重新应用"
            apply_codec "$want"       # 自愈
        fi
    fi
    sleep 0.5
done
```

这样无论 codec 因何原因（启动收尾、UCM 重配、挂起恢复）被重置，都会在 0.5 秒内自动纠正。

> **为什么必须校验 `dac_amp_ok`（增益），而不只是"未静音"：**
> 只检查静音位会漏掉"增益被压低"的情况。那种故障不会让声音消失，只会**一直偏小**，属于静默劣化 —— 比完全无声更难察觉。早期版本正是因为没有这项校验，才让 `gain=51` 的问题长期存在。

### 6.2 状态校验函数

```bash
# 判断 0x16 是否指向 0x11
conn_on_11() {
    awk '/^Node 0x16 /,/^Node 0x17 \[/' /proc/asound/card0/codec#0 \
      | grep -E '^[[:space:]]+0x1[01]' | head -1 | grep -q '0x11\*'
}

# 判断 DAC 0x11 的功放: mute=0 且 gain=74
dac_amp_ok() {
    local v
    v=$(awk '/^Node 0x11 /,/^Node 0x12 /' /proc/asound/card0/codec#0 \
        | grep -oP 'Amp-Out vals:\s+\[0x\K[0-9a-fA-F]+' | head -1)
    [[ -z "$v" ]] && return 1
    (( (0x$v >> 7 & 1) == 0 && (0x$v & 0x7f) == 0x4a ))
}
```

**踩坑记录**：不要写 `grep -A2 'Connection:' | tail -1` —— `awk` 范围会多带一行 `Node 0x17 [Pin Complex] ...`，`tail -1` 取到的是它，导致判断永远失效。

### 6.3 启动等待

服务可能早于 PipeWire 就绪。需轮询 `pactl info` 直到成功（上限 30 秒），否则 `set-card-profile` 会"成功"但 sink 不出现。

### 6.4 其他注意事项

- **返回值**：`apply_output` 需显式 `return $ok`。若末条是 `[[ -n "$x" ]] && cmd`，为空时会返回非 0，导致 `&& log` 被跳过——**日志缺失本身就是故障信号**。
- **root 下 pactl**：需显式传 `XDG_RUNTIME_DIR=/run/user/<uid>`，否则连不上 PipeWire。
- **失败不更新状态**：`old` 仅在成功时更新，失败则下轮重试。

---

## 七、故障排查

### 7.1 快速诊断

```bash
./diagnose-audio.sh
```

### 7.2 关键检查点

```bash
# ① 0x16 是否指向 0x11（重启后最常见的问题）
awk '/^Node 0x16 /,/^Node 0x17 \[/' /proc/asound/card0/codec#0 | grep -A2 "Connection:"
#    期望: 0x10 0x11*

# ② EAPD 状态
awk '/^Node 0x16 /,/^Node 0x17 \[/' /proc/asound/card0/codec#0 | grep -oP "EAPD 0x\w+"
awk '/^Node 0x17 \[/,/^Node 0x18 /' /proc/asound/card0/codec#0 | grep -oP "EAPD 0x\w+"
#    扬声器模式: 0x16=0x0, 0x17=0x2

# ③ DAC 功放（静音位 + 硬件增益，两者都在这里）
awk '/^Node 0x11 /,/^Node 0x12 /' /proc/asound/card0/codec#0 | grep "Amp-Out vals"
#    期望: 0x4a   (mute=0, gain=74 满值)
#    警示: 0x33 = gain 仅 51（-23dB），声音会明显偏小
#          0xb3 / 0xbb = 静音位被置位，完全无声

# ④ 数据流
sed -n '/^Node 0x11 /,/^Node 0x12 /p' /proc/asound/card0/codec#0 | grep -oP "stream=\d+"
#    期望: stream=1

# ⑤ 插拔传感器
python3 -c "
import fcntl,struct,os
fd=os.open('/dev/input/event15',os.O_RDONLY|os.O_NONBLOCK)
sw=struct.unpack('Q',fcntl.ioctl(fd,0x8008451b,b'\x00'*8))[0]
print('sw=0x%x 耳机已插入=%s'%(sw,bool(sw&4)))"
```

### 7.3 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 重启后无声 | `0x16` 指回 `0x10` | `hda-verb 0x16 0x701 0x0001` |
| 耳机扬声器同时出声 | 两个 EAPD 都开着 | 检查 `0x16`/`0x17` 的 EAPD 是否互斥 |
| 有流但完全无声 | `0x11` 静音位被置位 | `hda-verb 0x11 0x300 0xb04a` |
| **音量一直偏小，调软件音量也无效** | **DAC `0x11` 增益不是 74**（如 `0x33`=51） | **`hda-verb 0x11 0x300 0xb04a`** |
| 音量偏小，且硬件增益已是 `0x4a` | 软件层衰减 | `pactl set-sink-volume @DEFAULT_SINK@ 100%` |
| 服务报 sink 未出现 | PipeWire 未就绪 | 检查 `wait_for_pipewire` 逻辑 |

### 7.4 内核升级后

方案依赖节点编号与 `hwC0D0` 路径。若升级后失效：

```bash
./diagnose-audio.sh                    # 检查 Node 编号是否变化
grep -E "autoconfig for|speaker_outs|hp_outs" <(journalctl -b -k)
```

`/proc/asound/card0/codec#0` 中的 `Node 0x..` 编号若变化，需同步修改脚本中的硬编码值。

---

## 八、验证清单

部署后应确认：

- [ ] 冷启动后**不插拔**，扬声器直接有声
- [ ] 插入耳机 → 耳机有声，扬声器静音
- [ ] 拔掉耳机 → 扬声器恢复有声
- [ ] **音量为满：`0x11` 的 `Amp-Out vals` 应为 `0x4a`**（不是 `0x33`）
- [ ] `systemctl is-enabled huawei-audio-fix` → `enabled`
- [ ] 挂起恢复后仍正常
- [ ] `journalctl` 中无反复的"检测到 codec 状态被重置"

---

## 九、技术结论总结

本机问题**不是配置错误，而是驱动缺失针对性支持**：

1. **硬件设计特殊** —— 两个输出引脚共用同一 DAC，靠各自 EAPD 区分
2. **ACPI 描述不完整** —— 扬声器引脚带 `Misc = NO_PRESENCE`，内核 autoconfig 把 `0x17` 归为 `line_out` 而非 `speaker_out`
3. **UCM profile 互斥** —— 切换输出必须切 profile
4. **静音位无控件接口** —— 切 profile 后 `0x11` 静音位失控
5. **插拔检测不在 mixer** —— 需读输入子系统的 `SW_HEADPHONE_INSERT`
6. **硬件增益需显式写满** —— 该 DAC 的 `gain` 只有写寄存器才能到 0dB，默认/残留值会压低音量

Windows 原厂 Conexant 驱动内置了这些处理，Linux 通用驱动没有，因此需外部守护进程补足。

---

*文档基于 2026-10-16 的实测结果编写。所有寄存器结论均经过实际读回验证。*

*处理平台DeepSeek Harness，接入模型DeepSeek-v4.1-Flash，共38轮。*
