import sys, json, time

def send(obj):
    print(json.dumps(dict(jsonrpc='2.0', **obj), ensure_ascii=False), flush=True)

def update(u):
    send(dict(method='session/update', params=dict(sessionId='mock-session', update=u)))

pending = None
for line in sys.stdin:
    m = json.loads(line)
    method = m.get('method')
    if method == 'initialize':
        send(dict(id=m['id'], result=dict(protocolVersion=1, agentCapabilities=dict(promptCapabilities=dict(audio=False)))))
    elif method == 'session/new':
        send(dict(id=m['id'], result=dict(sessionId='mock-session', modes=dict(currentModeId='approve'))))
    elif method == 'session/set_mode':
        assert m['params']['modeId'] == 'approve'
        send(dict(id=m['id'], result={}))
    elif method == 'session/prompt':
        text = m['params']['prompt'][0]['text'].split('\n\n')[-1]
        if text == 'bad-json':
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
    elif m.get('id') == 'permission-1':
        assert m['result']['outcome'] == dict(outcome='selected', optionId='no')
        update(dict(sessionUpdate='agent_message_chunk', content=dict(type='text', text='rejected')))
        send(dict(id=pending, result=dict(stopReason='end_turn')))
    elif 'id' in m:
        send(dict(id=m['id'], error=dict(code=-32601, message='Unsupported')))
