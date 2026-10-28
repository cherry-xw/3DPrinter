# 打印机配置与本地扩展备份

本仓库保存本机 Klipper 配置，以及摄像头脚本和音乐扩展的部署副本。
**这不是可直接用于其他打印机的通用配置。** 引脚、加热功率、运动限制、Z 偏移、PID、输入整形和网床数据均需按实机验证，不能直接套用。

## 目录与备份范围

- 根目录 `*.cfg` / `*.conf`：当前打印机配置。
- `scripts/camera.sh`：`/home/biqu/camera.sh` 的副本。
- `extras/music.py`：`/home/biqu/klipper/klippy/extras/music.py` 的副本（保持现有实现）。
- 音乐文件、自动备份、日志、系统配置、SSH 密钥、PulseAudio cookie 不纳入版本控制。
- `mainsail.cfg`、`timelapse.cfg`、`print_area_bed_mesh.cfg` 由相应项目另行安装；见 `.gitignore`。

仓库中的脚本和插件是部署副本，不会自动替换正在运行的文件。日后修改运行文件后，需同步副本再提交。

## 恢复前准备

以下命令以用户 `biqu`、仓库位于 `/home/biqu/printer_data/config` 为例。
先备份目标机器现有配置，并在打印空闲时操作。需要 Klipper、Moonraker、Mainsail、Crowsnest，以及配置引用的 KlipperScreen、timelapse、print_area_bed_mesh 等项目。

摄像头宏依赖第三方 Klipper `gcode_shell_command` 扩展，Klipper 默认安装不一定包含它；恢复时需单独安装，并确认来源可信。

系统依赖（按需安装）：

```sh
sudo apt install alsa-utils pulseaudio pulseaudio-utils mpv v4l-utils ffmpeg usbutils psmisc kmod
```

## 部署摄像头脚本

```sh
install -m 0755 /home/biqu/printer_data/config/scripts/camera.sh /home/biqu/camera.sh
mkdir -p /home/biqu/.local/bin
ln -sfn /home/biqu/camera.sh /home/biqu/.local/bin/camera
/home/biqu/camera.sh install
```

`install` 必须在交互终端运行并输入 sudo 密码；不要从 Mainsail 宏执行安装。
此命令生成 `/etc/sudoers.d/camera-ctl`，授权具体的模块、服务和设备占用处理命令，而不是授权整个脚本或任意 shell。
安装后由管理员确认：

```sh
sudo visudo -cf /etc/sudoers.d/camera-ctl
```

现有安装器会先写入再校验；应在受控的本机终端操作，失败时由管理员检查并删除无效规则，不要直接复制未经验证的 sudoers 文件。
`boot`、`suspend`、`resume` 等额外操作不在日常宏的免密授权范围内，需要在终端输入密码。

脚本默认匹配 Sonix `0c45:64a1`，使用 `uvcvideo` 和 `crowsnest`。迁移硬件时需检查这些值及 `crowsnest.conf` 的视频路径。
关闭会停止整个 Crowsnest 服务并卸载 UVC 模块，可能影响其他摄像头；USB 挂起不等于切断 USB 5V，也不能据此保证零功耗。

## 部署音乐扩展

```sh
install -m 0644 /home/biqu/printer_data/config/extras/music.py /home/biqu/klipper/klippy/extras/music.py
mkdir -p /home/biqu/printer_data/config/music
```

将自备音乐文件放入 `music/`（不提交版权音乐）。
PulseAudio 和 Klipper 应以同一普通用户运行，播放和调音量不需要 sudo。
检查用户音频服务和输出：

```sh
systemctl --user status pulseaudio.service pulseaudio.socket
pactl info
pactl list short sinks
```

在 `music.cfg` 的 `vol_device` 中使用 PulseAudio 的完整输出名称，不要使用 ALSA 声卡编号。当前为：

```ini
vol_device: alsa_output.usb-GeneralPlus_USB_Audio_Device-00.analog-stereo
```

确认 `pactl info` 的默认输出也是实际扬声器，因为现有播放器使用 mpv 的默认输出。
现有扩展在没有 `XDG_RUNTIME_DIR` 时使用 `/run/user/1000/pulse/native`；其他 UID 或无人登录环境需单独确认用户服务生命周期和 socket 路径。不要通过 sudo 启动另一套 root 音频服务来绕过问题。

## 加载与验证

只在打印空闲时执行 Klipper `RESTART`。不要为同步备份在打印中重启。
Mainsail 控制台：

```gcode
CAMERA_STATUS
CAMERA_OFF
CAMERA_ON
MUSIC EVENT=list
MUSIC EVENT=volume VALUE=40
```

摄像头参数形式为 `CAMERA MODE=ON` / `CAMERA MODE=OFF`，不是 `CAMERA ON` / `CAMERA OFF`。
音量验证可在终端执行 `pactl get-sink-volume <完整输出名称>`，再播放音乐确认听感。

## 安全与维护

提交前检查 `git diff`，不要提交密码、Token、私钥、音频认证 cookie、日志或 shell history。
现有 Moonraker 配置包含较宽的可信私网网段，这不是密码，但属于访问策略；应按实际网络缩小范围，禁止直接暴露公网。
硬件序列号、主机路径与校准数据保留在配置内，公开仓库会公开这些设备信息。
此备份没有改变现有音乐扩展的实现，也不代表对其所有边界情况或打印期间负载完成了验证。
