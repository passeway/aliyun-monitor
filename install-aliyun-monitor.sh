#!/bin/sh
# Run with sh or bash, never pipe to a shell: interactive configuration needs a TTY.
# Reference project: https://github.com/10000ge10000/aliyun_monitor
if [ -z "${BASH_VERSION:-}" ]; then
    command -v bash >/dev/null 2>&1 || {
        if command -v apk >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then apk add --no-cache bash || exit 1;
        else echo '请先安装 bash，然后用 bash 执行本文件。' >&2; exit 1; fi
    }
    exec bash "$0" "$@"
fi
set -Eeuo pipefail
umask 077
TARGET=/opt/scripts
SERVICE=aliyun-ecs-bot
fail() { echo "错误：$*" >&2; exit 1; }
usage() {
cat <<'EOF'
全新部署阿里云监控与 Telegram Bot
  sh install-aliyun-monitor.sh install  # 交互配置与安装，默认不自动启用
  sh install-aliyun-monitor.sh start    # 正式启用，有开关 ECS 的能力
  sh install-aliyun-monitor.sh stop     # 停用 Bot 与本项目 cron
  sh install-aliyun-monitor.sh status   # 查看本机服务与定时任务
支持：Ubuntu/Debian + systemd；Alpine + OpenRC，Python >= 3.10。
默认每 2 分钟巡检，日报北京时间 09:00（与系统时区无关）。
默认阈值：中国内地地域 18 GiB，香港及其他境外地域 180 GiB，可修改。
CDT 使用系统默认 DNS 和网络，不强制 IPv4/IPv6。
安装拒绝覆盖已有 /opt/scripts；不需要旧备份。
同一个 Telegram Bot Token 和同一组自动开关机任务只在一台服务器启用。
配置路径 /opt/scripts/config.json；更改后重启 Bot 或重新运行 start。
EOF
}
[[ ${1:-install} != --help && ${1:-install} != -h ]] || { usage; exit 0; }
[[ $EUID == 0 ]] || fail '请使用 root。'
if [[ -f /etc/alpine-release ]]; then
    OS=alpine
    command -v rc-service >/dev/null || fail '需要 OpenRC，普通无 init 的容器不适用。'
elif [[ -f /etc/debian_version && -d /run/systemd/system ]]; then OS=debian
else fail '仅支持 Ubuntu/Debian + systemd 或 Alpine + OpenRC。'; fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'echo "执行失败，请检查上面的错误；不会宣称安装成功。" >&2' ERR
cron_read() {
    if ! LC_ALL=C crontab -l > "$TMP/cron" 2> "$TMP/error"; then
        grep -Eqi 'no crontab|No such file' "$TMP/error" || { cat "$TMP/error" >&2; return 1; }
        : > "$TMP/cron"
    fi
}
cron_clean() {
    python3 - "$TMP/cron" "$TMP/clean" <<'PYCRON'
import pathlib, sys
src, dst = map(pathlib.Path, sys.argv[1:])
lines = []
for line in src.read_text().splitlines():
    ours = any(s in line for s in ('#aliyun_monitor', '/opt/scripts/monitor.py', '/opt/scripts/report.py', '/opt/scripts/run-task.sh'))
    if not (ours and line.strip() and not line.lstrip().startswith('#')):
        lines.append(line)
dst.write_text('\n'.join(lines) + '\n')
PYCRON
}
case ${1:-install} in
install)
    [[ -t 0 ]] || fail '请先保存脚本，再在交互终端执行；不要使用 curl | sh。'
    [[ ! -e $TARGET ]] || fail '/opt/scripts 已存在，本脚本不会覆盖；请在新服务器部署。'
    [[ ! -e /etc/systemd/system/$SERVICE.service && ! -e /etc/init.d/$SERVICE ]] || fail '已经存在同名服务。'
    if [[ $OS == alpine ]]; then
        apk add --no-cache python3 py3-pip py3-virtualenv ca-certificates curl tzdata util-linux openrc
    else
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip ca-certificates curl tzdata cron util-linux
    fi
    python3 -c 'import sys; assert sys.version_info >= (3,10), "需要 Python 3.10 或更新版本"'
    mkdir "$TMP/runtime"
    echo '下载参考项目的三个运行脚本，并核对已适配版本的 SHA256……'
    curl --fail --location --retry 2 --connect-timeout 10 --max-time 90 "https://raw.githubusercontent.com/10000ge10000/aliyun_monitor/fab4985392aa7566ed0dd2ca5c8b86f2560afec2/src/monitor.py" -o "$TMP/runtime/monitor.py"
    echo "ac033b8409a94f256db13f322e044eefc29c42e67a1511a7cbe1b1a5c9910231  $TMP/runtime/monitor.py" | sha256sum -c -
    curl --fail --location --retry 2 --connect-timeout 10 --max-time 90 "https://raw.githubusercontent.com/10000ge10000/aliyun_monitor/fab4985392aa7566ed0dd2ca5c8b86f2560afec2/src/report.py" -o "$TMP/runtime/report.py"
    echo "c1556fe19b654a6eb37175d8f73d0695f91c881f799d912f5622468a848b68e8  $TMP/runtime/report.py" | sha256sum -c -
    curl --fail --location --retry 2 --connect-timeout 10 --max-time 90 "https://raw.githubusercontent.com/10000ge10000/aliyun_monitor/fab4985392aa7566ed0dd2ca5c8b86f2560afec2/src/ecs_bot.py" -o "$TMP/runtime/ecs_bot.py"
    echo "1a38e490e447a0900cffe6b8d3b6a4899d86ac35109041007ce4333d974ba4de  $TMP/runtime/ecs_bot.py" | sha256sum -c -
    # Fixed upstream commit + hashes; do not bypass source integrity checks.
    cat > "$TMP/runtime/monitor_support.py" <<'PYSUPPORT'
import datetime
import json
import math
from decimal import Decimal
from aliyunsdkcore.client import AcsClient
from aliyunsdkcore.request import CommonRequest


def region_bytes(data, region):
    items = data.get('TrafficDetails')
    if not isinstance(items, list):
        raise ValueError('CDT 未返回有效流量明细')
    total, found = 0.0, False
    for item in items:
        if not isinstance(item, dict) or not item.get('BusinessRegionId'):
            raise ValueError('CDT 明细缺少地域，停止本次判断')
        if item['BusinessRegionId'] == region.strip():
            value = float(item['Traffic'])
            if not math.isfinite(value) or value < 0:
                raise ValueError('CDT 流量数值异常')
            total += value
            found = True
    if not found:
        raise ValueError('CDT 暂无该地域明细，不能按零流量自动开机')
    return total


def billing_request(ak, sk, endpoint, action, params):
    client = AcsClient(ak.strip(), sk.strip(), 'ap-southeast-1')
    request = CommonRequest()
    request.set_domain(endpoint)
    request.set_version('2017-12-14')
    request.set_action_name(action)
    request.set_method('POST')
    request.set_protocol_type('https')
    request.set_connect_timeout(5)
    request.set_read_timeout(15)
    for k, v in params.items(): request.add_query_param(k, v)
    data = json.loads(client.do_action_with_exception(request).decode())
    if data.get('Success') is not True:
        raise ValueError('账单接口未返回成功状态')
    return data['Data']


def bill_items(data):
    raw = data.get('Items')
    if isinstance(raw, dict): raw = raw.get('Item')
    if not isinstance(raw, list): raise ValueError('账单明细格式错误')
    return raw


def sum_bill(items, default='USD'):
    currencies = {i.get('Currency') or default for i in items}
    if len(currencies) > 1: raise ValueError('同一汇总出现多币种')
    total = sum((Decimal(str(i['PretaxAmount'])) for i in items), Decimal('0'))
    if not total.is_finite(): raise ValueError('账单金额异常')
    return float(total), next(iter(currencies), default)


def instance_bill(ak, sk, endpoint, instance_id):
    found = []
    cycle = datetime.datetime.now().strftime('%Y-%m')
    for page in range(1, 1001):
        data = billing_request(ak, sk, endpoint, 'QueryInstanceBill', {
            'BillingCycle': cycle, 'ProductCode': 'ecs', 'InstanceID': instance_id,
            'PageNum': page, 'PageSize': 300, 'IsHideZeroCharge': 'false'})
        items = bill_items(data)
        found.extend(i for i in items if i.get('InstanceID') == instance_id and i.get('ProductCode') == 'ecs')
        count = int(data['TotalCount'])
        if page * 300 >= count:
            return sum_bill(found, 'CNY' if endpoint == 'business.aliyuncs.com' else 'USD')
        if not items: raise ValueError('账单分页提前结束')
    raise ValueError('账单页数异常')


def account_summary(users):
    lines, seen = [], set()
    for u in users:
        endpoint = u.get('bill_endpoint') or 'business.ap-southeast-1.aliyuncs.com'
        key = (u['ak'].strip(), endpoint)
        if key in seen: continue
        seen.add(key)
        try:
            data = billing_request(u['ak'], u['sk'], endpoint, 'QueryBillOverview', {
                'BillingCycle': datetime.datetime.now().strftime('%Y-%m')})
            amount, currency = sum_bill(bill_items(data), 'CNY' if endpoint == 'business.aliyuncs.com' else 'USD')
            lines.append(f'💰 账号{len(seen)}当月总账单（税前）: {amount:.2f} {currency}')
        except Exception:
            lines.append(f'💰 账号{len(seen)}当月总账单: 查询失败')
    return '\n'.join(lines)
PYSUPPORT
    python3 - "$TMP/runtime" <<'PYPATCH'
import ast, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
for name in ('monitor.py', 'report.py', 'ecs_bot.py'):
    p = root / name
    text = p.read_text()
    start = text.index('_orig_getaddrinfo = socket.getaddrinfo')
    end = text.index('socket.getaddrinfo = _getaddrinfo_ipv4_only', start) + len('socket.getaddrinfo = _getaddrinfo_ipv4_only')
    text = text[:start] + 'from monitor_support import region_bytes, instance_bill, account_summary' + text[end:]
    text = text.replace('set_connect_timeout(5000)', 'set_connect_timeout(5)').replace('set_read_timeout(15000)', 'set_read_timeout(15)')
    if name == 'monitor.py':
        old = "sum(d.get('Traffic', 0) for d in data_traffic.get('TrafficDetails', []))"
        assert text.count(old) == 1
        text = text.replace(old, "region_bytes(data_traffic, user['region'])")
    elif name == 'ecs_bot.py':
        old = 'sum(item.get("Traffic", 0) for item in data.get("TrafficDetails", []))'
        assert text.count(old) == 1
        text = text.replace(old, 'region_bytes(data, self.region)')
        a, b = text.index('    def get_current_bill('), text.index('    def get_account_balance(')
        text = text[:a] + """    def get_current_bill(self, instance_id: str, bill_endpoint: str = "business.ap-southeast-1.aliyuncs.com") -> Optional[float]:
        try:
            return instance_bill(self.ak, self.sk, bill_endpoint, instance_id)[0]
        except Exception as error:
            logger.warning("查询实例账单失败: %s", type(error).__name__)
            return None

""" + text[b:]
        text = text.replace('💰 账单:', '💰 ECS账单:').replace('📉 流量:', '📉 地域流量:')
    else:
        old = "sum(d.get('Traffic', 0) for d in traffic_data.get('TrafficDetails', []))"
        assert text.count(old) == 1
        text = text.replace(old, 'region_bytes(traffic_data, target_region)')
        a, b = text.index('            # 2. BSS'), text.index('            # 2.5 ')
        text = text[:a] + """            bill_amount, bill_currency = -1, 'USD'
            try:
                bill_amount, bill_currency = instance_bill(user['ak'], user['sk'], bill_endpoint, target_id)
            except Exception as error:
                logger.warning("实例账单查询失败: %s", type(error).__name__)

""" + text[b:]
        text = text.replace("ecs_params = {'PageSize': 50, 'RegionId': target_region}", "ecs_params = {'PageSize': 50, 'RegionId': target_region, 'InstanceIds': json.dumps([target_id])}")
        text = text.replace('    final_msg = ', '    report_lines.append(account_summary(users))\n    final_msg = ', 1)
        text = text.replace('💰 账单:', '💰 ECS账单:').replace('📉 流量:', '📉 地域流量:')
    ast.parse(text)
    p.write_text(text)
PYPATCH
    cat > "$TMP/configure.py" <<'PYCONFIG'
import getpass, json, math, pathlib, sys
# Input from the actual terminal, not from a shell heredoc.

def ask(label, default=''):
    return input(label + (f' [{default}]' if default else '') + ': ').strip() or default

def required(label, secret=False):
    while True:
        value = (getpass.getpass(label + ': ') if secret else input(label + ': ')).strip()
        if value: return value

def choice(label, values, default):
    while True:
        value = ask(label, default)
        if value in values: return value
        print('可选值：' + ', '.join(values))

print('输入仅保存在本机配置文件；AK/SK 和 Token 不会回显。')
token = required('Telegram Bot Token', True)
chat_id = required('接收通知的 Chat ID（群组可为负数）')
while True:
    try:
        admins = list(dict.fromkeys(int(x) for x in required('控制机器人的 Telegram 用户 ID，多个用逗号分隔').replace('，', ',').split(',')))
        if all(x > 0 for x in admins): break
    except ValueError: pass
    print('管理员必须是正整数用户 ID，不能填群组 ID。')
bark = ask('Bark 推送 URL（可留空）')
users = []
while True:
    name = required('实例备注（如 香港 或 上海）')
    region = required('地域代码（如 cn-hongkong、cn-shanghai、ap-southeast-1）')
    iid = required('实例 ID（i- 开头）')
    if not iid.startswith('i-') or any(u['instance_id'] == iid for u in users):
        print('实例 ID 格式错误或重复，请重新输入该实例。'); continue
    if users and choice('复用上一实例的账号？y/n', ('y','n'), 'y') == 'y':
        ak, sk, endpoint, currency = (users[-1][k] for k in ('ak','sk','bill_endpoint','currency'))
    else:
        ak = required('AccessKey ID', True)
        sk = required('AccessKey Secret', True)
        account = choice('账号 international（国际站）/china（中国站）', ('international','china'), 'international')
        endpoint = 'business.ap-southeast-1.aliyuncs.com' if account == 'international' else 'business.aliyuncs.com'
        currency = '$' if account == 'international' else '¥'
    # Alibaba Cloud cn-* regions are mainland China, except cn-hongkong.
    mainland = region.startswith('cn-') and region != 'cn-hongkong'
    default = '18' if mainland else '180'
    while True:
        try:
            limit = float(ask('地域关机阈值 GiB（不是免费额度承诺）', default))
            if math.isfinite(limit) and limit > 0: break
        except ValueError: pass
        print('请输入大于零的数字。')
    users.append(dict(name=name, region=region, instance_id=iid, ak=ak, sk=sk,
        bill_endpoint=endpoint, currency=currency, traffic_limit=limit, quota=limit,
        resgroup=ask('资源组 ID（可留空）'), paused=False, disabled=False))
    if choice('继续添加实例？y/n', ('y','n'), 'n') == 'n': break
config = dict(telegram=dict(bot_token=token,chat_id=chat_id), admin_users=admins,
    bark=dict(bark_url=bark), users=users)
p = pathlib.Path(sys.argv[1]); p.write_text(json.dumps(config, ensure_ascii=False, indent=2)); p.chmod(0o600)
print('配置完成。流量按账号+地域统计，同地域多实例共享同一流量值。')
PYCONFIG
    python3 "$TMP/configure.py" "$TMP/runtime/config.json"
    # All interactive input and source patching succeeded before committing directory.
    install -d -m 700 "$TARGET"
    cp -a "$TMP/runtime/." "$TARGET/"
    if [[ $OS == alpine ]]; then python3 -m virtualenv "$TARGET/venv"
    else python3 -m venv "$TARGET/venv"; fi
    "$TARGET/venv/bin/python" -m pip install --no-cache-dir 'requests>=2.31,<3' 'aliyun-python-sdk-core>=2.16,<3' 'aliyun-python-sdk-ecs>=4,<5' 'aliyun-python-sdk-bssopenapi>=2,<3' 'python-telegram-bot[job-queue]>=21,<23'
    "$TARGET/venv/bin/python" -m pip check
    "$TARGET/venv/bin/python" -m compileall -q "$TARGET" -x '/venv/'
    "$TARGET/venv/bin/python" -m pip freeze > "$TARGET/requirements-installed.txt"
    cat > "$TARGET/run-task.sh" <<'RUNNER'
#!/bin/sh
set -eu
cd /opt/scripts
export TZ=Asia/Shanghai
case "${1:-}" in
monitor) exec /opt/scripts/venv/bin/python /opt/scripts/monitor.py ;;
report)
    # Called every minute, but sends only once per Beijing date at 09:00.
    [ "$(date +%H:%M)" = 09:00 ] || exit 0
    exec 9>/opt/scripts/report.lock
    flock -n 9 || exit 0
    day=$(date +%F)
    [ "$(cat /opt/scripts/.report-day 2>/dev/null || true)" != "$day" ] || exit 0
    # Mark first: a failed send won't generate repeated reports that minute.
    echo "$day" > /opt/scripts/.report-day
    exec /opt/scripts/venv/bin/python /opt/scripts/report.py ;;
*) exit 2 ;;
esac
RUNNER
    chmod 700 "$TARGET/run-task.sh"
    if [[ $OS == alpine ]]; then
        cat > /etc/init.d/aliyun-ecs-bot <<'OPENRC'
#!/sbin/openrc-run
name="Aliyun ECS Telegram Bot"
supervisor="supervise-daemon"
command="/opt/scripts/venv/bin/python"
command_args="/opt/scripts/ecs_bot.py"
directory="/opt/scripts"
command_user="root"
respawn_delay=5
respawn_max=5
respawn_period=60
export TZ=Asia/Shanghai
umask 077
depend() { need net; }
OPENRC
        chmod 755 /etc/init.d/aliyun-ecs-bot
    else
        cat > /etc/systemd/system/aliyun-ecs-bot.service <<'SYSTEMD'
[Unit]
Description=Aliyun ECS Telegram Bot
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/scripts
Environment=TZ=Asia/Shanghai
ExecStart=/opt/scripts/venv/bin/python /opt/scripts/ecs_bot.py
Restart=on-failure
RestartSec=5
UMask=0077
[Install]
WantedBy=multi-user.target
SYSTEMD
        systemctl daemon-reload
    fi
    touch "$TARGET/.fresh-install-ready"
    echo '安装完成，尚未启用。确认旧机器没有使用同一 Bot/监控任务后，运行本脚本 start。'
    ;;
start)
    [[ -f $TARGET/.fresh-install-ready ]] || fail '未找到本安装器完成标记。'
    cron_read
    cp "$TMP/cron" "/root/crontab-before-aliyun-$(date +%Y%m%d-%H%M%S)"
    cron_clean
    cat >> "$TMP/clean" <<'CRON'
*/2 * * * * /opt/scripts/run-task.sh monitor >> /opt/scripts/cron-monitor.log 2>&1 #aliyun_monitor
* * * * * /opt/scripts/run-task.sh report >> /opt/scripts/cron-report.log 2>&1 #aliyun_monitor
CRON
    if [[ $OS == alpine ]]; then
        rc-update add crond default
        rc-service crond start
        rc-update add "$SERVICE" default
        rc-service "$SERVICE" restart
        rc-service "$SERVICE" status
    else
        systemctl enable --now cron
        systemctl enable "$SERVICE"
        systemctl restart "$SERVICE"
        systemctl is-active --quiet "$SERVICE"
    fi
    crontab "$TMP/clean"
    echo '已启用。监控每 2 分钟；日报北京时间 09:00；Telegram Bot 后台运行。'
    echo '服务进程启动不代表 API 验证通过。请两分钟后查看 /opt/scripts/monitor.log。'
    ;;
stop)
    cron_read
    cp "$TMP/cron" "/root/crontab-before-aliyun-stop-$(date +%Y%m%d-%H%M%S)"
    cron_clean
    crontab "$TMP/clean"
    if [[ $OS == alpine ]]; then
        rc-service "$SERVICE" stop
        rc-update del "$SERVICE" default
    else systemctl disable --now "$SERVICE"; fi
    echo '已停用本项目定时任务与 Bot。文件保留，正在运行的巡检可能仍需等待退出。'
    ;;
status)
    if [[ $OS == alpine ]]; then rc-service "$SERVICE" status || true
    else systemctl status "$SERVICE" --no-pager || true; fi
    crontab -l || true
    ;;
*) usage; exit 1 ;;
esac
