"""Loopback-only SSE fixture. No request bodies, headers, or keys are logged."""
import http.server, json, sys, pathlib

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        data = json.dumps(dict(object='list', data=[dict(id='gpt-4o-mini', object='model', owned_by='mock', created=1)])).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        if length > 1_048_576:
            self.send_error(413); return
        body = json.loads(self.rfile.read(length))
        tools = [t.get('function', {}).get('name') for t in body.get('tools', [])]
        has_result = any(m.get('role') == 'tool' for m in body.get('messages', []))
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        def send(delta, finish=None):
            self.wfile.write(('data: ' + json.dumps(dict(id='mock', object='chat.completion.chunk', created=1, model='gpt-4o-mini', choices=[dict(index=0, delta=delta, finish_reason=finish)])) + '\n\n').encode())
            self.wfile.flush()
        name = next((t for t in tools if t == 'jarvis__propose_action'), None)
        if name and not has_result:
            send(dict(role='assistant', content=None, tool_calls=[dict(index=0, id='call_plan', type='function', function=dict(name=name, arguments=json.dumps(dict(kind='openApp', target='terminal'))))]))
            send({}, 'tool_calls')
        else:
            send(dict(role='assistant', content='План готовий.' if has_result else 'MCP tool missing.'))
            send({}, 'stop')
        self.wfile.write(('data: ' + json.dumps(dict(id='mock', object='chat.completion.chunk', created=1, model='gpt-4o-mini', choices=[], usage=dict(prompt_tokens=1000, completion_tokens=20, total_tokens=1020))) + '\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_address[1]))
server.serve_forever()
