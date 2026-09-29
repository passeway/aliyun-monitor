# 阿里云监控 Bot 


## 支持环境

- Ubuntu / Debian：systemd。
- Alpine Linux：OpenRC。
- 使用 root 执行，安装时需要联网访问系统软件源和 PyPI。
- 自动安装 Python 等运行依赖，并创建独立虚拟环境。
- 需要 Python 3.10 或更新版本；如果旧系统软件源提供的版本过低，脚本会停止，不会自动升级整个系统。
- 全新部署不需要备份包；发现 `/opt/scripts` 已存在时会拒绝覆盖。

## 默认行为

| 项目 | 默认设置 |
| --- | --- |
| 流量监控 | 每 2 分钟执行一次 |
| 每日汇报 | 北京时间每天 09:00 |
| 定时开关机 | 支持每天重复的计划，按北京时间执行，每分钟检查 |
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

Token 和密钥输入时直接显示，配置保存在 `/opt/scripts/config.json`。不要公开分享该文件。

安装器内置独立实现的监控、日报和 Telegram Bot 运行代码，不下载或引用个人 GitHub 仓库。仅从系统软件源和 PyPI 安装运行依赖，使用阿里云官方核心 SDK 和 Telegram 官方 API。依赖安装失败时应先查看报错；不要删除现有目录后盲目重试。

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

本项目的三条任务：

```cron
*/2 * * * * /opt/scripts/run-task.sh monitor >> /opt/scripts/cron-monitor.log 2>&1 #aliyun_monitor
* * * * * /opt/scripts/run-task.sh report >> /opt/scripts/cron-report.log 2>&1 #aliyun_monitor
* * * * * /opt/scripts/run-task.sh timers >> /opt/scripts/cron-timers.log 2>&1 #aliyun_monitor
```

日报入口每分钟检查一次北京时间，在 09:00—09:10 的窗口发送；每日最多尝试 3 次，任一通知渠道成功后当天不再自动发送。无需修改服务器系统时区。

窗口内恢复运行可以补发；超过 09:10 或三次尝试均失败后，当天不再自动补发，可用第 6 节命令手动发送。网络超时、消息分段发送失败或进程中断时，重试可能重复部分消息；不承诺通知严格只送达一次。

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

## Telegram 命令

| 命令 | 功能 |
| --- | --- |
| `/start` 或 `/help` | 显示帮助 |
| `/menu` | 选择实例，查看状态及操作按钮 |
| `/list` | 查看实例列表 |
| `/status 实例ID或唯一备注` | 查询状态、地域流量及账单 |
| `/start_instance 实例ID或唯一备注` | 检查流量阈值后开机，并恢复监控 |
| `/stop 实例ID或唯一备注` | 暂停自动监控并关机，避免下一轮自动拉起 |
| `/reboot 实例ID或唯一备注` | 提交重启请求 |
| `/pause 实例ID或唯一备注` | 暂停自动监控 |
| `/resume 实例ID或唯一备注` | 恢复自动监控，后续可能按阈值自动开关机 |
| `/timers` | 查看全部每日定时计划 |
| `/timers 实例ID或唯一备注` | 查看单台实例的计划 |
| `/timer_add 实例ID或唯一备注 start HH:MM` | 添加每日定时开机计划 |
| `/timer_add 实例ID或唯一备注 stop HH:MM` | 添加每日定时关机计划 |
| `/timer_del 计划ID` | 删除计划 |

仅配置中的管理员可使用。控制操作须点击确认按钮，确认在 2 分钟内有效。开关机与重启是异步请求，需刷新状态确认最终结果。

### 定时开关机示例

以下命令发送给 Telegram Bot。将“上海”换成配置中的唯一备注或实例 ID。

每天北京时间 08:00 开机：

```text
/timer_add 上海 start 08:00
```

每天北京时间 23:00 关机：

```text
/timer_add 上海 stop 23:00
```

添加后点击 Bot 返回的“确认”按钮，计划才会保存。

查看计划及计划 ID：

```text
/timers
```

删除计划（替换为实际计划 ID，再点击确认）：

```text
/timer_del 计划ID
```

也可通过 `/menu` 选择实例，点击“定时计划”查看。

### 定时计划的行为

- 全部按北京时间（UTC+8）每天重复，与服务器系统时区无关。
- 每分钟检查一次，可能受接口耗时及巡检锁影响，不保证精确到秒。
- 计划保存到 `/opt/scripts/timers.json`，Bot 或服务器重启后保留。
- 定时关机先暂停自动监控，再提交停止请求，避免巡检立即重新开机。
- 定时开机检查地域流量阈值；查询失败、暂无地域明细或达到阈值时不启动。请求处理成功后恢复自动监控。
- 单独 `/pause` 只暂停流量巡检，不删除定时计划；如不希望计划再开机，请同时删除计划。
- 同一实例、同一时刻不能添加重复或互相冲突的计划。
- 计划执行失败会告警，本次不自动重放；下一天的计划保留。请按告警核对实例和监控暂停状态。
- 若错过执行时间不超过 5 分钟，会在下一轮尝试执行；超过 5 分钟则跳过本次并通知，避免机器恢复后执行过时的开关机操作。
- 删除计划不改变实例当前运行状态，也不改变监控的暂停设置。
- `stop` 会停用包含定时计划调度在内的本项目 cron，但不会删除计划文件；再次 `start` 时按上述超时规则处理。
- 这是新部署版本，不自动导入旧项目的计划文件。

查看定时计划运行日志：

```bash
tail -n 30 /opt/scripts/timers.log
tail -n 30 /opt/scripts/cron-timers.log
```

总账单按同一 AK 和账单节点去重；同一阿里云账号若使用不同 AK 配置，可能显示多组重复总账单，建议复用同一账号凭据。

## 验证范围

本次审查通过 Shell/Python 语法检查和 28 项模拟回归测试，覆盖配置校验、地域隔离、缺失明细保护、阈值边界、暂停停用、启动冷却、关机失败连续计数及恢复、账单分页、金额精度、文件锁、确认用户校验、定时跨日/防重复/过期处理、日报有限重试及只读自检。测试使用模拟云端响应，未操作真实 ECS。

尚未在真实 Ubuntu/Debian、Alpine 新机完成全量安装及云 API 联调；支持平台由安装分支实现，不能把本机测试当作所有发行版均已实测。

## 本次修正及只读自检

- 修复止损关机失败时连续失败计数被提前清零的问题；连续三轮失败会尝试通知。
- 实例操作、巡检和定时计划共享操作锁，避免暂停关机后被旧巡检立即开机。
- 安装后默认有停用标记；`start` 校验配置后启用，`stop` 阻止新操作并最多等待 120 秒让已有控制操作退出。已经提交给云端的请求无法撤回。
- 手动或定时关机先保存暂停状态；关机 API 失败也保持暂停，并提示核查。
- 账单分页提前结束或超过旧接口上限时显示失败，不返回不完整合计。
- AK/SK/Token 按要求在录入时显示；运行错误不输出签名 URL 或原始密钥。

安装后、启动前可以执行（不访问云 API，不开关机，不发送通知）：

```bash
sh /root/install-aliyun-monitor.sh check
sh /root/install-aliyun-monitor.sh start
sh /root/install-aliyun-monitor.sh status
```

`check` 只验证本机配置和定时文件，不能验证密钥权限、网络连通或余额接口权限。启动后检查日志，并用 `/status` 确认实际查询成功。默认的大陆 18 GiB、境外 180 GiB 是可修改的止损阈值；免费额度及计费请以账号控制台为准。

本文件和安装器用于**全新服务器部署**。现有 `/opt/scripts` 不会被覆盖，也不自动迁移旧版状态或计划。与原监控共存的展示面板应关闭自动启停，避免两个程序发出相反的操作。
