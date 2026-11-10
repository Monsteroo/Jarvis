import sys, json, time, os, subprocess

def send(obj):
    print(json.dumps(dict(jsonrpc='2.0', **obj), ensure_ascii=False), flush=True)

def update(u):
    send(dict(method='session/update', params=dict(sessionId='mock-session', update=u)))

pending = None
mcp_server = None
pending_tool = None
for line in sys.stdin:
    m = json.loads(line)
    method = m.get('method')
    if method == 'initialize':
        send(dict(id=m['id'], result=dict(protocolVersion=1, agentCapabilities=dict(promptCapabilities=dict(audio=False)))))
    elif method == 'session/new':
        servers = m['params'].get('mcpServers', [])
        mcp_server = servers[0] if servers else None
        send(dict(id=m['id'], result=dict(sessionId='mock-session', modes=dict(currentModeId='approve'))))
    elif method == 'session/set_mode':
        assert m['params']['modeId'] == 'approve'
        send(dict(id=m['id'], result={}))
    elif method == 'session/prompt':
        text = m['params']['prompt'][0]['text'].split('\n\n')[-1]
        if text in ['proposal', 'unsafe-proposal', 'proposal-mutated']:
            pending = m['id']
            pending_tool = text
            args = dict(kind='openApp', target='terminal')
            tool_name = 'jarvis__propose_action' if text != 'unsafe-proposal' else 'developer__shell'
            update(dict(sessionUpdate='tool_call', toolCallId='plan-1', rawInput=args, _meta=dict(goose=dict(toolCall=dict(toolName=tool_name, extensionName='jarvis' if text != 'unsafe-proposal' else 'developer')))))
            send(dict(id='plan-permission', method='session/request_permission', params=dict(sessionId='mock-session', toolCall=dict(toolCallId='plan-1', rawInput=(dict(kind='openApp', target='mail') if text == 'proposal-mutated' else args)), options=[dict(optionId='always', kind='allow_always'), dict(optionId='once', kind='allow_once'), dict(optionId='no', kind='reject_once')])))
        elif text == 'bad-json':
            print('not-json', flush=True)
        elif text == 'exit':
            sys.exit(0)
        elif text == 'slow':
            pending = m['id']
        elif text == 'error':
            update(dict(sessionUpdate='agent_message_chunk', content=dict(type='text', text='provisional')))
            send(dict(id=m['id'], error=dict(code=-32000, message='provider error')))
        elif text == 'invalid-then-over':
            update(dict(sessionUpdate='usage_update', cost=dict(amount=0.01, currency='EUR')))
            update(dict(sessionUpdate='usage_update', cost=dict(amount=0.50, currency='USD')))
            send(dict(id=m['id'], result=dict(stopReason='end_turn')))
        elif text == 'invalid-cost':
            update(dict(sessionUpdate='usage_update', cost=dict(amount=0.01, currency='EUR')))
            send(dict(id=m['id'], result=dict(stopReason='end_turn')))
        elif text == 'foreign':
            send(dict(method='session/update', params=dict(sessionId='wrong', update=dict(sessionUpdate='agent_message_chunk', content=dict(type='text', text='WRONG')))))
            update(dict(sessionUpdate='agent_message_chunk', content=dict(type='text', text='correct')))
            send(dict(id=m['id'], result=dict(stopReason='end_turn')))
        elif text == 'permission':
            pending = m['id']
            send(dict(id='permission-1', method='session/request_permission', params=dict(sessionId='mock-session', toolCall=dict(toolCallId='tool-1', title='test'), options=[dict(optionId='always', kind='allow_always'), dict(optionId='once', kind='allow_once'), dict(optionId='no', kind='reject_once')])))
        else:
            update(dict(sessionUpdate='agent_message_chunk', content=dict(type='text', text='Вітаю!')))
            for _ in range(2):
                update(dict(sessionUpdate='usage_update', cost=dict(amount=0.000162, currency='USD')))
            send(dict(id=m['id'], result=dict(stopReason='end_turn')))
    elif m.get('id') == 'plan-permission':
        if pending_tool == 'proposal':
            assert m['result']['outcome'] == dict(outcome='selected', optionId='once')
            assert mcp_server and mcp_server['name'] == 'jarvis'
            env = dict(os.environ, **{v['name']: v['value'] for v in mcp_server['env']})
            helper = subprocess.Popen([mcp_server['command']] + mcp_server['args'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)
            def mcp(method, params, id):
                helper.stdin.write(json.dumps(dict(jsonrpc='2.0', id=id, method=method, params=params)) + '\n'); helper.stdin.flush()
                reply = json.loads(helper.stdout.readline())
                assert reply['id'] == id
                return reply
            assert mcp('server/discover', {}, 0)['error']['code'] == -32601
            assert mcp('initialize', dict(protocolVersion='2025-11-25'), 1)['result']['protocolVersion'] == '2025-11-25'
            assert mcp('tools/list', {}, 2)['result']['tools'][0]['name'] == 'propose_action'
            result = mcp('tools/call', dict(name='propose_action', arguments=dict(kind='openApp', target='terminal')), 3)
            assert not result['result']['isError']
            helper.stdin.close(); helper.wait(timeout=5)
            reply_text = 'plan proposed'
        else:
            assert m['result']['outcome'] == dict(outcome='selected', optionId='no')
            reply_text = 'rejected'
        update(dict(sessionUpdate='agent_message_chunk', content=dict(type='text', text=reply_text)))
        send(dict(id=pending, result=dict(stopReason='end_turn')))
    elif m.get('id') == 'permission-1':
        assert m['result']['outcome'] == dict(outcome='selected', optionId='no')
        update(dict(sessionUpdate='agent_message_chunk', content=dict(type='text', text='rejected')))
        send(dict(id=pending, result=dict(stopReason='end_turn')))
    elif 'id' in m:
        send(dict(id=m['id'], error=dict(code=-32601, message='Unsupported')))
