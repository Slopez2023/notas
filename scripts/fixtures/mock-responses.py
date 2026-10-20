#!/usr/bin/env python3
"""Local stand-in for an OpenAI Responses endpoint. Records request metadata (never bodies' note text) to a log file."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

log_path = sys.argv[1]
REPLY = json.dumps({'reply': 'Mock reply from the OpenCode route.', 'operations': []})


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('content-length', 0))) or b'{}')
        with open(log_path, 'a') as log:
            log.write(json.dumps({
                'path': self.path,
                'authorization': self.headers.get('authorization'),
                'session': self.headers.get('x-opencode-session'),
                'model': body.get('model'),
                'effort': (body.get('reasoning') or {}).get('effort'),
            }) + '\n')
        events = [
            ('response.created', {'type': 'response.created', 'response': {'id': 'resp_1'}}),
            ('response.output_item.done', {'type': 'response.output_item.done', 'item': {
                'type': 'message', 'role': 'assistant', 'id': 'msg_1',
                'content': [{'type': 'output_text', 'text': REPLY}]}}),
            ('response.completed', {'type': 'response.completed', 'response': {'id': 'resp_1', 'usage': {
                'input_tokens': 1, 'input_tokens_details': None, 'output_tokens': 1,
                'output_tokens_details': None, 'total_tokens': 2}}}),
        ]
        self.send_response(200)
        self.send_header('content-type', 'text/event-stream')
        self.end_headers()
        for name, data in events:
            self.wfile.write(f'event: {name}\ndata: {json.dumps(data)}\n\n'.encode())
            self.wfile.flush()


server = HTTPServer(('127.0.0.1', 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
