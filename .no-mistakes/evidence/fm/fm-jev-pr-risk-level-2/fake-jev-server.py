#!/usr/bin/env python3
"""Local stand-in for https://api.typesafe.ai used only to drive bin/fm-pr-check.sh.
Replies per question key from a mode file; logs every request it receives."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
MODE, LOG = sys.argv[2], sys.argv[3]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        key = next(iter(body['questions']))
        mode = json.load(open(MODE))
        how = mode.get(key, mode.get('*', 'no:0.95'))
        ch = body['state']['change']
        with open(LOG, 'a') as f:
            f.write(json.dumps({'path': self.path, 'question': key, 'reply': how,
                'auth_header': self.headers.get('Authorization'),
                'options': sorted(body['questions'][key]['criteria']),
                'title': ch['title'], 'files': [x['path'] for x in ch['files']],
                'facts': ch['facts'], 'diff_bytes': len(ch['diff_start'])}) + '\n')
        if how == 'sleep': time.sleep(8)
        if how == '500':
            self.send_response(500); self.end_headers(); self.wfile.write(b'boom'); return
        if how == 'garbage': out = b'<html>not json</html>'
        elif how == 'maybe':
            out = json.dumps({'model': 'fake', 'answers': {key: {'choice': 'maybe', 'confidence': 0.99,
                'probabilities': {'maybe': 0.99, 'no': 0.01}}}}).encode()
        else:
            c, conf = how.split(':'); conf = float(conf); o = 'no' if c == 'yes' else 'yes'
            out = json.dumps({'model': 'fake', 'answers': {key: {'choice': c, 'confidence': conf,
                'probabilities': {c: conf, o: round(1 - conf, 4)}}}}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out))); self.end_headers()
        try: self.wfile.write(out)
        except BrokenPipeError: pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
