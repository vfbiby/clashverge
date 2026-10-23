import http.server, socketserver, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type','application/octet-stream')
        self.send_header('Content-Length','36000000')
        self.end_headers()
        chunk=b'\x00'*24000
        for i in range(2400):
            try:
                self.wfile.write(chunk); self.wfile.flush()
            except Exception: return
            if i%40==0: time.sleep(0.02)
    def log_message(self,*a,**k): pass
class S(socketserver.ThreadingTCPServer): allow_reuse_address=True
S(('104.20.26.136',80),H).serve_forever()
