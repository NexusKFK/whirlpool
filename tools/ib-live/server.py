#!/usr/bin/env python3
"""IBKR 实时持仓看板。

只读本机 IB Gateway（127.0.0.1:4001），绝不下单、不碰订单接口。
客户端 ID 93（91 留给 holdings_local）。
用法：python3 server.py   然后浏览器打开 http://127.0.0.1:8899
"""
import asyncio
import datetime
import functools
import json
import math
import os
import threading
import time
import zoneinfo
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

asyncio.set_event_loop(asyncio.new_event_loop())  # Python 3.14 下必须在 import ib_insync 之前
from ib_insync import IB  # noqa: E402

HOST = os.environ.get('IB_HTTP_HOST', '127.0.0.1')
PORT = int(os.environ.get('IB_HTTP_PORT', '8899'))
GW_HOST = os.environ.get('IB_GW_HOST', '127.0.0.1')
GW_PORT = int(os.environ.get('IB_GW_PORT', '4001'))
CLIENT_ID = 93
RETRY_SECONDS = 10


ET = zoneinfo.ZoneInfo('America/New_York')


def _nth_weekday(year, month, weekday, n):
    first = datetime.date(year, month, 1)
    return first + datetime.timedelta(days=(weekday - first.weekday()) % 7 + 7 * (n - 1))


def _easter(year):
    """格里历复活节日期；Good Friday 是它的前两天。"""
    a, b, c = year % 19, year // 100, year % 100
    d, e = b // 4, b % 4
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = c // 4, c % 4
    l = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * l) // 451
    return datetime.date(year, (h + l - 7 * m + 114) // 31,
                         (h + l - 7 * m + 114) % 31 + 1)


@functools.lru_cache(maxsize=8)
def _nyse_holidays(year):
    """NYSE Rule 7.2 的常规休市日，与 App 的 MarketClock 使用同一套规则。"""
    def observed(month, day, saturday_rule=True):
        date = datetime.date(year, month, day)
        if date.weekday() == 5:
            return date - datetime.timedelta(days=1) if saturday_rule else None
        if date.weekday() == 6:
            return date + datetime.timedelta(days=1)
        return date

    may31 = datetime.date(year, 5, 31)
    memorial_day = may31 - datetime.timedelta(days=may31.weekday())
    days = {d for d in (observed(1, 1, False), observed(6, 19),
                        observed(7, 4), observed(12, 25)) if d is not None}
    days.update((_nth_weekday(year, 1, 0, 3),       # Martin Luther King Jr. Day
                 _nth_weekday(year, 2, 0, 3),       # Washington's Birthday
                 memorial_day,
                 _nth_weekday(year, 9, 0, 1),       # Labor Day
                 _nth_weekday(year, 11, 3, 4),      # Thanksgiving
                 _easter(year) - datetime.timedelta(days=2)))
    return frozenset(days)


@functools.lru_cache(maxsize=8)
def _nyse_early_closes(year):
    """感恩节次日、平安夜和 7 月 3 日；周末或休市日不算提前收盘日。"""
    holidays = _nyse_holidays(year)
    days = {_nth_weekday(year, 11, 3, 4) + datetime.timedelta(days=1)}
    for month, day in ((12, 24), (7, 3)):
        date = datetime.date(year, month, day)
        if date.weekday() < 5 and date not in holidays:
            days.add(date)
    return frozenset(days)


def regular_close_minutes(day):
    """返回常规收盘的美东分钟数；周末和节假日返回 None。"""
    if day.weekday() >= 5 or day in _nyse_holidays(day.year):
        return None
    return 780 if day in _nyse_early_closes(day.year) else 960


def regular_close_time(day):
    minutes = regular_close_minutes(day)
    if minutes is None:
        raise ValueError(f'not an NYSE trading day: {day}')
    return datetime.datetime.combine(day, datetime.time(minutes // 60, minutes % 60), tzinfo=ET)


def us_phase(now=None):
    """美东时段：盘中 9:30 至常规收盘，盘前 4:00–9:30，其余收盘。"""
    now = now or datetime.datetime.now(ET)
    close = regular_close_minutes(now.date())
    if close is None:
        return 'closed'
    mins = now.hour * 60 + now.minute
    if 570 <= mins < close:
        return 'open'
    if 240 <= mins < 570:
        return 'pre'
    return 'closed'


def expected_close_session(now):
    """当前应展示的最近常规收盘日；收盘五分钟后才把今天算作已收盘。"""
    day = now.date()
    while True:
        close = regular_close_minutes(day)
        if close is not None:
            close_time = regular_close_time(day) + datetime.timedelta(minutes=5)
            if now >= close_time:
                return day
        day -= datetime.timedelta(days=1)


def refresh_seconds():
    """按美东市场时钟节流:盘中 30s,盘前(4:00–9:30)120s,盘后与隔夜 300s。
    面板月亮开着时(最近 90s 内带 extended=1 的请求),盘前/盘后也按 30s 拉。"""
    now = datetime.datetime.now(ET)
    with _lock:
        extended = time.time() - _state.get('extended_seen', 0.0) < 90
    base = {'open': 30, 'pre': 120, 'closed': 300}[us_phase(now)]
    return 30 if extended else base


PAGE = Path(__file__).with_name('page.html')
LAST_SNAPSHOT = Path(__file__).with_name('last_snapshot.json')   # 网关不在时的最后快照
LAST_CLOSE = Path(__file__).with_name('last_close.json')         # 最近一次常规收盘快照
ALLOWED_HOSTS = {f'127.0.0.1:{PORT}', f'localhost:{PORT}', f'[::1]:{PORT}'}

SUMMARY_TAGS = ('NetLiquidation', 'TotalCashValue', 'SettledCash', 'AvailableFunds')

_state = {'connected': False, 'time': None, 'error': None, 'account': None,
          'pnl': None, 'summary': {}, 'positions': [], 'extended_seen': 0.0}
_close_state = None
_close_prices = {}          # conId -> 最近一个常规收盘价
_close_prices_session = None
_close_attempts = {}        # conId -> 本收盘日已尝试次数
_close_retry_at = {}        # conId -> 下次允许重试的时间
MAX_CLOSE_ATTEMPTS = 6
_lock = threading.Lock()


def put(**kw):
    with _lock:
        _state.update(kw)


def persist_last():
    """网关在线时把完整状态原子落盘;下次启动连不上就用它回填展示。"""
    with _lock:
        snap = json.loads(json.dumps(_state, ensure_ascii=False))
    if not snap.get('positions'):
        return   # 空持仓不落盘:Gateway 重连后组合事件会晚到,别让空帧毁掉 fallback 好数据
    try:
        tmp = LAST_SNAPSHOT.with_suffix('.tmp')
        tmp.write_text(json.dumps(snap, ensure_ascii=False))
        tmp.replace(LAST_SNAPSHOT)
    except Exception:
        pass


def restore_last() -> bool:
    """启动即断连时回填最后快照(标记 connected=False),面板有东西可看。"""
    try:
        snap = json.loads(LAST_SNAPSHOT.read_text())
    except Exception:
        return False
    if not snap.get('positions'):
        return False
    snap['connected'] = False
    snap['error'] = 'gateway down, showing last snapshot'
    with _lock:
        _state.update(snap)
    return True


def restore_close() -> bool:
    """回填最近一次常规收盘快照。它不依赖网关,重启后仍可展示。"""
    global _close_state
    try:
        snap = json.loads(LAST_CLOSE.read_text())
    except Exception:
        return False
    if not snap.get('positions'):
        return False
    snap['mode'] = 'close'
    with _lock:
        _close_state = snap
    return True


def set_close_state(snap):
    global _close_state
    snap['mode'] = 'close'
    with _lock:
        _close_state = snap
    try:
        tmp = LAST_CLOSE.with_suffix('.tmp')
        tmp.write_text(json.dumps(snap, ensure_ascii=False))
        tmp.replace(LAST_CLOSE)
    except Exception:
        pass


def snapshot(extended=False):
    """月亮只管盘前盘后。盘中(9:30–常规收盘)无论月亮开关一律返回实时;
    月亮关时非盘中才返回最近常规收盘快照。"""
    with _lock:
        now = datetime.datetime.now(ET)
        live = extended or us_phase(now) == 'open'
        if live:
            src = _state
        elif _close_state is not None:
            src = _close_state
        else:
            # 收盘数据尚未准备好时明确返回空态，绝不把实时持仓标成 close。
            src = {'connected': _state.get('connected', False), 'time': None,
                   'error': 'close snapshot unavailable', 'account': _state.get('account'),
                   'pnl': None, 'summary': {}, 'positions': []}
        data = json.loads(json.dumps(src, ensure_ascii=False))
    data.pop('extended_seen', None)
    data['mode'] = 'live' if live else 'close'
    return data


def parse_opt(local_symbol):
    """'AAPL  270115C00250000' -> ('AAPL', '2027-01-15', 'C', 250.0)"""
    compact = local_symbol.replace(' ', '')
    under = local_symbol.split()[0]
    body = compact[len(under):]
    ymd, rest = body[:6], body[6:]
    return under, f'20{ymd[:2]}-{ymd[2:4]}-{ymd[4:6]}', rest[0], int(rest[1:]) / 1000.0


MONTHS = ('JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
          'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC')


def short_date(ymd):
    """'2027-01-15' -> '27JAN15'"""
    try:
        y, m, d = ymd.split('-')
        return f'{y[2:]}{MONTHS[int(m) - 1]}{d}'
    except Exception:
        return ymd


def finite(x):
    return x is not None and isinstance(x, (int, float)) and math.isfinite(x)


def close_price_pending(contracts, now):
    session = expected_close_session(now)
    if _close_prices_session != session:
        return True
    return any(c.conId not in _close_prices
               and _close_attempts.get(c.conId, 0) < MAX_CLOSE_ATTEMPTS
               and time.time() >= _close_retry_at.get(c.conId, 0.0)
               for c in contracts)


def ensure_close_prices(ib, contracts, now):
    """按需取常规收盘价;失败后逐步拉长冷却，单日最多试六次。"""
    global _close_prices, _close_prices_session, _close_attempts, _close_retry_at
    session = expected_close_session(now)
    if _close_prices_session != session:
        _close_prices = {}
        _close_attempts = {}
        _close_retry_at = {}
        _close_prices_session = session
    missing = [c for c in contracts if c.conId not in _close_prices
               and _close_attempts.get(c.conId, 0) < MAX_CLOSE_ATTEMPTS
               and time.time() >= _close_retry_at.get(c.conId, 0.0)]
    if not missing:
        return
    tickers = []
    for c in missing:
        attempts = _close_attempts.get(c.conId, 0) + 1
        _close_attempts[c.conId] = attempts
        _close_retry_at[c.conId] = time.time() + min(30 * attempts, 180)
        try:
            c.exchange = 'SMART'
            tickers.append((c, ib.reqMktData(c, '', snapshot=True, regulatorySnapshot=False)))
        except Exception:
            pass
    if tickers:
        deadline = time.time() + 5
        while time.time() < deadline:
            ib.sleep(0.2)
            if all(finite(getattr(t, 'close', None)) for _, t in tickers):
                break
        for c, t in tickers:
            px = getattr(t, 'close', None)
            if finite(px) and px > 0:
                _close_prices[c.conId] = px
            try:
                ib.cancelMktData(c)
            except Exception:
                pass


def build_rows(pos, subs, close_prices=None):
    close_mode = close_prices is not None

    def fields(label, kind, p=None, qty=None, last=None, mkt_value=None, cost_basis=None,
               unrealized=None, unrealized_pct=None, day=None, leg_count=None,
               net_cost=None, net_mark=None, spread_count=None):
        live_last = p.marketPrice if not close_mode and p and finite(p.marketPrice) else None
        live_value = p.marketValue if not close_mode and p and finite(p.marketValue) else None
        return {
            'label': label, 'kind': kind, 'secType': 'OPT' if kind != 'STK' else 'STK',
            'qty': qty if qty is not None else (p.position if p else 0.0),
            'last': last if last is not None else live_last,
            'mktValue': mkt_value if mkt_value is not None else live_value,
            'costBasis': cost_basis if cost_basis is not None else (p.averageCost * p.position if p and finite(p.averageCost * p.position) else None),
            'unrealized': unrealized, 'unrealizedPct': unrealized_pct, 'dayPnl': day,
            'legCount': leg_count, 'netCost': net_cost, 'netMark': net_mark,
            'spreadCount': spread_count,
        }

    def leg_day(p):
        ps = subs.get(p.contract.conId)
        return ps.dailyPnL if ps is not None and finite(ps.dailyPnL) else None

    def sum_or_none(values):
        vals = [v for v in values if v is not None]
        return sum(vals) if vals else None

    def price_of(p):
        if close_mode:
            px = close_prices.get(p.contract.conId)
            return px if finite(px) and px > 0 else None
        return p.marketPrice if finite(p.marketPrice) else None

    rows = []
    opt_legs = {}   # (under, expiry) -> [(p, right, strike, close_price)]
    for p in pos:
        c = p.contract
        if c.secType == 'OPT':
            px = price_of(p) if close_mode else None
            try:
                under, date, right, strike = parse_opt(c.localSymbol)
                opt_legs.setdefault((under, date), []).append((p, right, strike, px))
            except Exception:
                opt_legs.setdefault((c.localSymbol.strip(), ''), []).append((p, '?', None, px))
        else:
            cb = p.averageCost * p.position if finite(p.averageCost * p.position) else None
            if close_mode:
                px = price_of(p)
                mv = px * p.position if px is not None else None
                un = mv - cb if mv is not None and cb is not None else None
            else:
                px = None
                mv = None
                un = p.unrealizedPNL if finite(p.unrealizedPNL) else None
            pct = un / abs(cb) * 100 if un is not None and cb and abs(cb) > 0 else None
            rows.append(fields(c.symbol, 'STK', p=p, last=px, mkt_value=mv, cost_basis=cb,
                               unrealized=un, unrealized_pct=pct, day=leg_day(p)))

    for (under, date), legs in sorted(opt_legs.items()):
        rights = {r for _, r, _, _ in legs}
        signs = {p.position > 0 for p, _, _, _ in legs}
        strikes = {s for _, _, s, _ in legs}
        # 垂直价差:同标的同到期、同权型、一买一卖、行权价不同、两边张数相同 → 合成一行
        if (len(legs) == 2 and len(rights) == 1 and signs == {True, False}
                and len(strikes) == 2 and date
                and len({abs(p.position) for p, _, _, _ in legs}) == 1):
            (pl, rl, sl, pxl), (ps, rs, ss, pxs) = sorted(legs, key=lambda x: x[2])
            label = f"{under} {sl:g}/{ss:g}{rl} {short_date(date)}"
            cb_l = pl.averageCost * pl.position if finite(pl.averageCost * pl.position) else 0.0
            cb_s = ps.averageCost * ps.position if finite(ps.averageCost * ps.position) else 0.0
            net_cost = cb_l + cb_s
            if close_mode:
                if all(px is not None for _, _, _, px in legs):
                    net_mark = sum(px * 100 * p.position for p, _, _, px in legs)
                    un = net_mark - net_cost
                else:
                    net_mark = None
                    un = None
            else:
                net_mark = sum(p.marketValue for p, _, _, _ in legs if finite(p.marketValue))
                un = sum_or_none([p.unrealizedPNL if finite(p.unrealizedPNL) else None
                                  for p, _, _, _ in legs])
            pct = un / abs(net_cost) * 100 if un is not None and abs(net_cost) > 0 else None
            day = sum_or_none([leg_day(p) for p, _, _, _ in legs])
            spread_count = int(abs(pl.position))
            rows.append(fields(label, 'SPREAD', qty=float(spread_count), last=None,
                               mkt_value=net_mark, cost_basis=net_cost,
                               unrealized=un, unrealized_pct=pct, day=day,
                               leg_count=2, net_cost=net_cost, net_mark=net_mark,
                               spread_count=spread_count))
        else:
            for p, right, strike, px in legs:
                label = f"{under} {strike:g}{right} {short_date(date)}" if strike is not None else under
                cb = p.averageCost * p.position if finite(p.averageCost * p.position) else None
                if close_mode:
                    mv = px * 100 * p.position if px is not None else None
                    un = mv - cb if mv is not None and cb is not None else None
                else:
                    mv = None
                    un = p.unrealizedPNL if finite(p.unrealizedPNL) else None
                pct = un / abs(cb) * 100 if un is not None and cb and abs(cb) > 0 else None
                rows.append(fields(label, 'OPT', p=p, last=px, mkt_value=mv, cost_basis=cb,
                                   unrealized=un, unrealized_pct=pct, day=leg_day(p)))

    rows.sort(key=lambda r: -abs(r['mktValue'] or 0))
    return rows


def update_close_state(ib, acct, pos, subs, pnl_data, summary, now=None):
    """只用常规收盘价构建快照；收盘后取得完整价格时保存正式快照。"""
    now = now or datetime.datetime.now(ET)
    expected_date = expected_close_session(now)
    expected = expected_date.isoformat()
    contracts = [p.contract for p in pos]
    missing_close = close_price_pending(contracts, now)
    complete = all(c.conId in _close_prices for c in contracts)
    # 盘中重建的是上一收盘快照；只有当前交易日收盘后的完整版本才算正式快照。
    provisional = expected_date != now.date() or not complete
    if (_close_state is None or _close_state.get('session') != expected
            or (_close_state.get('provisional') and (missing_close or not provisional))):
        ensure_close_prices(ib, contracts, now)
        complete = all(c.conId in _close_prices for c in contracts)
        provisional = expected_date != now.date() or not complete
        close_rows = build_rows(pos, subs, _close_prices)
        close_summary = dict(summary)
        cash = close_summary.get('TotalCashValue')
        values = [r.get('mktValue') for r in close_rows]
        if finite(cash) and all(finite(v) for v in values):
            close_summary['NetLiquidation'] = cash + sum(values)
        else:
            # 缺一条腿的收盘价时不能把那条腿按零计入净资产。
            close_summary['NetLiquidation'] = None
        set_close_state({
            'connected': True, 'time': regular_close_time(expected_date).isoformat(timespec='seconds'),
            'error': None, 'account': acct, 'pnl': pnl_data,
            'summary': close_summary, 'positions': close_rows,
            'provisional': provisional, 'session': expected,
        })


def collect(ib, acct, pnl, subs):
    pos = ib.portfolio()

    conids = {p.contract.conId for p in pos}
    for cid in conids - set(subs):
        try:
            subs[cid] = ib.reqPnLSingle(acct, '', cid)
        except Exception:
            pass
    for cid in set(subs) - conids:
        try:
            ib.cancelPnLSingle(subs.pop(cid))
        except Exception:
            pass

    summary = {}
    try:
        for av in ib.accountSummary(acct):
            if av.tag in SUMMARY_TAGS:
                try:
                    summary[av.tag] = float(av.value)
                except ValueError:
                    pass
    except Exception:
        pass

    rows = build_rows(pos, subs)

    pnl_data = None
    if pnl is not None:
        pnl_data = {
            'daily': pnl.dailyPnL if finite(pnl.dailyPnL) else None,
            'unrealized': pnl.unrealizedPnL if finite(pnl.unrealizedPnL) else None,
            'realized': pnl.realizedPnL if finite(pnl.realizedPnL) else None,
        }
    now = datetime.datetime.now(ET).isoformat(timespec='seconds')
    if not rows and _state.get('positions'):
        # Gateway 重连后组合事件晚到:这轮只有空组合。保留旧持仓,只刷新时间与盈亏,
        # 否则面板会闪成"无持仓"并把空快照当作好数据传播。
        put(connected=True, error=None, account=acct, time=now, pnl=pnl_data, summary=summary)
        return
    put(connected=True, error=None, account=acct, time=now,
        pnl=pnl_data, summary=summary, positions=rows)
    try:
        update_close_state(ib, acct, pos, subs, pnl_data, summary)
    except Exception:
        pass


def throttled_sleep(ib, seconds):
    """分片睡:月亮开关改变节流档位时,最多 1 秒就醒来按新节奏走,不用等满旧档。"""
    deadline = time.time() + seconds
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            return
        ib.sleep(min(1.0, remaining))
        if refresh_seconds() != seconds:
            return


def run_ib():
    restored = False
    while True:
        ib = IB()
        try:
            ib.connect(GW_HOST, GW_PORT, clientId=CLIENT_ID, readonly=True, timeout=20)
            acct = ib.managedAccounts()[0]
            pnl = ib.reqPnL(acct)
            subs = {}
            while ib.isConnected():
                collect(ib, acct, pnl, subs)
                persist_last()
                throttled_sleep(ib, refresh_seconds())
            put(connected=False, error='网关连接断开')
        except Exception as e:
            put(connected=False, error=f'{type(e).__name__}: {e}')
        # 启动即断连且内存无数据:回填最后快照,面板显示旧数据+未连接标注
        if not restored and not _state.get('positions'):
            restored = restore_last()
        try:
            ib.disconnect()
        except Exception:
            pass
        time.sleep(RETRY_SECONDS)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # 只服务本机回环:Host 白名单挡 DNS 重绑定;数据接口再要求自定义头,
        # 浏览器里别的网页发起的跨站 fetch 带不上这个头(会先卡在预检)。
        host = (self.headers.get('Host') or '').lower()
        if host not in ALLOWED_HOSTS:
            self._send(403, 'text/plain; charset=utf-8', b'forbidden')
            return
        path, _, query = self.path.partition('?')
        if path == '/api/snapshot.json':
            if self.headers.get('X-Whirlpool') != '1':
                self._send(403, 'text/plain; charset=utf-8', b'forbidden')
                return
            extended = parse_qs(query).get('extended', ['0'])[0] == '1'
            with _lock:
                # 月亮开着:盘后/盘前也按盘中节奏拉;关着:立刻回到收盘快照与慢节流
                _state['extended_seen'] = time.time() if extended else 0.0
            body = json.dumps(snapshot(extended=extended), ensure_ascii=False).encode()
            self._send(200, 'application/json; charset=utf-8', body)
        elif path == '/':
            try:
                self._send(200, 'text/html; charset=utf-8', PAGE.read_bytes())
            except Exception as e:
                self._send(500, 'text/plain; charset=utf-8', str(e).encode())
        else:
            self._send(404, 'text/plain; charset=utf-8', b'not found')

    def log_message(self, *a):
        pass


if __name__ == '__main__':
    # 被 Whirlpool 作为子进程拉起时(带 WHIRLPOOL_FEEDER_CHILD):app 强杀/崩溃后
    # PPID 会变 1,此时自己退出,不留孤儿。手动启动不带此变量,不受影响。
    if os.environ.get('WHIRLPOOL_FEEDER_CHILD'):
        def _parent_watchdog():
            while True:
                time.sleep(10)
                if os.getppid() == 1:
                    os._exit(0)
        threading.Thread(target=_parent_watchdog, daemon=True).start()

    restore_close()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f'看板已启动: http://{HOST}:{PORT}  (只读连接 {GW_HOST}:{GW_PORT}, clientId {CLIENT_ID})', flush=True)
    run_ib()
