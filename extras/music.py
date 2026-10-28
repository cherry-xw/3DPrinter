import os
import subprocess
import glob
import logging
import time
import signal
import re

class MusicPlayer:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.continue_play = config.getboolean('continue_play', False)
        self.page_size = config.getint('page_size', 10)

        music_dir = config.get('music_dir', '/opt/navidrome/music/')
        default_volume = config.getint('default_volume', 40)
        vol_device = config.get('vol_device', '0')
        self.backend = MusicBackEnd(music_dir, vol_device, default_volume)

        # 注册G-code命令
        self.gcode = self.printer.lookup_object('gcode')
        self.gcode.register_command('MUSIC', self.cmd_MUSIC, desc=self.cmd_MUSIC_help)
        self.printer.register_event_handler("klippy:disconnect", self._handle_disconnect)

        # 创建状态监控任务
        self.printer.get_reactor().register_timer(self._monitor_player, self.printer.get_reactor().NOW)

        logging.info(f"chery: loop:{str(self.continue_play)} | vol:{default_volume} | dir:{music_dir}")
        logging.info("chery:Music Player plugin initialized (author: chery)")

    def _monitor_player(self, eventtime):
        """监控播放器状态"""
        player_pid = self.backend.status['pid']
        # logging.info("chery:"+ str(player_pid) + "___" +  str(not self.is_process_running(player_pid)))
        if player_pid and not self.backend.is_process_running():
            if (self.continue_play):
                self.backend.play_next()
                # pass
            else:
                logging.info(f"chery:Music playback ended for PID {player_pid}")
                self.backend.clean_status()
        return eventtime + 3.0  # 每3秒检查一次

    cmd_MUSIC_help = """
        <div style="color:cyan">Music Player commands:</div>
        &nbsp;&nbsp;1. <a class="command text--blue">MUSIC EVENT=list</a>: show all available music files
        &nbsp;&nbsp;2. <a class="command text--blue">MUSIC EVENT=play VALUE=&lt;index&gt;</a>: play a specific music file
        &nbsp;&nbsp;3. <a class="command text--blue">MUSIC EVENT=stop</a>: stop the current music playback
        &nbsp;&nbsp;5. <a class="command text--blue">MUSIC EVENT=volume VALUE=&lt;0-100&gt;</a>=: set the playback volume
    """
    def cmd_MUSIC(self, gcmd):
        """播放器"""
        objs = gcmd.get_command_parameters()
        args = objs.get('EVENT', '')
        logging.info(f"chery:Music command received: {args}")
        # args = gcmd.get("EVENT")
        if 'list' in args:
            self._cmd_MUSIC_LIST(gcmd)
        elif 'play' in args:
            self._cmd_MUSIC_PLAY(gcmd)
        elif 'stop' in args:
            self._cmd_MUSIC_STOP(gcmd)
        elif 'volume' in args:
            self._cmd_MUSIC_VOLUME(gcmd)
        else:
            self._cmd_MUSIC_LIST(gcmd)

    # ----------------------------------------------- 实现音乐播放执行逻辑 ---------------------------------------------------------------------
    def _cmd_MUSIC_LIST(self, gcmd):
        """根据分页列出音乐文件"""
        page_num = gcmd.get_int("PAGE", 1)
        total_page = len(self.backend.music_files)

        if page_num < 1 or page_num > total_page:
            page_num = 1

        end = page_num * self.page_size
        start = end - self.page_size

        last_page = int(total_page / self.page_size) + 1
        current_index = self.backend.status['current_index']
        # 发送响应
        info = "<div style='color: cyan'>音乐列表:</div>"
        for idx, file in enumerate(self.backend.music_files[start:end], start=start):
            rel_path = os.path.relpath(file, self.backend.music_dir)
            styl = f"margin-right:20px;{'color: yellow' if idx == current_index else ''}"
            info += f"""<div style='display:flex;white-space: nowrap;flex-wrap: wrap;'>
            <span>{idx + 1}: {self._create_fake_button(rel_path, f"MUSIC EVENT=play VALUE={idx}", styl)}</span>
            </div>""".replace("\n", "")
        info += "\n"
        info += self._MUSIC_STATUS()
        info += f"""<div style='display:flex;white-space: nowrap;flex-wrap: wrap;'>
        {self._create_fake_button('首页', 'MUSIC EVENT=list PAGE=1', 'margin-right:20px;')}
        <span>|</span>
        {self._create_fake_button('上一页', f'MUSIC EVENT=list PAGE={max(page_num-1, 1)}', 'margin-right:20px;margin-left:20px')}
        <span>| [{page_num}/{last_page}] |</span>
        {self._create_fake_button('下一页', f'MUSIC EVENT=list PAGE={min(page_num+1, last_page)}', 'margin-right:20px;margin-left:20px')}
        <span>|</span>
        {self._create_fake_button('末页', f'MUSIC EVENT=list PAGE={last_page}', 'margin-left:20px')}
        </div>""".replace("\n", "")
        gcmd.respond_info(info)

    def _create_fake_button(self, txt, gcode, txtStyle = ""):
        return f"<span style='position:relative;color: var(--v-anchor-base) !important;'><span style='{txtStyle}'>{txt}</span><div style='position:absolute;left:0;right:0;top:0;bottom:0;opacity:0;z-index:1;white-space:nowrap;overflow:hidden;'><a class='command text--blue'>{gcode}</a></div></span>"

    def _cmd_MUSIC_PLAY(self, gcmd):
        """播放指定音乐文件"""
        index = gcmd.get_int('VALUE')
        # 停止当前播放
        self.backend.stop_player()

        if index < 0 or index >= len(self.backend.music_files):
            gcmd.respond_info("Error: Invalid index")
            return
        # 异步播放
        self.backend.play(index)
        gcmd.respond_info(self._MUSIC_STATUS())

    def _cmd_MUSIC_STOP(self, gcmd):
        """停止播放"""
        self.backend.stop_player()
        gcmd.respond_info(self._MUSIC_STATUS())

    def _MUSIC_STATUS(self):
        """获取播放状态"""
        status = self.backend.status
        state = status['state']
        current_index = status['current_index'] + 1 if status['current_index'] is not None else "None"
        current_file = status['current_file'] or "None"
        pid = status['pid'] or "None"
        vol = status['volume']
        logging.info(f"chery: {current_index} / {self.page_size} - {int(current_index / self.page_size)}")

        minus = self._create_fake_button('-', f"MUSIC EVENT=volume VALUE={0 if vol < 10 else vol - 10}")
        plus = self._create_fake_button('+', f"MUSIC EVENT=volume VALUE={100 if vol > 90 else vol + 10}")
        see = '' if current_file is "None" else self._create_fake_button('[查看本页]', f'MUSIC EVENT=list VALUE={int(current_index / self.page_size) + 1}')
        return f"""<div style='display:flex;white-space: nowrap;flex-wrap: wrap;'>
            <span style='margin-right: 12px'>状态: <span style='color:{'gray' if state == '已停止' else 'yellow'}'>{state}</span></span>
            <span style='margin-right: 12px'>文件: {'' if current_file is "None" else current_index} {current_file} {see}</span>
            <span style='margin-right: 12px'>PID: {pid}</span>
            <span style='margin-right: 12px'>音量: {minus} {vol}/100 {plus}</span>
            {self._create_fake_button('停止播放', 'MUSIC EVENT=stop') if state == '播放中' else ''}
        </div>""".replace("\n", "")

    def _cmd_MUSIC_VOLUME(self, gcmd):
        """ 设置音量 """
        val = gcmd.get_int('VALUE')
        if val < 0 or val > 100:
            gcmd.respond_info("Error: Volume must be between 0 and 100")
            return
        self._base_set_vol(gcmd, val)

    def _base_set_vol(self, gcmd, val):
        if (not self.backend.set_volume(val)):
            try:
                r2 = subprocess.run("pactl list short sinks", shell=True, capture_output=True, text=True)
                gcmd.respond_info(f"pactl list short sinks = info:{r2.stdout} && err:{r2.stderr}")
            except:
                gcmd.respond_info("Error: set volume failed")
        else:
            gcmd.respond_info(self._MUSIC_STATUS())

    def _handle_disconnect(self):
        self.backend.stop()
# ----------------------------------------------- 具体执行终端指令部分 ---------------------------------------------------------------------
class MusicBackEnd:
    def __init__(self, music_dir, vol_device, volume):
        self.status = {
            'current_index': -1,
            'state': '已停止',
            'current_file': None,
            'volume': volume,
            'pid': None
        }
        self.music_dir = music_dir
        """获取所有音乐文件"""
        pattern = os.path.join(music_dir, '**/*.*')
        files = glob.glob(pattern, recursive=True)
        valid_exts = ['.mp3', '.flac', '.wav', '.ogg', '.m4a']
        self.music_files = [f for f in files if os.path.splitext(f)[1].lower() in valid_exts]
        self.vol_device = vol_device
        self.set_volume(volume)

    def stop_player(self):
        """停止播放器"""
        player_pid = self.status['pid']
        if player_pid and self.is_process_running():
            try:
                # 发送SIGTERM信号优雅终止
                os.kill(player_pid, signal.SIGTERM)
                logging.info(f"chery:Sent SIGTERM to music player PID {player_pid}")
                # 等待进程退出
                for _ in range(5):  # 最多等待5秒
                    if not self.is_process_running():
                        break
                    time.sleep(0.5)
                else:
                    # 如果还在运行，强制终止
                    os.kill(player_pid, signal.SIGKILL)
                    logging.warning(f"chery:Had to SIGKILL music player PID {player_pid}")
            except ProcessLookupError:
                # 进程已不存在
                pass
            except Exception as e:
                logging.error(f"chery:Error stopping player: {str(e)}")
        # 重置状态
        self.status.update({
            'state': '已停止',
            'current_index': -1,
            'current_file': None,
            'pid': None
        })

    def is_process_running(self):
        """检查进程是否在运行（不使用psutil）"""
        pid = self.status['pid']
        if pid is None:
            return False
        try:
            subprocess.check_output(["ps", "-p", str(pid)])
            # logging.info(f"chery:a")
            return True
        except subprocess.CalledProcessError:
            # logging.info(f"chery:b")
            return False

    def play(self, index):
        """播放音乐文件"""
        try:
            file_path = self.music_files[index]
            # 使用nohup在后台运行mpv
            process = subprocess.Popen(
                ['nohup', 'mpv', file_path],
                stdout=open('/dev/null', 'w'),
                stderr=subprocess.STDOUT,
                preexec_fn=os.setpgrp  # 创建新的进程组
            )

            # 记录PID
            self.status.update({
                'state': '播放中',
                'current_index': index,
                'current_file': os.path.relpath(file_path, self.music_dir),
                'pid': process.pid
            })
            logging.info(f"chery:Started music player with PID {process.pid}")

        except Exception as e:
            logging.error(f"chery:Error playing music: {str(e)}")
            self.stop_player()

    def play_next(self):
        index = self.status['current_index'] + 1
        self.play(index % len(self.music_files))

    def set_volume(self, volume):
        """设置音量"""
        try:
            # 使用pactl设置音量	pactl set-sink-volume @DEFAULT_SINK@ 80%
            runtime_dir = os.environ.get('XDG_RUNTIME_DIR', '/run/user/1000')
            server_address = f'unix:{runtime_dir}/pulse/native'
            env = os.environ.copy()
            env['PULSE_SERVER'] = server_address
            result = subprocess.run(f"pactl set-sink-volume {self.vol_device} {volume}%", shell=True, capture_output=True, text=True, env=env)
            if result.returncode != 0:
                logging.error(f"chery: vol info: {result.stdout} err: {result.stderr}, use first number to set vol_device value")
                return False
            logging.info(f"chery: vol = {volume}")
            self.status.update({'volume': volume})
            return True
        except subprocess.CalledProcessError as e:
            logging.error(f"chery:Error setting volume: {str(e)}, check cmd “pactl” is installed")
            return False

    def clean_status(self):
        self.status.update({
            'current_index': -1,
            'state': '已停止',
            'current_file': None,
            'pid': None
        })


def load_config(config):
    return MusicPlayer(config)
