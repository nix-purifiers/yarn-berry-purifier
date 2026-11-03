#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""A stock npm client consumes the repository exported by a Yarn Berry producer."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
repository, catalog, node = map(Path, sys.argv[1:])
modules = json.loads(catalog.read_text())['modules']
version = next(item['version'] for item in modules if item['name'] == 'hello-berry')
class Registry(BaseHTTPRequestHandler):
    def do_GET(self):
        route = unquote(urlsplit(self.path).path).lstrip('/')
        if route.startswith('tarballs/'):
            body = (repository/route).read_bytes()
        else:
            available = [item for item in modules if item['name'] == route]
            if not available:
                self.send_error(404)
                return
            versions = {}
            for item in available:
                metadata = dict(item['package'])
                metadata['dist'] = {'integrity': item['integrity'],
                    'tarball': 'http://'+self.headers['Host']+'/'+item['archive']}
                versions[item['version']] = metadata
            body = json.dumps({'name': route, 'versions': versions,
                'dist-tags': {'latest': available[0]['version']}}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Registry)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root/'package.json').write_text('{"name":"ordinary-npm-consumer","private":true}')
        env = dict(os.environ, PATH=str(node)+':'+os.environ['PATH'], npm_config_cache=str(root/'cache'))
        subprocess.run([str(node/'npm'), 'install', '--no-audit', '--no-fund', '--ignore-scripts',
                        '--registry', f'http://127.0.0.1:{server.server_port}/', 'hello-berry@'+version],
                       cwd=root, env=env, check=True)
        output = subprocess.check_output([str(node/'node'),str(root/'node_modules/.bin/hello-berry')],cwd=root,env=env,text=True)
        assert 'hello-berry: built by the build script' in output, output
        assert all(item['name'] != 'is-odd' for item in modules), 'build-only dependencies leaked into the runtime repository'
finally:
    server.shutdown()
