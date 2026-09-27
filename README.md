# 阿里云监控 Bot 全新部署指南

## 支持环境

- Ubuntu / Debian：systemd。
- Alpine Linux：OpenRC。
- 使用 root 执行，安装时需要联网访问系统软件源、GitHub 和 PyPI。
- 自动安装 Python 等运行依赖，并创建独立虚拟环境。
- 需要 Python 3.10 或更新版本；如果旧系统软件源提供的版本过低，脚本会停止，不会自动升级整个系统。
- 全新部署不需要备份包；发现 `/opt/scripts` 已存在时会拒绝覆盖。

## 默认行为

| 项目 | 默认设置 |
| --- | --- |
| 流量监控 | 每 2 分钟执行一次 |
| 每日汇报 | 北京时间每天 09:00 |
| 中国内地地域阈值 | 18 GiB，可修改 |
| 香港及其他境外地域阈值 | 180 GiB，可修改 |
| 流量统计 | 按账号、地域分别统计，同地域多实例共享该地域流量值 |
| 账单 | 实例 ECS 账单、账号当月税前总账单 |
| CDT 网络 | 使用系统默认 DNS 和网络，不强制 IPv4 或 IPv6 |
| 安装完成后 | 不自动启用，执行 `start` 后启用 |

阈值是脚本的关机设置，不是免费额度承诺。CDT 数据可能延迟更新，每 2 分钟巡检并不代表流量数据每 2 分钟刷新。

实例监控启用、查询成功且流量低于阈值时，脚本会尝试启动处于 `Stopped` 状态的实例；达到阈值时会尝试停止运行中的实例。启动能否成功取决于云端资源及接口结果，不能恢复已删除的实例。

## 1. 上传安装脚本

将下载的 `install-aliyun-monitor.sh` 通过 SFTP 上传到新服务器：

```text
/root/install-aliyun-monitor.sh
```

以下命令在服务器终端执行。不要使用 `curl | sh`，安装配置需要交互输入。

## 2. 安装与配置

Ubuntu、Debian、Alpine 都使用：

```bash
sh /root/install-aliyun-monitor.sh install
```

按提示填写：

1. Telegram Bot Token。
2. 接收通知的 Chat ID。
3. 有权控制实例的 Telegram 用户 ID，多个用逗号分隔；这里不能填写群组 ID。
4. Bark 推送 URL，可留空。
5. 实例备注、地域代码和实例 ID。
6. AccessKey ID、AccessKey Secret，以及国际站或中国站账号类型。
7. 地域关机阈值、资源组 ID（可留空）。
8. 是否继续添加实例；后续实例可复用上一实例的账号。

Token 和密钥输入不回显，保存在 `/opt/scripts/config.json`。不要公开分享该文件。

安装器从参考项目的固定提交下载运行脚本并校验 SHA256，再应用地域统计和账单等适配。依赖安装失败时应先查看报错；不要删除现有目录后盲目重试。

## 3. 启用 Bot 和定时任务

同一个 Bot Token 和同一组自动开关机任务，只在一台服务器启用。如果是迁移，先停用旧机器上的 Bot 和本项目定时任务。

```bash
sh /root/install-aliyun-monitor.sh start
```

服务启动后，等待约 2 分钟查看监控日志。服务显示运行，不等于云 API、权限和网络检查已经通过。

## 4. 查看状态

```bash
sh /root/install-aliyun-monitor.sh status
```

## 5. 查看日志

查看最近 30 行监控日志：

```bash
tail -n 30 /opt/scripts/monitor.log
```

查看 Bot 日志：

```bash
tail -n 30 /opt/scripts/bot.log
```

查看日报日志：

```bash
tail -n 30 /opt/scripts/report.log
```

持续观察监控日志，按 `Ctrl+C` 退出：

```bash
tail -f /opt/scripts/monitor.log
```

查看定时任务启动时的错误输出：

```bash
tail -n 30 /opt/scripts/cron-monitor.log
tail -n 30 /opt/scripts/cron-report.log
```

首次执行前，部分日志文件可能还不存在。

## 6. 立即发送一次日报

以下命令会实际发送日报：

```bash
TZ=Asia/Shanghai /opt/scripts/venv/bin/python /opt/scripts/report.py
```

手动发送不受定时日报的每日标记限制。

## 7. 立即执行一次巡检

以下命令会执行实际监控逻辑，可能触发实例开机或超流量关机：

```bash
/opt/scripts/run-task.sh monitor
```

如果上一轮巡检仍在运行，监控脚本的锁会阻止重叠执行。

## 8. 修改配置

```bash
vi /opt/scripts/config.json
```

例如，`traffic_limit` 是关机阈值，`paused` 或 `disabled` 为 `true` 时会跳过该实例巡检。

修改后检查 JSON 语法，不输出配置中的密钥：

```bash
/opt/scripts/venv/bin/python -m json.tool /opt/scripts/config.json > /dev/null
```

仅在检查无报错后重新加载 Bot：

```bash
sh /root/install-aliyun-monitor.sh start
```

`start` 同时确保本项目定时任务已启用。监控和日报脚本在下次运行时读取新配置。

## 9. 查看定时任务

```bash
crontab -l
```

本项目的两条任务：

```cron
*/2 * * * * /opt/scripts/run-task.sh monitor >> /opt/scripts/cron-monitor.log 2>&1 #aliyun_monitor
* * * * * /opt/scripts/run-task.sh report >> /opt/scripts/cron-report.log 2>&1 #aliyun_monitor
```

日报入口每分钟检查一次北京时间，仅在 09:00 执行日报，并使用日期标记防止重复触发。无需修改服务器系统时区。

如果服务器在 09:00 未运行，此版本不会自动补发；定时发送失败也不会在当日自动补发，可用第 6 节命令手动发送。

## 10. 停用整套监控

```bash
sh /root/install-aliyun-monitor.sh stop
```

该命令停用 Bot 和本项目定时任务，保留脚本、配置及其他 cron 任务。已经开始的巡检不会被强制中断，仍可能执行完当前动作。

重新启用：

```bash
sh /root/install-aliyun-monitor.sh start
```

## 11. 仅重启 Bot

仅重启 Bot 不改变定时任务。

### Ubuntu / Debian

```bash
systemctl restart aliyun-ecs-bot
systemctl status aliyun-ecs-bot --no-pager
```

查看服务日志：

```bash
journalctl -u aliyun-ecs-bot -n 50 --no-pager
```

### Alpine

```bash
rc-service aliyun-ecs-bot restart
rc-service aliyun-ecs-bot status
```

查看 Bot 日志：

```bash
tail -n 50 /opt/scripts/bot.log
```

## 12. 查看帮助

```bash
sh /root/install-aliyun-monitor.sh --help
```

