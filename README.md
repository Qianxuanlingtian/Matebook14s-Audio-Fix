# Huawei MateBook 14s (HKD-WXX) Linux 音频修复

> Conexant CX11880 + Intel Tiger Lake + SOF 驱动下扬声器/耳机无声、音量偏小的完整解决方案

---

## 一、问题现象

| 现象 | 说明 |
|---|---|
| 扬声器无声 | 系统音量正常、DMA 有数据流，但物理无声 |
| 插入耳机也无声 | 与扬声器同时失效，指向同一底层原因 |
| 音量始终偏小 | 软硬件音量都调到 100% 仍很小 —— 硬件 DAC 增益被压低 |
| 插耳机时扬声器同时响 | 切换不完全，两个输出同时出声 |
| 拔耳机后扬声器无声 | 内核切回扬声器模式但没有解除 DAC 静音 |
| Windows 下正常 | 硬件完好，排除硬件故障 |
| 内核日志无报错 | 固件/拓扑加载成功，属"驱动正常运行但没做该做的事" |

---

## 二、环境信息

```
机型      HUAWEI HKD-WXX (MateBook 14s) / 主板 HKD-WXX-PCB-B1
系统      Arch Linux, 内核 7.2.11-arch1-1（7.2.9 亦适用，见文末差异说明）
声卡      Intel Tiger Lake HD Audio 8086:a0c8 (子系统 152d:1346 QUANTA)
驱动      sof-audio-pci-intel-tgl
Codec     Conexant CX11880 (14f11f86 / 152d1350)
音频栈    PipeWire 1.6.9 + WirePlumber 0.5.18
固件      sof-firmware 2026.09.2-1, alsa-ucm-conf 1.2.16.1-1
工具      alsa-tools（提供 hda-verb）
```

---

## 三、硬件机制（关键）

**本节所有结论均来自 2026-10-29 的隔离实测，每一条都经过单独验证。**

### 3.1 节点拓扑

```
Node 0x10  [Audio Output]  DAC   —— 耳机与扬声器的【总闸】
Node 0x11  [Audio Output]  DAC   —— 实测与输出【完全无关】
Node 0x16  [Pin Complex]   耳机插孔 [Jack] HP Out at Ext Left，带 Detect
Node 0x17  [Pin Complex]   内置扬声器 [Fixed] Speaker at Int Rear
```

两个引脚都声明了 `Connection: 0x10 / 0x11` 两个候选源，**但这个连接选择对输出没有实际作用**（见 3.3）。

### 3.2 两条核心规律

#### 规律一：DAC `0x10` 是耳机和扬声器共用的事实总闸

```
0x10 = 0x4a   mute=0, gain=74 (0dB)   ->  有声音
0x10 = 0xbb   mute=1, gain=59         ->  耳机、扬声器【一起】无声
```

`0x10` 同时供给耳机和扬声器。**任何模式下它都必须保持 `0x4a`。**
把 `0x10` 静音来"关扬声器"——会把耳机一起弄哑。这是最常见的误区。

DAC 功放值格式（`verb 0x300 = SET_AMP_GAIN_MUTE`）：

```
bit15    输出功放（1）
bit14    index（0）
bit13/12 左右声道（均为 1）
bit7     mute（0 = 不静音）
bit6-0   gain（0x4a = 74，即 0dB；该 codec 范围 0..74）
```

该 codec 的 `Amp-Out caps: ofs=0x4a, nsteps=0x4a, stepsize=0x03, mute=1`，
意味着 gain 每级 0.75dB，`0x4a` 是满值 0dB。写 `0xb033`（gain=51）会压低到 -23dB —— 这正是"音量偏小"的根因。

#### 规律二：扬声器引脚 `0x17` 只受 EAPD 控制

```
0x17 EAPD = 0x2   ->  扬声器响
0x17 EAPD = 0x0   ->  扬声器静音（耳机不受影响）
```

命令：`hda-verb /dev/snd/hwC0D0 0x17 0x70C 0x0002` / `... 0x0000`
（`verb 0x70C = SET_EAPD_BTL_ENABLE`）

### 3.3 无效的尝试（重要，避免重复踩坑）

以下操作都**经过实测确认无效**，不要再试：

| 操作 | 效果 |
|---|---|
| `0x17 0x707 <Pin-ctls>` 写 `0x00` 或 `0x40` | **无效**。`0x17` 的 Pincap 只有 `OUT EAPD`，没有 OUT/HP 位，不看 Pin-ctls |
| `0x16 0x701 0x0001/0x0000` 切连接 | 对输出无可见影响 |
| `0x17 0x701` 切连接 | **无效**。该引脚忽略自身 connection select |
| 往 `0x11` 写 amp（`0x300`） | **完全无关**。`0x11` 怎么改都不影响声音 |
| `0x1 0x715/0x716/0x717`（Config Default Override） | 不需要，写入无效果 |
| `Auto-Mute Mode` 设为 Enabled | 无效 |

补充：`0x17` 的 `Pin Default 0x91170110` 带 `Misc = NO_PRESENCE`，表示该固定引脚不做存在检测 —— 所以它没有插拔感知能力，这也解释了为什么它不响应 Pin-ctls。

### 3.4 插拔传感器

耳机插入状态来自 `/dev/input/eventN`，其 `name` 为 `sof-hda-dsp Headphone`：

```
EV_SW (ev bit 5) , capabilities = 4 = SW_HEADPHONE_INSERT (bit2)
读取: fcntl.ioctl(fd, EVIOCGSW=0x8008451b, b'\x00'*8) -> sw
插入状态 = bool(sw & 4)
```

其他同族 input 设备：`Mic`、`HDMI/DP,pcm=3/4/5`。

### 3.5 内核做对了什么、做错了什么

插耳机时内核会：
- 切到 `HiFi (..., Headphones, ...)` profile（priority 10300）
- 设置 `default-sink` 为 Headphones sink
- 设置 `0x16` Pin-ctls = `0xc0`（OUT HP）
- **把 `0x17` EAPD 保持为 `0x2`** ← 漏了，扬声器不关

拔耳机时内核会：
- 切回 `HiFi (..., Speaker)` profile（priority 10200）
- 设置 `0x17` EAPD = `0x2` ← 对了
- **不解除 `0x10` 的静音**（停在 `0xbb`）← 漏了，扬声器不响

两个 UCM profile 是互斥的，同一时刻只存在一个对应 sink。这只影响 PipeWire 的命名，不影响寄存器层的切换。

---

## 四、解决方案

### 4.1 唯一正确的切换矩阵

| 模式 | `0x10` DAC amp | `0x17` EAPD |
|---|---|---|
| **扬声器模式**（未插耳机） | `0x4a`（总闸开） | `0x2`（分闸开） |
| **耳机模式**（已插耳机） | `0x4a`（总闸开） | `0x0`（分闸关） |

记住两点：
1. `0x10` **永远**是 `0x4a`
2. 只有 `0x17` EAPD 在变

### 4.2 手动验证命令

```bash
# 扬声器模式
sudo hda-verb /dev/snd/hwC0D0 0x10 0x300 0xb04a
sudo hda-verb /dev/snd/hwC0D0 0x17 0x70C 0x0002

# 耳机模式
sudo hda-verb /dev/snd/hwC0D0 0x10 0x300 0xb04a
sudo hda-verb /dev/snd/hwC0D0 0x17 0x70C 0x0000
```

### 4.3 守护进程

`huawei-audio-fix.sh` 每 0.5 秒轮询一次：

```
1. 0x10 不满足 (0x4a)        -> 写 0xb04a
2. 未插耳机 且 EAPD != 0x2   -> 写 0x0002
3. 已插耳机 且 EAPD != 0x0   -> 写 0x0000
```

**脚本不碰的**：UCM profile、`default-sink`、`0x16`、Pin-ctls、`0x11`、`0x1` 的 Config Default Override。
这些要么内核已经处理，要么写入无效/有害。

### 4.4 安装与卸载

```bash
cd ~/Documents/deepseek-harness/metbook14s-audio-fix

sudo ./install.sh      # 安装并启用
sudo ./uninstall.sh    # 卸载
```

安装后立即生效，无需重启。

### 4.5 验证

```bash
systemctl is-active huawei-audio-fix          # active
journalctl -u huawei-audio-fix -f             # 看模式切换日志
```

寄存器检查：

```bash
# 0x10 的 amp（应始终为 0x4a）
awk '/^Node 0x10 /,/^Node 0x11 /' /proc/asound/card0/codec#0 | grep "Amp-Out vals"

# 0x17 的 EAPD（扬声器 0x2 / 耳机 0x0）
awk '/^Node 0x17 \[/,/^Node 0x18 /' /proc/asound/card0/codec#0 | grep "EAPD 0x"
```

日志中每次模式切换只输出一行：

```
扬声器模式: DAC 0x4a / EAPD 0x2
耳机模式: DAC 0x4a / EAPD 0x0
```

---

## 五、故障排查

### 扬声器无声

```bash
# 1. 服务在跑吗
systemctl is-active huawei-audio-fix

# 2. 0x10 是多少
awk '/^Node 0x10 /,/^Node 0x11 /' /proc/asound/card0/codec#0 | grep "Amp-Out vals"
#    不是 0x4a -> 服务没生效

# 3. 0x17 EAPD 是多少
awk '/^Node 0x17 \[/,/^Node 0x18 /' /proc/asound/card0/codec#0 | grep "EAPD 0x"
#    不是 0x2 -> 被当成耳机模式了，检查插孔
```

### 耳机无声

```bash
# 1. 0x10 必须是 0x4a（最常见错误：被设成 0xbb，耳机一起哑了）
sed -n '/^Node 0x10 /,/^Node 0x11 /p' /proc/asound/card0/codec#0 | grep "Amp-Out vals"

# 2. profile 是否是 Headphones
pactl list cards | grep "Active Profile"

# 3. 插拔传感器
amixer -c0 cget numid=14       # values=on 表示已插入
```

注意：`amixer get 'Headphone Jack'` 会报 `Unable to find simple control`，因为 `get` 只查 MIXER 级控件，而 `Headphone Jack`（numid=14）是 **CARD 级**控件。必须用 `cget numid=14`。

### 音量偏小

```bash
# 硬件 DAC 增益（唯一可能的衰减点）
awk '/^Node 0x10 /,/^Node 0x11 /' /proc/asound/card0/codec#0 | grep "Amp-Out vals"
# 必须是 0x4a（0dB 满值），0x33/0xb3 等表示 gain 被压低

# 软件侧（应该都是满值）
amixer -c0 sget "Master Playback Volume"
amixer -c0 sget "PGA1.0 1 Master Playback Volume"
```

### 插耳机时扬声器也响

说明 `0x17` EAPD 是 `0x2`。等服务把它改成 `0x0`，或手动执行：

```bash
sudo hda-verb /dev/snd/hwC0D0 0x17 0x70C 0x0000
```

如果手动执行有效但服务下无效，**先确认服务已停** —— 服务的 0.5 秒轮询会把你的修改改回去。

---

## 六、排错过程中踩过的坑

这一节记录反例，避免以后重复走弯路。

| 错误认知 | 实际 |
|---|---|
| "扬声器由 DAC `0x11` 驱动" | `0x11` 与输出**完全无关**。静音 `0x11` 毫无变化，静音 `0x10` 两边一起哑 |
| "插耳机时把 `0x10` 静音就能关扬声器" | `0x10` 是耳机+扬声器的**共用总闸**，静音会把耳机也弄哑 |
| "`0x17` 的 Pin-ctls 能关扬声器" | 完全无效。`0x17` 的 Pincap 没有 OUT 位，只认 EAPD |
| "`0x17` 的 connection select 无效" | 确实无效 —— 但这说明不能靠路由切换，只能靠 EAPD |
| "`0x1 0x715/0x716/0x717` 是缺失的一环" | 隔离测试证明完全不需要 |
| "`amixer get 'Headphone Jack'` 报错 = 控件不存在" | 控件在 CARD 级，`get` 查不到，要用 `cget numid=14` |
| "`/proc/asound/card0/codec#0` 里应该有全部控件" | CARD 级控件在 `controlC0`，`amixer -c0 contents` 才看得到 |

**方法论上的教训**：

- **不要在守护进程运行时手动验证寄存器写入** —— 0.5 秒的轮询会覆盖掉你的修改，得出"写入无效"的错误结论。这次排查中多次因此误判。
- **播放结束后采样不可靠** —— codec 会复位。必须在播放中采样。
- **音量没有固定时，"有声/无声"的结论不可靠** —— 21%/27%/-40dB 时做出的判断让你白走了很多弯路。
- **矛盾现象是最有价值的线索** —— "`0x11` 静音时扬声器反而有声"直接推翻了 `0x11` 假设。

---

## 七、内核版本差异

kernel 7.2.9 → 7.2.11 后，内核在 UCM 与寄存器层面的行为有变化。旧版脚本（见 `huawei-audio-fix.sh.old-kernel-729`）针对 7.2.9 的逆向工程，在 7.2.11 上会**主动破坏耳机通路**，故已弃用。

当前脚本基于上面的切换矩阵，不依赖内核版本的具体行为，因此在两个版本上都应适用。若将来内核修复了 §3.5 的两处遗漏，本脚本仍然正确（它只是把寄存器维持在该有的值上，不会与内核冲突）。

---

## 八、参考

- 上游同类方案：https://github.com/motogodfather/huawei-ubuntu-sound-fix
- SOF 相关 issue：https://github.com/thesofproject/linux/issues/3350
- ALSA HDA 规范中的 verb 定义：
  - `0x300` SET_AMP_GAIN_MUTE
  - `0x707` SET_PIN_WIDGET_CONTROL
  - `0x70C` SET_EAPD_BTL_ENABLE
  - `0x701` SET_CONNECT_SEL
