# Surface Book 1 摄像头 Linux 修复

两个内核模块修复，让 **Surface Book 1（1703/1705）的前后摄像头在 Linux 上可用**。
不打这两个补丁，两个摄像头**一个都注册不上**——`cam -l` 列出空表，GNOME Snapshot
会说找不到摄像头。

实测环境：

| | |
|---|---|
| 机器 | Surface Book 1（13 寸，1703/1705） |
| 内核 | `6.19.8-surface-3`（linux-surface） |
| libcamera | 0.7.0 |
| IPU3 栈 | `ipu3-cio2`、`ipu3-imgu`、`ov8865`（后摄）、`ov5693`（前摄）、`dw9719`（对焦马达 VCM） |

许可证：**GPL-2.0-only**——这是内核模块，两个源文件都派生自 Linux 内核。

> English documentation: [README.md](README.md)

## 两个 bug

| # | 症状 | 根因 | 补丁 |
|---|---|---|---|
| 1 | **摄像头一个都没有。** 前后摄都不在 libcamera 列表里。 | v6.19 删掉了 `dw9719` 的 `i2c_device_id` 表，导致 ACPI 平台上 VCM 绑不上，CIO2 notifier 永远不 complete。 | [`patches/0001`](patches/0001-dw9719-add-back-i2c-device-id-table.patch) |
| 2 | **后摄画面纯绿**，或者干脆没画面。 | `ov8865` 只有 native 3264x2448 模式能连续出帧，其余三个模式约 1 帧后停。 | [`patches/0003`](patches/0003-ov8865-only-expose-native-mode.patch) |

[`patches/0002`](patches/0002-dw9719-fsleep-power-up-delay.patch) **不是我们的**
——它是 linux-surface 自己给同一个驱动打的探测延时补丁。这里一并附上，只是因为
out-of-tree 模块会整体替换掉内核自带的那份文件。**任何 linux-surface 内核都已经
带了这个改动，别再打一遍。**

前提是你的内核带 linux-surface 补丁集。原生 Ubuntu 内核不行：它本来就没有这台机器
的 IPU3 摄像头支持。

## 安装

```bash
git clone <本仓库地址>
cd surface-book-1-camera-fix

./build.sh                 # 需要 linux-headers-$(uname -r)
sudo ./install.sh
sudo reboot
./diagnose.sh              # 看是否生效
```

`build.sh` **不需要内核源码树**，装好 linux-surface 的 headers 包就够。它会把两个
模块 out-of-tree 编出来，并在安装前校验 vermagic 是否匹配当前内核。

### 为什么必须重启（不是保险起见）

在**活着的**摄像头栈上卸载/重载这几个模块，会让 `ipu_bridge` 卡死：它不再给 ACPI
传感器设备挂 software node，之后每个传感器探测都报

```
failed to find 360000000 clk rate in endpoint link-frequencies
```

而且**不会重试**。这个状态不重启恢复不了。所以别为了"快速验证"去 `modprobe -r`
或者 unbind 设备。

### Secure Boot

模块未签名，所以内核会自我污染（`module verification failed ... tainting kernel`）。
这是预期行为，无害。但如果你的 **Secure Boot 是开启的**，必须先用自己的 MOK 密钥签名，
否则模块会直接拒绝加载。

## Bug 1 —— 为什么**两个**摄像头一起消失

后摄是 `ov8865`，带一个对焦音圈马达 `dw9719`。上游 v6.19 把它改成 CCI 驱动时，顺手
把 `i2c_device_id` 表删了：

```console
$ grep -nE 'i2c_device_id|\.id_table' dw9719.c    # v6.18.7
356:static const struct i2c_device_id dw9719_id_table[] = {
373:	.id_table = dw9719_id_table,

$ grep -nE 'i2c_device_id|\.id_table' dw9719.c    # v6.19.8
（什么都没有）
```

这件事之所以致命，是因为 ACPI 平台上 CIO2 桥把 VCM 实例化成一个**带 software node
的 i2c client**，而不是 OF 节点：

```
i2c-INT347A:00-VCM      modalias = i2c:dw9719
```

没有 `of_node`，OF 表永远匹配不上；id 表又被删了，于是没有任何东西能匹配。接下来的
链条毫无回旋余地：

```
VCM 探测不了
  -> ov8865 在 v4l2-async 里永远等它的 fwnode 供应者
    -> CIO2 notifier 永远不 complete
      -> 不创建任何 media 链接
        -> libcamera 的 registerCameras() 返回 -ENODEV
          -> 摄像头数量为零
```

反直觉的地方在于：**前摄 `ov5693` 也一起死了。** 它自己没有 VCM，纯粹是同一个
notifier 下的连带受害者。如果你因此去查前摄驱动的 bug，方向就错了。

补丁把 v6.18 那张表加回来。生效后内核日志里能看到：

```
dw9719 i2c-INT347A:00: Instantiated dw9719 VCM
```

模块别名里也能看到：

```console
$ modinfo dw9719 | grep '^alias.*i2c:'
alias:          i2c:dw9761
alias:          i2c:dw9719
```

这**不是 Surface Book 特有的**。任何用这颗 VCM 的 ACPI 机器（Surface Go 2、
Surface Pro 7+ 等）在 v6.19 上都会以同样方式丢掉摄像头。如果你是那些机型来的，
要看的就是 `patches/0001`。

## Bug 2 —— 后摄的绿色画面

`ov8865` 有四个模式，只有 native 那个能连续出帧：

| 模式 | `v4l2-ctl --stream-mmap --stream-count=5` |
|---|---|
| **3264x2448**（native） | **5/5 帧，rc=0** |
| 3264x1836 | 0.99 帧后停 |
| 1632x1224 | 0.99 帧后停 |
| 800x600 | 1.00 帧后停 |

按 好→坏→好→坏 交替测试复现同样的模式，所以这是**模式本身的属性**，不是 stream-on
的状态残留。内核日志说：

```
ipu3-cio2: payload length is 2585088, received 2588672
CSI-2 receiver port 0: frame sync error
```

实际收到比期望**多** 3584 字节，然后失步——非 native 模式的 HTS/VTS 时序表有误，
接收端溢出了。

### 为什么应用一定会踩到坏模式

libcamera 选「**≥ 请求尺寸里最小的那个**模式」：

| 应用请求 | libcamera 选中 | 结果 |
|---|---|---|
| 1280x720 | 1632x1224 | 坏模式——0 或 1 帧 |
| 1920x1080 | 3264x2448 | 好 |
| 2560x1920 | 3264x2448 | 好 |

GNOME Snapshot 请求的就是 1280x720，于是必踩坏模式。而它也没法请求更大：libcamera
经 PipeWire 暴露的 IPU3 摄像头输出尺寸**封顶 1280x720**（前后摄都一样，这是管线
限制不是传感器限制）。所以「应用改用更大分辨率」这条路走不通。

### 「纯绿」到底是什么

纯绿 = `YUV(0,0,0)`，换算成 `RGB(0,154,0)`。而 libcamera 自己填的「黑帧」是
`YUV(0,128,128)`。所以绿色**不是色彩问题**，而是应用拿到了一块**从未被写入**的缓冲
——零初始化内存。根本没有帧。（1280x720 下唯一到达的那一帧渲染出来是**品红**
`RGB(255,95,255)`——未收敛的 AWB——所以这个症状看起来像色彩 bug，其实不是。）

### 修法，以及代价

真正的修法需要 OV8865 datasheet。`ov8865_pll1_config` 只有一份、所有模式共用，而
`ov8865_pll2_config` 有 per-mode 变体；`ov8865_mode_pll1_rate()` /
`ov8865_mode_pll1_configure()` 收下了 `mode` 指针却完全不用。PLL1 决定 MIPI 时钟
（`pll1_rate / m_div / 2`），结果所有模式都报同一个 360 MHz。这是**没写完的实现**，
而 datasheet 里的 binning PLL1 参数拿不到，就无从改起。

所以退一步：把坏模式藏起来。让 `VIDIOC_ENUM_FRAMESIZES` 只报 native 一个，libcamera
就没得选；`set_fmt` 再兜底钉死，防止直接操作 V4L2 的调用方选到坏模式。

代价：

- 传感器恒跑 3264x2448，由 IMGU 降采样（请求 1280x720 时是 2.55×）；
- 功耗略升；
- 视野反而**更宽**而不是更窄——非 native 模式是裁切的
  （`crop:(832,652)/1632x1224`），native 用全阵列（`crop:(16,40)/3264x2448`）。

这是一个 workaround，我们就是这么标注的。如果谁手上有 datasheet，请把 PLL1 正经修好，
然后把 `patches/0003` 删掉。

## 回滚

```bash
sudo ./uninstall.sh
sudo reboot
```

模块装在 `/lib/modules/$(uname -r)/updates/`，该目录优先级高于内核自带的那份，因此
它会遮蔽内置模块。卸载就是删文件 + `depmod -a`，**完全不碰包管理器管的东西**，所以
重装 `linux-image-surface` 永远能回到原状。

## 排查 IPU3 栈时的备忘

- **裸 V4L2 必须手工对齐管线格式。** `ov8865` 停在 native 3264x2448，而
  `ipu3-csi2 0` 默认是 1632x1224；宽高不符会让 `v4l2_subdev_link_validate()` 返回
  `-EPIPE`，`VIDIOC_STREAMON` 直接 `Broken pipe`。先对齐：

  ```bash
  sudo media-ctl -d /dev/media1 -V '"ov8865 3-0010":0 [fmt:SBGGR10_1X10/1632x1224 field:none]'
  sudo media-ctl -d /dev/media1 -V '"ipu3-csi2 0":0 [fmt:SBGGR10_1X10/1632x1224 field:none]'
  sudo media-ctl -d /dev/media1 -V '"ipu3-csi2 0":1 [fmt:SBGGR10_1X10/1632x1224 field:none]'
  ```

  前摄 `ov5693` 是**碰巧**躲过这一劫：它的驱动默认模式（2592x1944）刚好等于 CIO2
  的默认格式。

- **`cam` 的参数语法会咬人。** libcamera 0.7.0 里正确的是
  `cam -c1 --capture=5 --stream role=viewfinder,width=1280,height=720 --file=out.raw`。
  `--stream size=...` 和 `--stream-count=5` 都不存在；传了会让 `cam` 打印帮助并以
  非零退出——很容易误判成「抓帧失败」。`-F out.ppm` 会静默产生 0 字节文件。

- **`cam` 报 "Device or resource busy"** 通常是 PipeWire / wireplumber 占着
  `/dev/video*` 和 `/dev/media*` 的 fd，不是驱动坏了。

- **`dmesg` 在 Ubuntu 上受限**，用 `sudo journalctl -k -b`。

- **第 1 帧一定是全零**（前后摄都一样）。那是 IPU3 预热，不是 bug，`diagnose.sh`
  已经把这情况排除在外。

## 有意不放进仓库的东西

- **预编译的 `.ko`。** 它们绑定某一个确切的内核构建、会污染内核，而且你不该加载
  陌生人仓库里的二进制。自己 `make` 三秒钟的事。
- **MOK 签名密钥。** 签名跟机器绑定，用你自己的密钥。
- 完整内核源码。补丁针对内核树，`src/` 里的副本可以 out-of-tree 编译；两条路都
  由你自己去取内核。

## 致谢

- IPU3、摄像头与 Surface 支持来自
  [linux-surface](https://github.com/linux-surface/linux-surface) 以及上游
  `drivers/media/i2c` 的维护者。`patches/0002` 是 linux-surface 的补丁
  （作者：mojyack）。
- 这里的两个修复来自对一台 Surface Book 1 的排查。
