#!/usr/bin/env python3
# 长连接探针: TLS 建连后每 interval 秒一个 keep-alive GET
# 输出行: CONNECTED / ALIVE / HANG(读超时, 连接未死) / ERROR(RST 或 EOF)
import socket, ssl, sys, time
ip, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
interval = float(sys.argv[4]) if len(sys.argv) > 4 else 0.2
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = socket.create_connection((ip, port), timeout=8)
s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
ss = ctx.wrap_socket(s, server_hostname="example.org")
f = open(out, "w", buffering=1)
f.write("CONNECTED %.3f %s\n" % (time.time(), ss.version()))
REQ = b"GET / HTTP/1.1\r\nHost: example.org\r\nConnection: keep-alive\r\n\r\n"
i = 0
while True:
    i += 1
    try:
        ss.sendall(REQ)
        ts = time.time()
        ss.settimeout(max(1.0, interval * 2))
        d = ss.recv(65536)
        if d == b"":
            f.write("ERROR %.3f req=%d EOF(peer closed)\n" % (time.time(), i)); break
        f.write("ALIVE %.3f req=%d resp=%dB\n" % (time.time(), i, len(d)))
        time.sleep(interval)
    except socket.timeout:
        f.write("HANG %.3f req=%d read-timeout(连接未死, 无 RST)\n" % (time.time(), i))
        time.sleep(interval)
    except Exception as e:
        f.write("ERROR %.3f req=%d %s: %s\n" % (time.time(), i, type(e).__name__, e))
        break
