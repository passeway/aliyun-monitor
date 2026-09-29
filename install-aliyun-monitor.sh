#!/bin/sh
# Reviewed release: 2026-09-29. Fresh installs only.
# Run with sh or bash, never pipe to a shell: interactive configuration needs a TTY.
# Self-contained runtime: only system packages, PyPI and official service APIs are used.
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
  sh install-aliyun-monitor.sh check    # 只读检查配置、云接口和 Bot 身份
支持：Ubuntu/Debian + systemd；Alpine + OpenRC，Python >= 3.10。
默认每 2 分钟巡检，日报北京时间 09:00（与系统时区无关）。
支持 Telegram /timers、/timer_add、/timer_del，每日定时开关机。
默认阈值：中国内地地域 18 GiB，香港及其他境外地域 180 GiB，可修改。
CDT 使用系统默认 DNS 和网络，不强制 IPv4/IPv6。
安装拒绝覆盖已有 /opt/scripts；不需要旧备份。
同一个 Telegram Bot Token 和同一组自动开关机任务只在一台服务器启用。
运行代码内置，无需下载任何个人 GitHub 仓库。
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
        apk add --no-cache python3 py3-pip py3-virtualenv ca-certificates tzdata util-linux openrc
    else
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip ca-certificates tzdata cron util-linux
    fi
    python3 -c 'import sys; assert sys.version_info >= (3,10), "需要 Python 3.10 或更新版本"'
    command -v flock >/dev/null || fail '缺少 flock，请安装 util-linux/flock 后重试。'
    mkdir "$TMP/runtime"
    cat > "$TMP/runtime/runtime.py" <<'PYRUNTIME'
"""Standalone ECS monitor, report and Telegram controller.
Uses Alibaba Cloud's official Python core SDK and the Telegram HTTPS API.
"""
import contextlib
import datetime as dt
import decimal
import fcntl
import json
import logging
from logging.handlers import RotatingFileHandler
import math
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile
import time

import requests
from aliyunsdkcore.client import AcsClient
from aliyunsdkcore.request import CommonRequest

ROOT = Path(__file__).resolve().parent
CONFIG = ROOT / 'config.json'
DISABLED = ROOT / '.automation-disabled'
CST = dt.timezone(dt.timedelta(hours=8))
LOG = logging.getLogger('aliyun-monitor')


def now():
    return dt.datetime.now(CST)


def setup_log(mode):
    LOG.setLevel(logging.INFO)
    handler = RotatingFileHandler(ROOT / (mode + '.log'), maxBytes=2*1024*1024,
                                  backupCount=3, encoding='utf-8')
    handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
    LOG.addHandler(handler)


def atomic_json(path, value):
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(value, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def read_json(path, default=None):
    if not path.exists() and default is not None: return default
    with path.open(encoding='utf-8') as f: return json.load(f)


@contextlib.contextmanager
def locked(name, wait=False):
    with (ROOT / name).open('a') as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        try: yield True
        finally: fcntl.flock(f, fcntl.LOCK_UN)


def load_config():
    cfg = read_json(CONFIG)
    if not isinstance(cfg, dict): raise ValueError('配置必须是 JSON 对象')
    users = cfg.get('users')
    if not isinstance(users, list) or not users: raise ValueError('配置中没有实例')
    ids = set()
    for u in users:
        if not isinstance(u, dict): raise ValueError('实例配置必须是对象')
        for key in ('instance_id', 'region', 'ak', 'sk'):
            if not isinstance(u.get(key), str) or not u[key].strip():
                raise ValueError('实例配置缺少字段：' + key)
            u[key] = u[key].strip()
        if not re.fullmatch(r'i-[A-Za-z0-9]+', u['instance_id']):
            raise ValueError('实例 ID 格式错误')
        if not re.fullmatch(r'[a-z][a-z0-9-]+', u['region']):
            raise ValueError('地域代码格式错误')
        for key in ('paused', 'disabled'):
            if key in u and type(u[key]) is not bool:
                raise ValueError(key + ' 必须是 true/false，不能是字符串或 null')
        if u['instance_id'] in ids: raise ValueError('实例 ID 重复')
        ids.add(u['instance_id'])
        if type(u.get('traffic_limit')) not in (int, float):
            raise ValueError('traffic_limit 必须是数字')
        limit = float(u['traffic_limit'])
        if not math.isfinite(limit) or limit <= 0: raise ValueError('阈值必须大于零')
        endpoint = u.get('bill_endpoint', 'business.ap-southeast-1.aliyuncs.com')
        if endpoint not in ('business.aliyuncs.com', 'business.ap-southeast-1.aliyuncs.com'):
            raise ValueError('账单 endpoint 不在支持列表中')
    if not isinstance(cfg.get('admin_users'), list) or not cfg['admin_users'] or any(type(x) is not int or x <= 0 for x in cfg['admin_users']):
        raise ValueError('admin_users 必须是非空正整数列表')
    telegram = cfg.get('telegram')
    if not isinstance(telegram, dict): raise ValueError('缺少 Telegram 配置')
    token = telegram.get('bot_token')
    if not isinstance(token, str) or not re.fullmatch(r'[0-9]+:[A-Za-z0-9_-]+', token.strip()):
        raise ValueError('Bot Token 格式错误')
    telegram['bot_token'] = token.strip()
    if not re.fullmatch(r'-?[1-9][0-9]*', str(telegram.get('chat_id', ''))):
        raise ValueError('chat_id 必须是非零数字 ID')
    telegram['chat_id'] = int(telegram['chat_id'])
    return cfg


def paused(user):
    return bool(user.get('paused') or user.get('disabled'))


def label(user):
    return user.get('name') or user['instance_id']


class ApiError(Exception):
    pass


def api(user, domain, version, action, params=None, region=None, readonly=True):
    attempts = 2 if readonly else 1
    for attempt in range(attempts):
        try:
            client = AcsClient(user['ak'].strip(), user['sk'].strip(), region or user['region'], auto_retry=False)
            req = CommonRequest()
            req.set_domain(domain)
            req.set_version(version)
            req.set_action_name(action)
            req.set_method('POST')
            req.set_protocol_type('https')
            req.set_connect_timeout(5)
            req.set_read_timeout(15)
            for key, value in (params or {}).items(): req.add_query_param(key, value)
            data = json.loads(client.do_action_with_exception(req).decode('utf-8'))
            if not isinstance(data, dict): raise ValueError('bad response')
            if data.get('Success') is False:
                code = re.sub(r'[^A-Za-z0-9_.-]', '', str(data.get('Code', 'Unsuccessful')))[:80]
                raise ApiError(action + ': ' + code)
            return data
        except ApiError:
            raise
        except Exception as error:
            # Never expose a signed URL, AK, Token or raw SDK exception text.
            code_fn = getattr(error, 'get_error_code', None)
            code = code_fn() if callable(code_fn) else type(error).__name__
            safe_code = re.sub(r'[^A-Za-z0-9_.-]', '', str(code))[:80]
            if attempt + 1 == attempts:
                raise ApiError(action + ': ' + safe_code) from None
            time.sleep(1)


def traffic_regions(user):
    data = api(user, 'cdt.aliyuncs.com', '2021-08-13', 'ListCdtInternetTraffic', region='cn-hangzhou')
    items = data.get('TrafficDetails')
    if not isinstance(items, list): raise ApiError('CDT 缺少有效流量明细')
    totals = {}
    for item in items:
        if not isinstance(item, dict) or not item.get('BusinessRegionId'):
            raise ApiError('CDT 明细缺少地域')
        value = float(item['Traffic'])
        if not math.isfinite(value) or value < 0: raise ApiError('CDT 流量数值异常')
        region = item['BusinessRegionId']
        totals[region] = totals.get(region, 0.0) + value / 1024**3
    return totals


def traffic_for(user, totals):
    if user['region'] not in totals:
        raise ApiError('该地域暂无 CDT 明细，不能作为零流量执行开关机')
    return totals[user['region']]


def instance_info(user):
    params = {'RegionId': user['region'], 'InstanceIds': json.dumps([user['instance_id']])}
    if user.get('resgroup'): params['ResourceGroupId'] = user['resgroup']
    data = api(user, 'ecs.aliyuncs.com', '2014-05-26', 'DescribeInstances', params)
    items = data.get('Instances', {}).get('Instance')
    if not isinstance(items, list): raise ApiError('ECS 状态响应不完整')
    return next((i for i in items if i.get('InstanceId') == user['instance_id']), None)


def power(user, action):
    if DISABLED.exists(): raise ApiError('本项目已停用，拒绝提交云端控制请求')
    if action not in ('StartInstance', 'StopInstance', 'RebootInstance'):
        raise ValueError('不支持的操作')
    params = {'InstanceId': user['instance_id']}
    # Do not force-stop, delete, or change billing mode.
    if action in ('StopInstance', 'RebootInstance'): params['ForceStop'] = 'false'
    api(user, 'ecs.aliyuncs.com', '2014-05-26', action, params, readonly=False)


def bill_endpoint(user):
    return user.get('bill_endpoint') or 'business.ap-southeast-1.aliyuncs.com'


def bill_api(user, action, params=None):
    region = 'cn-hangzhou' if bill_endpoint(user) == 'business.aliyuncs.com' else 'ap-southeast-1'
    data = api(user, bill_endpoint(user), '2017-12-14', action, params, region=region)
    if data.get('Success') is not True or not isinstance(data.get('Data'), dict):
        raise ApiError('账单接口未返回成功数据')
    return data['Data']


def items_of(data):
    items = data.get('Items')
    if isinstance(items, dict): items = items.get('Item')
    if not isinstance(items, list): raise ApiError('账单明细格式错误')
    return items


def instance_bills(user):
    result = []
    received = 0
    cycle = now().strftime('%Y-%m')
    for page in range(1, 1001):
        data = bill_api(user, 'QueryInstanceBill', {
            'BillingCycle': cycle, 'ProductCode': 'ecs',
            'PageNum': page, 'PageSize': 300, 'IsHideZeroCharge': 'false'})
        items = items_of(data)
        result.extend(items)
        received += len(items)
        count = int(data['TotalCount'])
        if count < 0 or count > 50000:
            raise ApiError('实例账单数量异常或超过旧接口50000条限制，拒绝返回不完整合计')
        if received >= count: return result
        if not items: raise ApiError('账单分页提前结束')
    raise ApiError('账单分页超出限制')


def sum_money(items):
    totals = {}
    for item in items:
        currency = item.get('Currency')
        if not currency: raise ApiError('账单缺少币种')
        value = decimal.Decimal(str(item['PretaxAmount']))
        if not value.is_finite(): raise ApiError('账单金额异常')
        totals[currency] = totals.get(currency, decimal.Decimal(0)) + value
    return totals


def money_text(totals, default='USD'):
    if not totals: totals = {default: decimal.Decimal(0)}
    return ' + '.join(f'{value:.2f} {currency}' for currency, value in sorted(totals.items()))


def default_currency(user):
    return 'CNY' if bill_endpoint(user) == 'business.aliyuncs.com' else 'USD'


def tg(cfg, method, payload):
    try:
        token = cfg['telegram']['bot_token']
        response = requests.post('https://api.telegram.org/bot' + token + '/' + method,
                                 json=payload, timeout=(5, 40))
        data = response.json()
        if not data.get('ok'): raise ValueError('Telegram rejected request')
        return data['result']
    except Exception:
        raise ApiError('Telegram ' + method + ' 请求失败') from None


def send(cfg, text, chat=None, keyboard=None):
    chat = chat if chat is not None else cfg['telegram']['chat_id']
    # Plain text avoids Markdown injection and escaping issues.
    for start in range(0, len(text), 3000):
        payload = {'chat_id': chat, 'text': text[start:start+3000]}
        if keyboard and start + 3000 >= len(text): payload['reply_markup'] = {'inline_keyboard': keyboard}
        tg(cfg, 'sendMessage', payload)


def notify(cfg, text):
    success = False
    try:
        send(cfg, text)
        success = True
    except ApiError as e: LOG.warning('%s', e)
    url = cfg.get('bark', {}).get('bark_url')
    if url:
        try:
            response = requests.post(url, json={'title': '阿里云监控', 'body': text}, timeout=(5,15))
            response.raise_for_status()
            if response.json().get('code') != 200: raise ValueError('Bark rejected')
            success = True
        except Exception: LOG.warning('Bark 通知失败')
    return success


def alert(cfg, state, key, text, cooldown=3600):
    when = time.time()
    if when - state.get(key, 0) >= cooldown and notify(cfg, text): state[key] = when


def monitor_one(cfg, user, state):
    if paused(user):
        LOG.info('[%s] 监控已暂停', label(user)); return
    total = traffic_for(user, traffic_regions(user))
    info = instance_info(user)
    if info is None: raise ApiError('实例不存在或不可见，无法恢复已删除实例')
    status = info['Status']
    limit = float(user['traffic_limit'])
    if total >= limit:
        if status == 'Running':
            power(user, 'StopInstance')
            LOG.warning('[%s] %.2f >= %.2f GiB，已提交停止请求', label(user), total, limit)
            alert(cfg, state, 'over_notice', f'🛑 {label(user)}：地域流量 {total:.2f}/{limit:g} GiB，已提交停止请求。', 86400)
        else:
            LOG.info('[%s] 超过阈值，状态 %s，不开机', label(user), status)
        return
    if status == 'Running':
        if state.pop('start_pending', False): notify(cfg, f'✅ {label(user)} 已恢复运行')
        state['start_failures'] = 0
        LOG.info('[%s] 流量安全(%.2f/%.2f GiB)，实例运行中', label(user), total, limit)
    elif status == 'Stopped':
        failures = state.get('start_failures', 0)
        if failures >= 3 and time.time() - state.get('last_start', 0) < 1800:
            LOG.info('[%s] 启动失败冷却中', label(user)); return
        state['last_start'] = time.time()
        state['start_failures'] = failures + 1
        try:
            power(user, 'StartInstance')
            state['start_pending'] = True
            LOG.info('[%s] 已提交启动请求，下一轮确认状态', label(user))
            alert(cfg, state, 'start_notice', f'▶️ {label(user)}：已提交启动请求；地域流量 {total:.2f} GiB。')
        except ApiError as e:
            LOG.warning('[%s] 启动失败：%s', label(user), e)
            alert(cfg, state, 'start_error_notice', f'⚠️ {label(user)} 启动失败：{e}。连续尝试 3 次后每 30 分钟重试。')
    else: LOG.info('[%s] 状态 %s，本轮不干预', label(user), status)


def monitor():
    if DISABLED.exists(): return
    with locked('monitor.lock') as acquired:
        if not acquired: return
        ids = [u['instance_id'] for u in load_config()['users']]
        path = ROOT / 'monitor_state.json'
        state = read_json(path, {})
        for iid in ids:
            # Shared lock with Bot prevents a stale monitor run undoing manual pause/stop.
            with locked('actions.lock') as acquired:
                if not acquired:
                    LOG.info('控制操作进行中，跳过本轮剩余实例'); break
                cfg = load_config()
                user = next((u for u in cfg['users'] if u['instance_id'] == iid), None)
                if DISABLED.exists(): break
                if user is None or paused(user):
                    if user: LOG.info('[%s] 监控已暂停', label(user))
                    continue
                entry = state.setdefault(iid, {})
                try: monitor_one(cfg, user, entry)
                except Exception as e:
                    error = str(e) if isinstance(e, ApiError) else type(e).__name__
                    entry['check_failures'] = entry.get('check_failures', 0) + 1
                    LOG.error('[%s] 巡检失败：%s', label(user), error)
                    if entry['check_failures'] >= 3:
                        entry['blind'] = True
                        alert(cfg, entry, 'error_notice', f'🚨 {label(user)}：连续 {entry["check_failures"]} 次巡检失败：{error}。本轮未执行流量止损，请人工核对。')
                else:
                    entry['check_failures'] = 0
                    if entry.pop('blind', False):
                        notify(cfg, f'✅ 监控恢复：{label(user)}，流量及状态已成功查询。')
                    entry.pop('error_notice', None)
                atomic_json(path, state)


def cached(cache, key, fn):
    if key not in cache:
        try: cache[key] = fn()
        except Exception as e: cache[key] = e
    value = cache[key]
    if isinstance(value, Exception): raise value
    return value


def status_text(user, cache):
    lines = ['👤 ' + label(user), '⏱ ' + now().strftime('%Y-%m-%d %H:%M:%S')]
    if paused(user): lines.append('⏸ 自动监控已暂停')
    try:
        info = instance_info(user)
        if info is None: lines.append('🖥 实例不存在或无权限查看')
        else:
            ip = info.get('EipAddress', {}).get('IpAddress')
            if not ip: ip = next(iter(info.get('PublicIpAddress', {}).get('IpAddress', [])), '无公网 IP')
            spec = f'{info.get("Cpu", "?")}C{float(info.get("Memory",0))/1024:g}G'
            lines.extend([f'🖥 {info["Status"]} ({spec})', f'🌐 IP: {ip}'])
    except Exception: lines.append('🖥 状态查询失败')
    try:
        totals = cached(cache, ('traffic', user['ak']), lambda: traffic_regions(user))
        amount = traffic_for(user, totals)
        limit = float(user['traffic_limit'])
        lines.append(f'📉 地域流量: {amount:.2f} GiB ({amount/limit*100:.1f}%) / 阈值 {limit:g} GiB')
    except Exception: lines.append('📉 地域流量: 查询失败或暂无明细')
    key = (user['ak'], bill_endpoint(user))
    try:
        items = cached(cache, ('bills',) + key, lambda: instance_bills(user))
        items = [i for i in items if i.get('InstanceID') == user['instance_id'] and i.get('ProductCode') == 'ecs']
        lines.append('💰 ECS当月账单（税前）: ' + money_text(sum_money(items), default_currency(user)))
    except Exception: lines.append('💰 ECS账单: 查询失败')
    try:
        data = cached(cache, ('balance',) + key, lambda: bill_api(user, 'QueryAccountBalance'))
        value = decimal.Decimal(str(data['AvailableAmount']).replace(',', ''))
        if not value.is_finite(): raise ValueError()
        lines.append(f'💳 账号余额: {value:.2f} {data.get("Currency") or default_currency(user)}')
    except Exception: lines.append('💳 账号余额: 查询失败')
    return '\n'.join(lines)


def report():
    # Separate from the cron entry's report.lock; also covers manual invocations.
    with locked('report-run.lock') as acquired:
        if not acquired: raise ApiError('另一日报任务正在执行')
        cfg, cache = load_config(), {}
        parts = ['📊 阿里云每日汇报\n📅 ' + now().strftime('%Y-%m-%d')]
        accounts = {}
        for user in cfg['users']:
            parts.append(status_text(user, cache))
            accounts.setdefault((user['ak'], bill_endpoint(user)), user)
        for index, user in enumerate(accounts.values(), 1):
            try:
                data = bill_api(user, 'QueryBillOverview', {'BillingCycle': now().strftime('%Y-%m')})
                text = money_text(sum_money(items_of(data)), default_currency(user))
            except Exception: text = '查询失败'
            parts.append(f'💰 账号{index}当月总账单（税前）: {text}')
        # Different keys for the same Alibaba account cannot be automatically deduplicated.
        text = '\n\n'.join(parts)
        LOG.info('已生成日报，实例数 %s，账号凭据组 %s', len(cfg['users']), len(accounts))
        if not notify(cfg, text): raise ApiError('日报所有通知渠道发送失败')


def execute_control(cfg, user, action):
    if DISABLED.exists(): raise ApiError('本项目已停用')
    if action in ('stop', 'pause'):
        user['paused'] = True
        atomic_json(CONFIG, cfg)
        if action == 'stop':
            info = instance_info(user)
            if info is None: raise ApiError('实例不存在或不可见；自动监控已暂停')
            if info['Status'] == 'Running': power(user, 'StopInstance')
            elif info['Status'] not in ('Stopped', 'Stopping'):
                raise ApiError('当前状态暂不允许关机；自动监控已暂停，请稍后重试')
    elif action == 'start_instance':
        total = traffic_for(user, traffic_regions(user))
        if total >= float(user['traffic_limit']): raise ApiError('地域流量已达到阈值，拒绝开机')
        info = instance_info(user)
        if info is None: raise ApiError('实例不存在或不可见')
        if info['Status'] == 'Stopped': power(user, 'StartInstance')
        elif info['Status'] not in ('Running', 'Starting'): raise ApiError('实例状态暂不允许启动')
        user['paused'] = False; user['disabled'] = False
        atomic_json(CONFIG, cfg)
    elif action == 'resume':
        user['paused'] = False; user['disabled'] = False
        atomic_json(CONFIG, cfg)
    elif action == 'reboot': power(user, 'RebootInstance')


def next_timer_time(at, current=None):
    if not re.fullmatch(r'(?:[01][0-9]|2[0-3]):[0-5][0-9]', at):
        raise ApiError('时间格式应为 HH:MM，例如 08:00 或 23:30')
    current = current or now()
    hour, minute = map(int, at.split(':'))
    due = current.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if due <= current: due += dt.timedelta(days=1)
    return due.timestamp()


def load_timers():
    timers = read_json(ROOT / 'timers.json', [])
    if not isinstance(timers, list): raise ApiError('定时计划文件格式错误')
    ids = set()
    for t in timers:
        if t.get('action') not in ('start_instance', 'stop') or not t.get('iid'):
            raise ApiError('定时计划操作无效')
        next_timer_time(t['at'])
        if t['id'] in ids or not math.isfinite(float(t['next_due'])):
            raise ApiError('定时计划数据异常')
        ids.add(t['id'])
    return timers


def timers_run():
    if DISABLED.exists(): return
    with locked('timers.lock') as acquired:
        if not acquired: return
        with locked('actions.lock') as acquired:
            if not acquired:
                LOG.info('巡检或控制操作正在执行，下一分钟重试定时计划')
                return
            cfg = load_config()
            users = {u['instance_id']:u for u in cfg['users']}
            timers = load_timers()
            for t in sorted(timers, key=lambda t:t['next_due']):
                if DISABLED.exists(): return
                current = now()
                if t['next_due'] > current.timestamp(): continue
                late = current.timestamp() - t['next_due']
                # Commit consumption before the cloud call: no duplicate execution after crash.
                t['next_due'] = next_timer_time(t['at'], current)
                atomic_json(ROOT / 'timers.json', timers)
                user = users.get(t['iid'])
                if user is None:
                    LOG.warning('计划 %s 的实例已从配置删除', t['id']); continue
                if late > 300:
                    notify(cfg, f'⚠️ 定时计划 {t["id"]}：{label(user)} {t["at"]} 已错过超过5分钟，本次跳过，保留下一天计划。')
                    continue
                try:
                    execute_control(cfg, user, t['action'])
                    text = f'⏰ {label(user)} 定时计划 {t["id"]} 已处理：{t["action"]}。请查询实例最终状态。'
                    LOG.info('%s', text)
                    notify(cfg, text)
                except Exception as error:
                    message = str(error) if isinstance(error, ApiError) else type(error).__name__
                    LOG.error('定时计划 %s 失败：%s', t['id'], message)
                    notify(cfg, f'⚠️ {label(user)} 定时计划 {t["id"]} 执行失败：{message}。本次不自动重放，请核对状态和监控暂停设置。')


HELP = '''/menu 选择实例及操作
/list 查看实例列表
/status [实例ID或唯一备注] 查询状态和账单
/start_instance <实例ID或备注> 开机并恢复监控（仍检查流量阈值）
/stop <实例ID或备注> 暂停自动监控并关机
/reboot <实例ID或备注> 重启
/pause <实例ID或备注> 暂停自动监控
/resume <实例ID或备注> 恢复自动监控
/timers [实例ID或备注] 查看每天重复的计划
/timer_add <实例ID或备注> start|stop HH:MM 添加北京时间计划
/timer_del <计划ID> 删除计划
所有控制操作需要二次确认。/resume 后监控将按阈值自动开关机。'''


class Controller:
    def __init__(self):
        self.pending = {}

    def keyboard(self, user):
        iid = user['instance_id']
        return [[{'text': '刷新状态', 'callback_data': 'status|' + iid}],
                [{'text': '开机/恢复监控', 'callback_data': 'start_instance|' + iid},
                 {'text': '暂停并关机', 'callback_data': 'stop|' + iid}],
                [{'text': '重启', 'callback_data': 'reboot|' + iid}],
                [{'text': '暂停监控', 'callback_data': 'pause|' + iid},
                 {'text': '恢复监控', 'callback_data': 'resume|' + iid}],
                [{'text': '定时计划', 'callback_data': 'timers|' + iid}]]

    def request_control(self, cfg, actor, chat, user, action):
        self.pending = {k:v for k,v in self.pending.items() if v['expires'] > time.time()}
        nonce = secrets.token_hex(8)
        self.pending[nonce] = dict(actor=actor, chat=chat, iid=user['instance_id'], action=action, expires=time.time()+120)
        descriptions = {'stop':'暂停自动监控并提交关机', 'start_instance':'检查地域流量后开机并恢复监控',
                        'reboot':'提交重启', 'pause':'暂停自动监控', 'resume':'恢复自动监控，可能自动开机或止损关机'}
        send(cfg, f'确认对 {label(user)} 执行：{descriptions[action]}？（2分钟内有效）', chat,
             [[{'text':'确认', 'callback_data':'confirm|' + nonce}, {'text':'取消', 'callback_data':'cancel|' + nonce}]])

    def apply(self, cfg, actor, chat, nonce):
        item = self.pending.get(nonce)
        if not item or item['actor'] != actor or item['chat'] != chat or item['expires'] < time.time():
            send(cfg, '确认已过期或不属于当前用户，请重新操作。', chat); return
        with locked('actions.lock') as acquired:
            if not acquired:
                send(cfg, '巡检正在执行，请稍后再次点击确认。', chat); return
            self.pending.pop(nonce, None)
            cfg = load_config()
            if DISABLED.exists(): raise ApiError('本项目已停用')
            if actor not in cfg['admin_users']: return
            user = next((u for u in cfg['users'] if u['instance_id'] == item['iid']), None)
            action = item['action']
            if user is None and action != 'timer_del': raise ApiError('实例已从配置移除')
            if action == 'timer_add':
                timers = load_timers()
                if any(t['iid'] == user['instance_id'] and t['at'] == item['at'] for t in timers):
                    raise ApiError('该实例在这个时刻已经有计划，请先删除旧计划')
                if len(timers) >= 100: raise ApiError('最多保存 100 条定时计划')
                timer_id = secrets.token_hex(6)
                timers.append(dict(id=timer_id, iid=user['instance_id'], action=item['timer_action'],
                    at=item['at'], next_due=next_timer_time(item['at']), created_by=actor))
                atomic_json(ROOT / 'timers.json', timers)
                send(cfg, f'已添加计划 {timer_id}：每天北京时间 {item["at"]}，{item["timer_action"]}。', chat)
                return
            if action == 'timer_del':
                timers = load_timers()
                filtered = [t for t in timers if t['id'] != item['timer_id']]
                if len(filtered) == len(timers): raise ApiError('计划已经不存在')
                atomic_json(ROOT / 'timers.json', filtered)
                send(cfg, '已删除计划；实例当前状态及暂停设置保持不变。', chat)
                return
            execute_control(cfg, user, action)
            send(cfg, '操作已处理。开关机/重启为异步请求，请刷新状态确认。', chat)

    def timer_command(self, cfg, actor, chat, command, arg):
        timers = load_timers()
        if command == 'timers':
            users = {u['instance_id']:u for u in cfg['users']}
            if arg:
                match = [u for u in cfg['users'] if arg.strip() in (u['instance_id'], u.get('name'))]
                if len(match) != 1: raise ApiError('请提供唯一实例 ID 或备注')
                timers = [t for t in timers if t['iid'] == match[0]['instance_id']]
            lines = ['⏰ 每日定时计划（北京时间）']
            for t in timers:
                name = label(users[t['iid']]) if t['iid'] in users else t['iid']
                action = '开机并恢复监控' if t['action'] == 'start_instance' else '暂停监控并关机'
                due = dt.datetime.fromtimestamp(t['next_due'], CST).strftime('%m-%d %H:%M')
                lines.append(f'{t["id"]} | {name} | 每天 {t["at"]} {action} | 下次 {due}')
            if not timers: lines.append('暂无计划')
            lines.append('添加：/timer_add 实例ID start 08:00 或 /timer_add 实例ID stop 23:00')
            lines.append('删除：/timer_del 计划ID')
            send(cfg, '\n'.join(lines), chat)
            return
        if command == 'timer_add':
            fields = arg.rsplit(None, 2)
            if len(fields) != 3 or fields[1] not in ('start','stop'):
                raise ApiError('用法：/timer_add 实例ID或备注 start|stop HH:MM')
            identity, action, at = fields
            next_timer_time(at)
            matches = [u for u in cfg['users'] if identity in (u['instance_id'],u.get('name'))]
            if len(matches) != 1: raise ApiError('请提供唯一实例 ID 或备注')
            user = matches[0]
            item = dict(iid=user['instance_id'], action='timer_add',
                        timer_action='start_instance' if action == 'start' else 'stop', at=at)
            description = f'为 {label(user)} 添加每天北京时间 {at} 的{("开机并恢复监控" if action == "start" else "暂停监控并关机")}计划'
        else:
            timer = next((t for t in timers if t['id'] == arg.strip()),None)
            if timer is None: raise ApiError('未找到这个计划 ID')
            item = dict(iid=timer['iid'], action='timer_del', timer_id=timer['id'])
            description = f'删除计划 {timer["id"]}'
        self.pending = {k:v for k,v in self.pending.items() if v['expires'] > time.time()}
        nonce = secrets.token_hex(8)
        item.update(actor=actor, chat=chat, expires=time.time()+120)
        self.pending[nonce] = item
        send(cfg, '确认' + description + '？（2分钟内有效）', chat,
             [[{'text':'确认','callback_data':'confirm|' + nonce},{'text':'取消','callback_data':'cancel|' + nonce}]])

    def handle(self, update):
        cfg = load_config()
        callback = update.get('callback_query')
        message = callback.get('message', {}) if callback else update.get('message', {})
        actor = (callback or message).get('from', {}).get('id')
        chat = message.get('chat', {}).get('id')
        if callback:
            try: tg(cfg, 'answerCallbackQuery', {'callback_query_id': callback['id']})
            except ApiError: pass
        if actor not in cfg['admin_users'] or chat is None: return
        try:
            if callback:
                command, _, arg = callback.get('data','').partition('|')
            else:
                text = message.get('text','').strip()
                first, _, arg = text.partition(' ')
                command = first.split('@')[0].lstrip('/')
            if command in ('confirm','cancel') and callback:
                if command == 'confirm': self.apply(cfg, actor, chat, arg)
                else:
                    item = self.pending.get(arg)
                    if item and item['actor'] == actor and item['chat'] == chat:
                        self.pending.pop(arg, None)
                    send(cfg, '已取消。', chat)
                return
            if command in ('timers','timer_add','timer_del'):
                self.timer_command(cfg, actor, chat, command, arg); return
            if command in ('start','help'):
                send(cfg, HELP, chat); return
            if command == 'list':
                send(cfg, '\n'.join(f'{label(u)} ({u["region"]}) {u["instance_id"]}' + (' [暂停]' if paused(u) else '') for u in cfg['users']), chat); return
            if command == 'menu' or (command == 'status' and not arg and len(cfg['users']) > 1):
                send(cfg, '请选择实例：', chat, [[{'text':label(u), 'callback_data':'status|' + u['instance_id']}] for u in cfg['users']]); return
            matches = [u for u in cfg['users'] if arg.strip() in (u['instance_id'], u.get('name'))]
            if not arg and len(cfg['users']) == 1: matches = cfg['users']
            if len(matches) != 1:
                send(cfg, '请用 /menu 选择实例，或提供唯一实例 ID。', chat); return
            user = matches[0]
            if command == 'status': send(cfg, status_text(user, {}), chat, self.keyboard(user))
            elif command in ('start_instance','stop','reboot','pause','resume'):
                self.request_control(cfg, actor, chat, user, command)
            else: send(cfg, HELP, chat)
        except Exception as error:
            message = str(error) if isinstance(error, ApiError) else type(error).__name__
            LOG.warning('Bot 操作失败：%s', message)
            send(cfg, '操作未完成：' + message + '。若操作是暂停并关机，暂停设置可能已经保存，请刷新核对。', chat)


def bot():
    with locked('bot.lock') as acquired:
        if not acquired: raise ApiError('本机已经有 Bot 进程')
        cfg = load_config()
        # Do not silently remove an existing webhook or consume another server's Bot.
        if tg(cfg, 'getWebhookInfo', {}).get('url'):
            raise ApiError('该 Bot 已设置 Webhook，请先确认并移除旧部署的 Webhook')
        controller = Controller()
        cursor_file = ROOT / 'bot_cursor.json'
        cursor = read_json(cursor_file, {'offset': 0})['offset']
        LOG.info('Bot 轮询已启动')
        while True:
            try:
                cfg = load_config()
                updates = tg(cfg, 'getUpdates', {'offset':cursor, 'timeout':25, 'allowed_updates':['message','callback_query']})
                for update in updates:
                    cursor = update['update_id'] + 1
                    # Persist first: never replay a power command after a process crash.
                    atomic_json(cursor_file, {'offset':cursor})
                    message = update.get('message') or update.get('callback_query', {}).get('message', {})
                    if not update.get('callback_query') and time.time() - message.get('date',0) > 120: continue
                    controller.handle(update)
            except Exception as error:
                LOG.warning('Bot 轮询失败：%s', str(error) if isinstance(error, ApiError) else type(error).__name__)
                time.sleep(5)


def check():
    cfg = load_config()
    timers = load_timers()
    print(f'本机配置检查通过：{len(cfg["users"])} 个实例，{len(timers)} 条计划；未调用云 API。')


def scheduled_report():
    if DISABLED.exists(): return
    current = now()
    if current.hour != 9 or current.minute > 10: return
    with locked('report-schedule.lock') as acquired:
        if not acquired or DISABLED.exists(): return
        path = ROOT / 'report_schedule.json'
        state = read_json(path, {})
        day = current.strftime('%Y-%m-%d')
        if state.get('day') != day: state = dict(day=day, attempts=0, sent=False)
        if state.get('sent') or state['attempts'] >= 3: return
        state['attempts'] += 1
        atomic_json(path, state)
        report()
        state['sent'] = True
        atomic_json(path, state)


def main(mode):
    os.umask(0o077)
    setup_log(mode)
    try:
        {'monitor':monitor, 'report':report, 'bot':bot, 'timers':timers_run, 'check':check, 'scheduled_report':scheduled_report}[mode]()
    except Exception as error:
        LOG.error('执行失败：%s', str(error) if isinstance(error, ApiError) else type(error).__name__)
        return 1
    return 0

PYRUNTIME
    cat > "$TMP/runtime/monitor.py" <<'PYWRAPPER'
from runtime import main
if __name__ == '__main__':
    raise SystemExit(main('monitor'))
PYWRAPPER
    cat > "$TMP/runtime/report.py" <<'PYWRAPPER'
from runtime import main
if __name__ == '__main__':
    raise SystemExit(main('report'))
PYWRAPPER
    cat > "$TMP/runtime/ecs_bot.py" <<'PYWRAPPER'
from runtime import main
if __name__ == '__main__':
    raise SystemExit(main('bot'))
PYWRAPPER
    cat > "$TMP/runtime/timers.py" <<'PYWRAPPER'
from runtime import main
if __name__ == '__main__':
    raise SystemExit(main('timers'))
PYWRAPPER
    cat > "$TMP/configure.py" <<'PYCONFIG'
import json, math, pathlib, sys
# Input from the actual terminal, not from a shell heredoc.

def ask(label, default=''):
    return input(label + (f' [{default}]' if default else '') + ': ').strip() or default

def required(label):
    while True:
        value = input(label + ': ').strip()
        if value: return value

def choice(label, values, default):
    while True:
        value = ask(label, default)
        if value in values: return value
        print('可选值：' + ', '.join(values))

token = required('Telegram Bot Token')
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
        ak = required('AccessKey ID')
        sk = required('AccessKey Secret')
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
    # Configuration complete; install the embedded runtime.
    install -d -m 700 "$TARGET"
    cp -a "$TMP/runtime/." "$TARGET/"
    if [[ $OS == alpine ]]; then python3 -m virtualenv "$TARGET/venv"
    else python3 -m venv "$TARGET/venv"; fi
    "$TARGET/venv/bin/python" -m pip install --no-cache-dir 'requests>=2.31,<3' 'aliyun-python-sdk-core>=2.16,<3'
    "$TARGET/venv/bin/python" -m pip check
    "$TARGET/venv/bin/python" -m compileall -q "$TARGET" -x '/venv/'
    "$TARGET/venv/bin/python" -c "import sys; sys.path.insert(0, '$TARGET'); from runtime import check; check()"
    touch "$TARGET/.automation-disabled"
    "$TARGET/venv/bin/python" -m pip freeze > "$TARGET/requirements-installed.txt"
    cat > "$TARGET/run-task.sh" <<'RUNNER'
#!/bin/sh
set -eu
cd /opt/scripts
export TZ=Asia/Shanghai
case "${1:-}" in
monitor) exec /opt/scripts/venv/bin/python /opt/scripts/monitor.py ;;
timers) exec /opt/scripts/venv/bin/python /opt/scripts/timers.py ;;
report) exec /opt/scripts/venv/bin/python -c 'from runtime import main; raise SystemExit(main("scheduled_report"))' ;;
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
    "$TARGET/venv/bin/python" -c "import sys; sys.path.insert(0, '$TARGET'); from runtime import check; check()"
    cron_read
    cp "$TMP/cron" "/root/crontab-before-aliyun-$(date +%Y%m%d-%H%M%S)"
    cron_clean
    cat >> "$TMP/clean" <<'CRON'
*/2 * * * * /opt/scripts/run-task.sh monitor >> /opt/scripts/cron-monitor.log 2>&1 #aliyun_monitor
* * * * * /opt/scripts/run-task.sh report >> /opt/scripts/cron-report.log 2>&1 #aliyun_monitor
* * * * * /opt/scripts/run-task.sh timers >> /opt/scripts/cron-timers.log 2>&1 #aliyun_monitor
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
    rm -f "$TARGET/.automation-disabled"
    echo '已启用。监控每 2 分钟；日报北京时间 09:00；Telegram Bot 后台运行。'
    echo '服务进程启动不代表 API 验证通过。请两分钟后查看 /opt/scripts/monitor.log。'
    ;;
stop)
    [[ -f $TARGET/.fresh-install-ready ]] || fail '未找到本安装器完成标记。'
    touch "$TARGET/.automation-disabled"
    cron_read
    cp "$TMP/cron" "/root/crontab-before-aliyun-stop-$(date +%Y%m%d-%H%M%S)"
    cron_clean
    crontab "$TMP/clean"
    if [[ $OS == alpine ]]; then
        rc-service "$SERVICE" stop
        rc-update del "$SERVICE" default
    else systemctl disable --now "$SERVICE"; fi
    flock -w 120 "$TARGET/actions.lock" true || fail '已停用，但旧操作尚未退出；请查看日志核对云端状态。'
    echo '已停用本项目定时任务与 Bot，文件保留；已提交给云端的异步操作不会撤回。'
    ;;
check)
    [[ -f $TARGET/.fresh-install-ready ]] || fail '尚未安装完成。'
    cd "$TARGET"
    "$TARGET/venv/bin/python" -c 'from runtime import main; raise SystemExit(main("check"))'
    ;;
status)
    if [[ $OS == alpine ]]; then rc-service "$SERVICE" status || true
    else systemctl status "$SERVICE" --no-pager || true; fi
    crontab -l || true
    ;;
*) usage; exit 1 ;;
esac
