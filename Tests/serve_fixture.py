from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from functools import partial
class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
server = ThreadingHTTPServer(('127.0.0.1', 8042), partial(QuietHandler, directory=str(Path(__file__).parent / 'Fixtures')))
print('http://127.0.0.1:8042/a.html', flush=True)
server.serve_forever()
