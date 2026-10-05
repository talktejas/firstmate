#!/usr/bin/env python3
"""Local stand-in for POST /v1/systemone. Answers from a mode file; logs every request."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
D = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        key = list(body['questions'])[0]
        with open(D + '/requests.jsonl', 'a') as f:
            f.write(json.dumps({'path': self.path, 'auth': self.headers.get('Authorization'), 'question': key, 'body': body}) + '\n')
        mode = json.load(open(D + '/mode.json'))
        m = mode.get(key, mode.get('default', ['no', 0.95]))
        if m == 'hang': time.sleep(8); return
        if m == 'http500': self.send_response(500); self.end_headers(); self.wfile.write(b'boom'); return
        if m == 'garbage': out = b'<html>not json'
        else:
            choice, conf = m
            other = 'no' if choice == 'yes' else 'yes'
            probs = {choice: conf, other: round(1 - conf, 4)} if choice in ('yes', 'no') else {choice: conf, 'yes': round(1 - conf, 4)}
            out = json.dumps({'model': 'jev-standin', 'answers': {key: {'choice': choice, 'confidence': conf, 'probabilities': probs}}}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(out)
s = HTTPServer(('127.0.0.1', 0), H)
open(D + '/port', 'w').write(str(s.server_port))
s.serve_forever()
