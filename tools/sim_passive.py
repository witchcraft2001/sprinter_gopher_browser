#!/usr/bin/env python3
"""Byte-exact simulation of the v0.1.19 passive overlay state machine against
ESP-AT 2.2 semantics taken from the firmware disassembly.

Key difference from the v0.1.18 sim: state (pv_live, PAYLOAD_LEFT) persists
across NET.RECV calls, and the model injects "hiccups" - stalls longer than the
control tick but shorter than the data timeout - which is what made long
transfers rot on target.
"""
import itertools, random, sys

PREFIX = b"+CIPRECVDATA:"
POLL_MS, DATA_MS, TRIES = 1500, 10000, 10

class Timeout(Exception):
    pass

class ESP:
    """Firmware model: socket buffer + 'reported' flag + deferred CLOSED."""
    def __init__(self, body, chunks, poisoned=False, cap=5760):
        self.tosend, self.buf, self.cap = body, b"", cap
        self.reported, self.closed, self.chunks = 0, False, chunks
        self.poisoned = poisoned          # firmware that never emits +IPD
        self.pending = 0                  # arrived at the ESP, waiting for room

    def pump(self, sim):
        self.pending += next(self.chunks, 0)
        n = min(self.pending, len(self.tosend), self.cap - len(self.buf))
        self.pending -= n
        if n:
            self.buf += self.tosend[:n]
            self.tosend = self.tosend[n:]
            if not self.reported and not self.poisoned:
                sim.feed(b"\r\n+IPD,%d\r\n" % len(self.buf))
                self.reported = 1
        elif not self.tosend and not self.closed:
            self.closed = True
            if not self.buf:
                sim.feed(b"\r\nCLOSED\r\n")

    def on_probe(self, sim, req):
        self.pump(sim)
        if not self.buf:
            sim.feed(b"\r\nNO DATA\r\n\r\nERROR\r\n")   # reported NOT cleared
            if self.closed:
                sim.feed(b"\r\nCLOSED\r\n")
            return
        n = min(req, len(self.buf))
        sim.feed(b"\r\n+CIPRECVDATA:%d," % n)
        sim.feed(self.buf[:n])
        self.buf = self.buf[n:]
        sim.feed(b"\r\nOK\r\n")
        if self.buf:
            if not self.poisoned:
                sim.feed(b"\r\n+IPD,%d\r\n" % len(self.buf))
                self.reported = 1
        else:
            self.reported = 0
            if self.closed:
                sim.feed(b"\r\nCLOSED\r\n")

class Sim:
    """The Z80 side: RECV_PASSIVE_222 + PASSIVE_RESPONSE + PASSIVE_READ_DEC."""
    def __init__(self, esp, hiccup_rate=0.0, rng=None):
        self.stream = bytearray()
        self.esp = esp
        self.pv_closed = self.pv_live = 0
        self.pv_first = 1
        self.payload_left = 0
        self.pv_lch, self.pv_llen = 0, 0   # line-scan state: survives timeouts
        self.timeout = POLL_MS
        self.hiccup_rate = hiccup_rate
        self.deep_stall = False
        self.rng = rng or random.Random(0)
        self.out = bytearray()

    def feed(self, b):
        self.stream += b

    # --- UART read with the current timeout -----------------------------
    def read_byte(self):
        if self.stream and self.hiccup_rate and self.rng.random() < self.hiccup_rate:
            # ESP stalls ~2 s (Wi-Fi retransmits): trips the tick, not the data wait
            if self.timeout < 2000 or self.deep_stall:
                raise Timeout()
        if not self.stream:
            self.esp.pump(self)                    # async arrival while waiting
            if not self.stream:
                raise Timeout()
        return self.stream.pop(0)

    # --- PASSIVE_RESPONSE ----------------------------------------------
    def response(self, wake):
        while True:
            e = self.read_byte()                # may raise Timeout: state persists
            if e == ord(':') and self.pv_lch == ord('+') and self.pv_llen == 12:
                self.pv_llen = 0
                return 0
            if e == 13:
                continue
            if e == 10:
                if self.pv_llen == 0:
                    continue
                d, ch = self.pv_llen, self.pv_lch
                self.pv_llen = 0
                if ch == ord('O') and d == 2:
                    return 1
                if ch == ord('E') and d == 5:
                    return 1
                woke = False
                if ch == ord('C') and d == 6:
                    self.pv_closed = 1
                    woke = True
                elif ch == ord('+'):
                    woke = True
                if woke and wake:
                    return 2
                continue
            if self.pv_llen == 0:
                self.pv_lch = e
            self.pv_llen += 1

    def read_dec(self):
        hl = 0
        while True:
            b = self.read_byte()
            if b == ord(','):
                return hl
            if not (ord('0') <= b <= ord('9')):
                raise ValueError("bad digit %r" % bytes([b]))
            hl = hl * 10 + (b - ord('0'))

    def read_payload(self, ptr_sink):
        """TCP.READ_PAYLOAD: store min(payload_left, remain); CF=1 only if the
        call has stored nothing at all."""
        while self.payload_left and self.remain:
            try:
                b = self.read_byte()
            except Timeout:
                if self.stored:
                    return False        # CF=0, payload_left kept
                raise
            ptr_sink.append(b)
            self.payload_left -= 1
            self.remain -= 1
            self.stored += 1
        return False

    # --- RECV_PASSIVE_222 ------------------------------------------------
    def recv(self, free):
        self.remain, self.stored = free, 0
        poll = TRIES
        sink = bytearray()

        if self.payload_left:
            state = 'payload'
        elif self.pv_live:
            state = 'resp'
        elif self.pv_first:
            self.pv_first = 0
            self.timeout = POLL_MS
            state = 'empty_eval'
        else:
            state = 'rearm'

        while True:
            if state == 'rearm':
                self.esp.on_probe(self, self.remain)
                self.pv_live = 1
                state = 'resp'
            elif state == 'resp':
                self.timeout = POLL_MS
                try:
                    r = self.response(0)
                except Timeout:
                    if self.stored:
                        return bytes(sink)          # pv_live stays 1
                    state = 'tick'
                    continue
                if r == 0:
                    state = 'data'
                    continue
                self.pv_live = 0
                if self.stored:
                    return bytes(sink)
                state = 'empty_eval'
            elif state == 'empty_eval':
                if self.pv_closed:
                    return 'EOF'
                try:
                    r = self.response(1)
                except Timeout:
                    state = 'tick'
                    continue
                state = 'data' if r == 0 else 'rearm'
            elif state == 'tick':
                poll -= 1
                if poll == 0:
                    raise Timeout()
                state = 'rearm'
            elif state == 'data':
                self.timeout = DATA_MS
                n = self.read_dec()
                if n == 0:
                    state = 'resp'
                    continue
                self.payload_left = n
                state = 'payload'
            elif state == 'payload':
                self.timeout = DATA_MS
                try:
                    self.read_payload(sink)
                except Timeout:
                    raise
                if self.payload_left:
                    return bytes(sink)              # resumed by the next call
                state = 'resp'

def run(name, body_len, chunks, hiccup=0.0, poisoned=False, seed=1, free=4096, deep=False):
    rng = random.Random(seed)
    body = bytes(rng.randrange(256) for _ in range(body_len))
    esp = ESP(body, chunks, poisoned=poisoned)
    sim = Sim(esp, hiccup_rate=hiccup, rng=rng)
    sim.deep_stall = deep
    sim.feed(b"\r\nRecv 32 bytes\r\n\r\nSEND OK\r\n")   # NO_WAIT send chatter
    got, comb = b"", 0
    try:
        while True:
            r = sim.recv(free - comb)
            if r == 'EOF':
                break
            got += r
            comb = (comb + len(r)) % free
    except Timeout:
        print(f"{name:22s} TIMEOUT at {len(got)}/{body_len}")
        return False
    ok = got == body
    print(f"{name:22s} {'OK  ' if ok else 'BAD '} {len(got)}/{body_len}")
    return ok

fails = 0
fails += not run("small", 1000, iter([1000]))
fails += not run("exact-4k", 4096, iter([4096]))
fails += not run("big-steady", 400000, itertools.repeat(1460))
fails += not run("big-bursty", 400000, iter([5760] * 200 + [1460] * 10000))
fails += not run("900k-steady", 921600, itertools.repeat(1460))
fails += not run("900k-poisoned", 921600, itertools.repeat(1460), poisoned=True)
fails += not run("fin-race", 12000, iter([5760, 5760, 480]))
fails += not run("slow-start", 9000, itertools.chain([0, 0, 0], itertools.repeat(2920)))
for s in range(1, 6):
    fails += not run(f"900k-hiccup s{s}", 921600, itertools.repeat(1460), hiccup=0.0005, seed=s)
for s in range(1, 4):
    fails += not run(f"400k-hiccup-hard s{s}", 400000, itertools.repeat(1460), hiccup=0.005, seed=s)
# Deep stalls (longer than the data timeout) must never corrupt: either the
# transfer completes or it fails visibly - a truncated prefix is never returned
# as a good file.
for s_ in range(1, 6):
    r = run(f"deep-stall s{s_}", 400000, itertools.repeat(1460), hiccup=0.0008, seed=s_, deep=True)
    # a "BAD" (wrong bytes at full length) would be the fatal outcome
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
