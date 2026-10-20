#!/usr/bin/env python3
"""Deterministic app-server fixture. Never contacts OpenAI or executes commands."""
import json
import sys
import time

threads = 0


def emit(value):
    data = json.dumps(value) + '\n'
    # Exercise partial reads without splitting JSON in the client incorrectly.
    midpoint = len(data) // 2
    sys.stdout.write(data[:midpoint])
    sys.stdout.flush()
    time.sleep(0.005)
    sys.stdout.write(data[midpoint:])
    sys.stdout.flush()


for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    params = message.get('params', {})
    result = {}
    if method == 'initialize':
        result = {'userAgent': 'fixture/0.163.0'}
    elif method == 'command/exec':
        allowed = params['command'][0] == '/bin/echo'
        result = {'exitCode': 0 if allowed else 1, 'stdout': 'notas-sandbox-ok\n' if allowed else '', 'stderr': ''}
    elif method == 'account/read':
        result = {'account': {'type': 'chatgpt', 'email': 'fixture@example.test', 'planType': 'plus'}}
    elif method == 'model/list':
        result = {'data': [{'model': 'gpt-6.1-sol', 'supportedReasoningEfforts': [{'reasoningEffort': 'medium'}]}], 'nextCursor': None}
    elif method == 'thread/start':
        assert params['permissions'] == 'notas' and 'sandbox' not in params
        threads += 1
        result = {'thread': {'id': f'thread-{threads}'}}
    elif method == 'turn/start':
        assert params['model'] == 'gpt-6.1-sol' and params['effort'] == 'medium'
        assert params['permissions'] == 'notas'
        assert params['outputSchema']['additionalProperties'] is False
        result = {'turn': {'id': 'turn-1', 'status': 'inProgress'}}
    if 'id' in message:
        emit({'id': message['id'], 'result': result})
    if method == 'turn/start':
        emit({'method': 'turn/started', 'params': {'threadId': params['threadId'], 'turn': {'id': 'turn-1'}}})
        reply = json.dumps({'reply': 'Here is a clearer version.', 'operations': [
            {'action': 'replace', 'block': 1, 'text': 'Improved', 'kind': 'body'}]})
        emit({'method': 'item/completed', 'params': {'threadId': params['threadId'], 'turnId': 'turn-1',
             'item': {'type': 'agentMessage', 'id': 'answer-1', 'text': reply}}})
        emit({'method': 'turn/completed', 'params': {'threadId': params['threadId'], 'turn': {'id': 'turn-1', 'status': 'completed', 'items': []}}})
