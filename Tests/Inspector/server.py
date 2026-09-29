from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import base64
import hashlib


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/socket":
            accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            # Local fixture accepts one short, masked text frame and echoes it.
            header = self.rfile.read(2)
            mask = self.rfile.read(4)
            payload = self.rfile.read(header[1] & 127)
            assert header[0] == 0x81 and header[1] & 128 and len(payload) < 126
            body = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
            self.wfile.write(bytes([0x81, len(body)]) + body + b"\x88\x00")
            self.wfile.flush()
            self.close_connection = True
            return
        routes = {
            "/": ("text/html", '<script>window.probeValue=42</script><script src="/debug.js"></script><iframe src="http://localhost:18765/frame"></iframe>'),
            "/debug.js": ("text/javascript", "function inspectorInner(value) {\n  let local = value + 1;\n  window.debugResult = local * 2;\n  return window.debugResult;\n}\nfunction inspectorOuter() { return inspectorInner(20); }"),
            "/frame": ("text/html", "<h1>cross origin frame</h1>"),
            "/second": ("text/html", "<h1>navigated</h1>"),
            "/body": ("text/plain", "inspector-response-body"),
            "/worker.js": ("text/javascript", "self.workerValue=73;setInterval(()=>{},1000)"),
        }
        content_type, body = routes.get(self.path, ("text/plain", "missing"))
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *_):
        pass


Thread(target=ThreadingHTTPServer(("127.0.0.1", 18765), Handler).serve_forever, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", 18764), Handler).serve_forever()
