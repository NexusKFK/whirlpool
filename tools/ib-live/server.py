#!/usr/bin/env python3
"""IBKR 实时持仓看板。

只读本机 IB Gateway（127.0.0.1:4001），绝不下单、不碰订单接口。
客户端 ID 93（91 留给 holdings_local）。
用法：python3 server.py   然后浏览器打开 http://127.0.0.1:8899
"""
import asyncio
import datetime
import json
import math
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

asyncio.set_event_loop(asyncio.new_event_loop())  # Python 3.14 下必须在 import ib_insync 之前
from ib_insync import IB  # noqa: E402

HOST = os.environ.get('IB_HTTP_HOST', '127.0.0.1')
PORT = int(os.environ.get('IB_HTTP_PORT', '8899'))
GW_HOST = os.environ.get('IB_GW_HOST', '127.0.0.1')
GW_PORT = int(os.environ.get('IB_GW_PORT', '4001'))
CLIENT_ID = 93
RETRY_SECONDS = 10


def refresh_seconds():
    """按美东市场时钟节流:盘中 30s,盘前(4:00–9:30)120s,盘后与隔夜 300s。
    盘后净值不是重点、期权 mark 不更新,慢拉即可;面板页脚同口径标注。
    面板的"盘后行情"月亮开着时(最近 90s 内带 extended=1 的请求),盘前/盘后也按 30s 拉。"""
    import zoneinfo
    tz = zoneinfo.ZoneInfo('America/New_York')
    now = datetime.datetime.now(tz)
    mins = now.hour * 60 + now.minute
    with _lock:
        extended = time.time() - _state.get('extended_seen', 0.0) < 90
    if now.weekday() >= 5:
        base = 300
    elif 570 <= mins < 960:
        base = 30
    elif 240 <= mins < 570:
        base = 120
    else:
        base = 300
    return 30 if extended else base
PAGE = Path(__file__).with_name('page.html')
LAST_SNAPSHOT = Path(__file__).with_name('last_snapshot.json')   # 网关不在时的最后快照
ALLOWED_HOSTS = {f'127.0.0.1:{PORT}', f'localhost:{PORT}', f'[::1]:{PORT}'}

SUMMARY_TAGS = ('NetLiquidation', 'TotalCashValue', 'SettledCash', 'AvailableFunds')

_state = {'connected': False, 'time': None, 'error': None, 'account': None,
          'pnl': None, 'summary': {}, 'positions': [], 'extended_seen': 0.0}
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


def snapshot():
    with _lock:
        return json.loads(json.dumps(_state, ensure_ascii=False))


def parse_opt(local_symbol):
    """'AAPL  270115C00250000' -> ('AAPL', '2027-01-15', 'C', 250.0)"""
    compact = local_symbol.replace(' ', '')
    under = local_symbol.split()[0]
    body = compact[len(under):]
    ymd, rest = body[:6], body[6:]
    return under, f'20{ymd[:2]}-{ymd[2:4]}-{ymd[4:6]}', rest[0], int(rest[1:]) / 1000.0


def finite(x):
    return x is not None and isinstance(x, (int, float)) and math.isfinite(x)


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

    def fields(label, kind, p=None, qty=None, last=None, mkt_value=None, cost_basis=None,
               unrealized=None, unrealized_pct=None, day=None, leg_count=None,
               net_cost=None, net_mark=None):
        return {
            'label': label, 'kind': kind, 'secType': 'OPT' if kind != 'STK' else 'STK',
            'qty': qty if qty is not None else (p.position if p else 0.0),
            'last': last if last is not None else (p.marketPrice if p and finite(p.marketPrice) else None),
            'mktValue': mkt_value if mkt_value is not None else (p.marketValue if p and finite(p.marketValue) else None),
            'costBasis': cost_basis if cost_basis is not None else (p.averageCost * p.position if p and finite(p.averageCost * p.position) else None),
            'unrealized': unrealized, 'unrealizedPct': unrealized_pct, 'dayPnl': day,
            'legCount': leg_count, 'netCost': net_cost, 'netMark': net_mark,
        }

    def leg_day(p):
        ps = subs.get(p.contract.conId)
        return ps.dailyPnL if ps is not None and finite(ps.dailyPnL) else None

    def sum_or_none(values):
        vals = [v for v in values if v is not None]
        return sum(vals) if vals else None

    rows = []
    opt_legs = {}   # (under, expiry) -> [(p, right, strike)]
    for p in pos:
        c = p.contract
        if c.secType == 'OPT':
            try:
                under, date, right, strike = parse_opt(c.localSymbol)
                opt_legs.setdefault((under, date), []).append((p, right, strike))
            except Exception:
                opt_legs.setdefault((c.localSymbol.strip(), ''), []).append((p, '?', None))
        else:
            cb = p.averageCost * p.position if finite(p.averageCost * p.position) else None
            un = p.unrealizedPNL if finite(p.unrealizedPNL) else None
            pct = un / abs(cb) * 100 if un is not None and cb and abs(cb) > 0 else None
            rows.append(fields(c.symbol, 'STK', p=p, unrealized=un, unrealized_pct=pct, day=leg_day(p)))

    for (under, date), legs in sorted(opt_legs.items()):
        rights = {r for _, r, _ in legs}
        signs = {p.position > 0 for p, _, _ in legs}
        strikes = {s for _, _, s in legs}
        # 垂直价差:同标的同到期、同权型、一买一卖、行权价不同 → 合成一行
        if len(legs) == 2 and len(rights) == 1 and signs == {True, False} and len(strikes) == 2 and date:
            (pl, rl, sl), (ps, rs, ss) = sorted(legs, key=lambda x: x[2])
            label = f"{under} {sl:g}/{ss:g}{rl} {date[2:]}"
            cb_l = pl.averageCost * pl.position if finite(pl.averageCost * pl.position) else 0.0
            cb_s = ps.averageCost * ps.position if finite(ps.averageCost * ps.position) else 0.0
            net_cost = cb_l + cb_s
            net_mark = sum(p.marketValue for p, _, _ in legs if finite(p.marketValue))
            un = sum_or_none([p.unrealizedPNL if finite(p.unrealizedPNL) else None for p, _, _ in legs])
            pct = un / abs(net_cost) * 100 if un is not None and abs(net_cost) > 0 else None
            day = sum_or_none([leg_day(p) for p, _, _ in legs])
            rows.append(fields(label, 'SPREAD', qty=2.0, mkt_value=net_mark, cost_basis=net_cost,
                               unrealized=un, unrealized_pct=pct, day=day,
                               leg_count=2, net_cost=net_cost, net_mark=net_mark))
        else:
            for p, right, strike in legs:
                label = f"{under} {strike:g}{right} {date[2:]}" if strike is not None else under
                cb = p.averageCost * p.position if finite(p.averageCost * p.position) else None
                un = p.unrealizedPNL if finite(p.unrealizedPNL) else None
                pct = un / abs(cb) * 100 if un is not None and cb and abs(cb) > 0 else None
                rows.append(fields(label, 'OPT', p=p, unrealized=un, unrealized_pct=pct, day=leg_day(p)))

    rows.sort(key=lambda r: -abs(r['mktValue'] or 0))

    pnl_data = None
    if pnl is not None:
        pnl_data = {
            'daily': pnl.dailyPnL if finite(pnl.dailyPnL) else None,
            'unrealized': pnl.unrealizedPnL if finite(pnl.unrealizedPnL) else None,
            'realized': pnl.realizedPnL if finite(pnl.realizedPnL) else None,
        }
    now = datetime.datetime.now().isoformat(timespec='seconds')
    if not rows and _state.get('positions'):
        # Gateway 重连后组合事件晚到:这轮只有空组合。保留旧持仓,只刷新时间与盈亏,
        # 否则面板会闪成"无持仓"并把空快照当作好数据传播。
        put(connected=True, error=None, account=acct, time=now, pnl=pnl_data, summary=summary)
        return
    put(connected=True, error=None, account=acct, time=now,
        pnl=pnl_data, summary=summary, positions=rows)


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
            if query == 'extended=1':
                # 面板月亮开关开着:喂料盘后/盘前也按盘中节奏向网关拉
                with _lock:
                    _state['extended_seen'] = time.time()
            body = json.dumps(snapshot(), ensure_ascii=False).encode()
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

    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f'看板已启动: http://{HOST}:{PORT}  (只读连接 {GW_HOST}:{GW_PORT}, clientId {CLIENT_ID})', flush=True)
    run_ib()
