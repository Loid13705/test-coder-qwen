"""Servidor HTTP local REAL para verificação de streaming SSE do provider.

Não é mock da aplicação: é um servidor real que fala o protocolo
OpenAI-compatible (text/event-stream) sobre TCP, exatamente como o upstream.
Usado apenas por tool/stream_smoke.dart para verificar parser/cancelamento.
"""
import http.server, json, socketserver, threading, time, sys

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send_sse(self, events, delay=0.12):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        try:
            for ev in events:
                self.wfile.write(b'data: ' + json.dumps(ev).encode() + b'\n\n')
                self.wfile.flush()
                time.sleep(delay)
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # cliente cancelou de verdade — registra no sidecar log
            with open(sys.argv[2], 'a') as f:
                f.write('client_cancelled\n')

    def do_GET(self):
        if self.path == '/v1/models':
            body = json.dumps({'object': 'list', 'data': [
                {'id': 'gpt-4o-mini'}, {'id': 'smoke-local-model'}]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        req = json.loads(self.rfile.read(n) or b'{}')
        auth = self.headers.get('Authorization', '')
        if req.get('model') == 'reject-auth' or auth == 'Bearer BAD':
            body = json.dumps({'error': {'message': 'Invalid API key provided.'}}).encode()
            self.send_response(401)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        words = ['Olá!', ' Este', ' é', ' um', ' stream', ' SSE', ' real.']
        events = []
        for w in words:
            events.append({'choices': [{'delta': {'content': w}, 'index': 0}], 'object': 'chat.completion.chunk'})
        events.append({'choices': [{'delta': {}, 'finish_reason': 'stop', 'index': 0}], 'object': 'chat.completion.chunk'})
        events.append({'choices': [], 'usage': {'prompt_tokens': 11, 'completion_tokens': 7, 'total_tokens': 18}})
        self._send_sse(events, delay=float(req.get('_smoke_delay', 0.08)))

if __name__ == '__main__':
    port_file, cancel_log = sys.argv[1], sys.argv[2]
    server = socketserver.ThreadingTCPServer(('127.0.0.1', int(port_file)), H)
    server.allow_reuse_address = True
    with open(port_file, 'w') as f:
        f.write('ready\n')
    server.serve_forever()
