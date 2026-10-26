#!/usr/bin/env python3
"""Reference models for the two-trader exchange (docs/mm_protocol.md).

  Exchange     the matching engine with its two-order ETF book, producing the
               exact messages rtl/mm/mm_book.sv sends, in the same order.
  MarketMaker  the trading strategy both traders run: host/mm_trader.py uses
               it live, and the testbench vectors for the FPGA trader
               (rtl/mm/mm_trader.sv) are generated from it.

Both work on FIX payloads (bytes) from tools/mm_fix.py. Trader ports are
0 = L (laptop, exchange PHY on JB) and 1 = F (FPGA trader, exchange PHY on
JC); BOTH means a market-data message that goes to both ports.
"""
import mm_fix as fx

L, F, BOTH = 0, 1, 2
BUY, SELL = "1", "2"
BID, OFFER, TRADE = "0", "1", "2"


def fair_cents(aapl_cents):
    """ETF fair value, exactly as the RTL computes it."""
    n = fx.FAIR_NUM * aapl_cents
    assert n < (1 << 22)
    return ((n * fx.DIV10_M) >> fx.DIV10_S) + fx.FAIR_OFF_CENTS


def wrap5(n):
    return n % 100000


class Order:
    def __init__(self, trader, clordid, price, ordid, qty):
        self.trader, self.clordid, self.price, self.ordid, self.qty = \
            trader, clordid, price, ordid, qty


class Exchange:
    """Two-order book for the ETF: one resting bid, one resting ask.

    New order (35=D):
      symbol not ETF, or bad side        -> 8 rejected
      crosses the resting opposite order -> trade at the resting price:
                                            8 filled to the taker, 8 filled to
                                            the maker, X with size 0 for the
                                            level; the resting order is gone
      ... but the resting order is own    -> 8 rejected (no self-trade)
      same side empty or price better     -> rests; the displaced order (if
                                            any) gets 8 canceled; 8 new to the
                                            sender; X with the new level
      otherwise                          -> 8 rejected
    Cancel (35=F) for a resting own order -> 8 canceled, X size 0
      for the trader's last filled order  -> 9 with 39=2, 102=0 (too late)
      anything else                      -> 9 with 39=8, 102=1 (unknown)
    Quantities are carried but not used: every order trades as one unit.
    34 is one counter for both ports, so each trader sees gaps.
    """

    def __init__(self):
        self.bid = None
        self.ask = None
        self.seq = 0
        self.next_ordid = 1
        self.last_filled = {L: None, F: None}   # (clordid, ordid) per trader
        self.fills = []                          # (taker, maker, price)

    def _seq(self):
        self.seq = wrap5(self.seq + 1)
        return self.seq

    def _ordid(self):
        o = self.next_ordid
        self.next_ordid = wrap5(o + 1)
        return o

    def _er(self, dst, ordid, clordid, exectype, status, sym, side, cents, qty):
        p, _ = fx.exec_report(self._seq(), ordid, clordid, exectype, status,
                              sym, side, cents, qty)
        return (dst, p)

    def _md(self, sym, entry, cents, size):
        p, _ = fx.market_data(self._seq(), sym, entry, cents, size)
        return (BOTH, p)

    def aapl(self, cents):
        """The exchange prints an AAPL trade."""
        return [self._md(fx.SYM_AAPL, TRADE, cents, fx.QTY)]

    def on_payload(self, port, payload):
        d = fx.parse(payload)
        if d is None:
            return []
        if d[35] == "D":
            return self.on_order(port, d)
        if d[35] == "F":
            return self.on_cancel(port, d)
        return []

    def on_order(self, port, d):
        sym, side = d[55], d[54]
        price, qty = fx.price_cents(d[44]), int(d[38])
        clordid = int(d[11])
        out = []
        if sym != fx.SYM_ETF or side not in (BUY, SELL):
            return [self._er(port, 0, clordid, "8", "8", sym, side, price, qty)]
        opp = self.ask if side == BUY else self.bid
        crosses = opp is not None and (price >= opp.price if side == BUY else price <= opp.price)
        if crosses:
            if opp.trader == port:
                return [self._er(port, 0, clordid, "8", "8", sym, side, price, qty)]
            ordid = self._ordid()
            out.append(self._er(port, ordid, clordid, "F", "2", sym, side, opp.price, qty))
            out.append(self._er(opp.trader, opp.ordid, opp.clordid, "F", "2", sym,
                                SELL if side == BUY else BUY, opp.price, opp.qty))
            out.append(self._md(sym, OFFER if side == BUY else BID, opp.price, 0))
            self.last_filled[opp.trader] = (opp.clordid, opp.ordid)
            self.last_filled[port] = (clordid, ordid)
            self.fills.append((port, opp.trader, opp.price))
            if side == BUY:
                self.ask = None
            else:
                self.bid = None
            return out
        same = self.bid if side == BUY else self.ask
        better = same is None or (price > same.price if side == BUY else price < same.price)
        if not better:
            return [self._er(port, 0, clordid, "8", "8", sym, side, price, qty)]
        if same is not None:
            out.append(self._er(same.trader, same.ordid, same.clordid, "4", "4", sym,
                                side, same.price, same.qty))
        ordid = self._ordid()
        o = Order(port, clordid, price, ordid, qty)
        if side == BUY:
            self.bid = o
        else:
            self.ask = o
        out.append(self._er(port, ordid, clordid, "0", "0", sym, side, price, qty))
        out.append(self._md(sym, BID if side == BUY else OFFER, price, qty))
        return out

    def on_cancel(self, port, d):
        side, sym = d[54], d[55]
        clordid, orig = int(d[11]), int(d[41])
        same = None
        if sym == fx.SYM_ETF and side in (BUY, SELL):
            same = self.bid if side == BUY else self.ask
        if same is not None and same.trader == port and same.clordid == orig:
            if side == BUY:
                self.bid = None
            else:
                self.ask = None
            return [self._er(port, same.ordid, orig, "4", "4", sym, side, same.price, same.qty),
                    self._md(sym, BID if side == BUY else OFFER, same.price, 0)]
        lf = self.last_filled[port]
        if lf is not None and lf[0] == orig:
            p, _ = fx.cancel_reject(self._seq(), lf[1], clordid, orig, "2", "0")
        else:
            p, _ = fx.cancel_reject(self._seq(), 0, clordid, orig, "8", "1")
        return [(port, p)]


class MarketMaker:
    """The strategy both traders run.

    On an AAPL print: fair = 3/10 * AAPL + $20. Then, in this order,
      1. if the resting ETF ask is below fair and is not our own: buy it at
         its price; else if the resting bid is above fair and not ours: sell
         to it (one message);
      2. cancel our resting bid, then our resting ask, if any;
      3. if quoting: new bid at fair - half_spread, new ask at fair + half_spread.
    ETF market data keeps the book (a level with size 0 is gone). Execution
    reports for our ClOrdIDs update our order state: new -> active;
    filled / canceled / rejected -> gone. Reports for other ClOrdIDs and
    cancel rejects change nothing. The FPGA trader does exactly this.
    """

    def __init__(self, half_spread_cents=100, quoting=True):
        self.hs = half_spread_cents
        self.quoting = quoting
        self.aapl = None
        self.fair = None
        self.book = {BID: None, OFFER: None}   # price in cents or None
        self.own = {BUY: None, SELL: None}      # dict(clordid, price, active)
        self.seq = 0
        self.next_clordid = 1
        self.n_buys = self.n_sells = self.n_fills = 0

    def _seq(self):
        self.seq = wrap5(self.seq + 1)
        return self.seq

    def _clordid(self):
        c = self.next_clordid
        self.next_clordid = wrap5(c + 1)
        return c

    def _order(self, side, cents):
        c = self._clordid()
        self.own[side] = dict(clordid=c, price=cents, active=False)
        p, _ = fx.new_order(self._seq(), c, fx.SYM_ETF, side, fx.QTY, cents)
        return p

    def _cancel(self, side, orig):
        c = self._clordid()
        p, _ = fx.cancel(self._seq(), c, orig, fx.SYM_ETF, side)
        return p

    def own_at(self, side, cents):
        o = self.own[side]
        return o is not None and o["price"] == cents

    def on_payload(self, payload):
        d = fx.parse(payload)
        if d is None:
            return []
        t = d[35]
        if t == "X":
            cents, size = fx.price_cents(d[270]), int(d[271])
            if d[55] == fx.SYM_AAPL and d[269] == TRADE:
                return self.on_aapl(cents)
            if d[55] == fx.SYM_ETF and d[269] in (BID, OFFER):
                self.book[d[269]] = cents if size else None
            return []
        if t == "8":
            side, clordid = d[54], int(d[11])
            if d[150] == "F":
                self.n_fills += 1   # every report is for one of our orders
            o = self.own.get(side)
            if o is not None and o["clordid"] == clordid:
                if d[150] == "0":
                    o["active"] = True
                else:
                    self.own[side] = None
            return []
        return []

    def on_aapl(self, cents):
        self.aapl = cents
        self.fair = fair_cents(cents)
        out = []
        ask, bid = self.book[OFFER], self.book[BID]
        # Orders to cancel are decided before the pickoff order, which takes
        # over the "own order" slot of its side.
        cancels = [(side, self.own[side]["clordid"]) for side in (BUY, SELL)
                   if self.own[side] is not None]
        if ask is not None and ask < self.fair and not self.own_at(SELL, ask):
            out.append(self._order(BUY, ask))
            self.n_buys += 1
        elif bid is not None and bid > self.fair and not self.own_at(BUY, bid):
            out.append(self._order(SELL, bid))
            self.n_sells += 1
        for side, orig in cancels:
            out.append(self._cancel(side, orig))
            if self.own[side] is not None and self.own[side]["clordid"] == orig:
                self.own[side] = None
        if self.quoting:
            if self.fair > self.hs:
                out.append(self._order(BUY, self.fair - self.hs))
            out.append(self._order(SELL, self.fair + self.hs))
        return out


def demo(verbose=True, fpga_hs=200, laptop_hs=100, script=None):
    """Run the demo script with a fast FPGA (half-spread $2) and a slow laptop
    (half-spread $1) that reacts to each print only after the FPGA's whole
    burst has been processed.

    Returns (log, exchange). log is a list of (kind, port, payload):
    ("print", BOTH, cents), ("rx", port, payload) for a message a trader
    received, ("tx", port, payload) for one it sent, in the order they
    happen. The testbench vectors (tools/mm_vectors.py) are cut from it."""
    ex = Exchange()
    traders = {F: MarketMaker(fpga_hs), L: MarketMaker(laptop_hs)}
    log = []
    queue = {L: [], F: []}

    def deliver(msgs):
        for dst, p in msgs:
            for port in ((L, F) if dst == BOTH else (dst,)):
                log.append(("rx", port, p))
                queue[port] += traders[port].on_payload(p)

    for dollars in (script or fx.SCRIPT_DOLLARS):
        log.append(("print", BOTH, dollars * 100))
        deliver(ex.aapl(dollars * 100))
        for port in (F, L):                      # FPGA first, then the laptop
            while queue[port]:
                p = queue[port].pop(0)
                log.append(("tx", port, p))
                deliver(ex.on_payload(port, p))
    if verbose:
        names = {L: "laptop", F: "fpga", BOTH: "both"}
        for kind, port, p in log:
            if kind == "print":
                print(f"\n== AAPL ${p // 100}  (fair ${fair_cents(p) / 100:.2f}) ==")
            else:
                d = fx.parse(p)
                print(f"  {kind} {names[port]:6s} " +
                      " ".join(f"{k}={v}" for k, v in d.items() if k not in (8, 9, 10, 34)))
        print("\nfills (taker, maker, price):",
              [(names[a], names[b], f"${p / 100:.2f}") for a, b, p in ex.fills])
    return log, ex


if __name__ == "__main__":
    demo()
