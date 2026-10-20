#!/usr/bin/env python3
"""Local stand-in for an OpenAI Responses endpoint. Appends request metadata (no note text) to a log file."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log_path = sys.argv[1]
REPLY = json.dumps({'reply': 'Here is a clearer version.', 'operations': [
    {'action': 'replace', 'block': 1, 'text': 'Improved', 'kind': 'body'}]})


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('content-length', 0))) or b'{}')
        text = json.dumps((body.get('input') or [{}])[-1].get('content'))
        with open(log_path, 'a') as log:
            log.write(json.dumps({
                'path': self.path,
                'authorization': self.headers.get('authorization'),
                'session': self.headers.get('x-opencode-session'),
                'model': body.get('model'),
                'effort': (body.get('reasoning') or {}).get('effort'),
                'strict': ((body.get('text') or {}).get('format') or {}).get('strict'),
                'turns': len(body.get('input') or []),
            }) + '\n')
        if 'FAIL401' in text:
            self.send_response(401)
            self.send_header('content-type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"bad key"}}')
            return
        if 'SLOW' in text:
            time.sleep(8)
        payload = {'id': 'resp_1', 'status': 'completed', 'output': [
            {'type': 'reasoning', 'id': 'rs_1'},
            {'type': 'message', 'role': 'assistant', 'id': 'msg_1',
             'content': [{'type': 'output_text', 'text': REPLY}]}]}
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
