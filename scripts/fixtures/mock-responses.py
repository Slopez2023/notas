#!/usr/bin/env python3
"""Local Responses and Chat Completions stand-in. Logs request metadata without note text."""
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
        chat = self.path.endswith('/chat/completions')
        turns = body.get('messages' if chat else 'input') or [{}]
        text = json.dumps(turns[-1].get('content'))
        with open(log_path, 'a') as log:
            log.write(json.dumps({
                'path': self.path,
                'authorization': self.headers.get('authorization'),
                'session': self.headers.get('x-opencode-session'),
                'model': body.get('model'),
                'effort': body.get('reasoning_effort') if chat else (body.get('reasoning') or {}).get('effort'),
                'strict': ((body.get('text') or {}).get('format') or {}).get('strict'),
                'format': (body.get('response_format') or {}).get('type'),
                'system_schema': chat and turns[0].get('role') == 'system' and '"operations"' in turns[0].get('content', ''),
                'turns': len(turns),
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
        if 'NOCHANGE' in text:
            payload['output'][1]['content'][0]['text'] = json.dumps({'reply': 'No correction needed.', 'operations': [
                {'action': 'replace', 'block': 1, 'text': 'Original', 'kind': 'body'}]})
        if chat:
            payload = {'choices': [{'finish_reason': 'stop', 'message': {
                'role': 'assistant', 'content': REPLY, 'reasoning_content': 'Private reasoning, not the reply.'}}]}
            choice = payload['choices'][0]
            if 'TRUNCATED' in text:
                choice['finish_reason'] = 'length'
            if 'REFUSAL' in text:
                choice['message']['refusal'] = 'Declined'
            if 'EMPTY' in text:
                choice['message']['content'] = None
        expected_chat = body.get('model') == 'deepseek-v4.1-flash'
        valid = chat == expected_chat
        if chat:
            valid = valid and body.get('reasoning_effort') == 'high' and body.get('response_format') == {'type': 'json_object'}
        if not valid:
            self.send_response(400)
            self.send_header('content-type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"Wrong model protocol or parameters"}}')
            return
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
