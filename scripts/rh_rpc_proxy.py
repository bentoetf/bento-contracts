#!/usr/bin/env python3
import http.server, urllib.request, sys, time
UPSTREAM = 'https://rpc.mainnet.chain.robinhood.com'
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length=int(self.headers.get('content-length','0'))
        body=self.rfile.read(length)
        last_error = None
        for attempt in range(6):
            req=urllib.request.Request(UPSTREAM, data=body, headers={
                'content-type':'application/json',
                'user-agent':'Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 Chrome/126 Safari/537.36',
                'accept':'application/json,*/*',
            })
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    data=r.read(); self.send_response(200)
                    self.send_header('content-type','application/json')
                    self.send_header('content-length', str(len(data)))
                    self.end_headers(); self.wfile.write(data)
                    return
            except Exception as e:
                last_error = e
                time.sleep(min(10, 1 + attempt * 2))
        msg=(str(last_error)).encode()
        self.send_response(502); self.send_header('content-type','text/plain'); self.end_headers(); self.wfile.write(msg)
    def log_message(self, format, *args):
        sys.stderr.write((format % args)+'\n')
if __name__ == '__main__':
    http.server.ThreadingHTTPServer(('127.0.0.1', 8547), Handler).serve_forever()
