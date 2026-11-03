#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Installed Yarn Berry integration, source pins, offline use and pure composition."""
import base64
import io
import tarfile
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from urllib.parse import unquote, urlsplit
import os
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
system = subprocess.check_output(['nix','eval','--impure','--raw','--expr','builtins.currentSystem'], text=True).strip()
snapshot = json.loads(subprocess.check_output(['nix','flake','archive','--json','--no-write-lock-file',str(root)], text=True))['path']
with tempfile.TemporaryDirectory(prefix='yarn-berry-native-composition-') as temporary:
    temporary = Path(temporary)
    subprocess.run(['nix-store','--add-root',str(temporary/'source'),'--realise',snapshot],check=True)
    cli = Path(subprocess.check_output(['nix','build','path:'+snapshot+'#toolchain','--out-link',str(temporary/'cli'),'--print-out-paths'],text=True).strip())/'bin/yarn-berry-purifier'
    env = dict(os.environ, BERRY_COMPOSITION_FLAKE=snapshot)
    home = temporary/'home'
    home.mkdir()
    env.update(NO_COLOR='1', HOME=str(home))
    env.pop('FORCE_COLOR',None)
    sdk = Path(subprocess.check_output(['nix','build','--impure','--expr',
        'let f=builtins.getFlake ("path:"+builtins.getEnv "BERRY_COMPOSITION_FLAKE"); in f.inputs.nixpkgs.legacyPackages.'+system+'.nodejs',
        '--out-link',str(temporary/'sdk'),'--print-out-paths'],env=env,text=True).strip())
    env['PATH'] = str(sdk/'bin')+':'+env['PATH']
    project = temporary/'project'
    project.mkdir()
    manifest = {'name':'yarn-berry-composed','version':'1.0.0','license':'MIT','main':'index.js','bin':'index.js','packageManager':'yarn@4.18.1','dependencies':{'hello-berry':'>=99'},
                'scripts':{'test':'hello-berry'}}
    original = (json.dumps(manifest,indent=2)+'\n').encode()
    (project/'package.json').write_bytes(original)
    (project/'index.js').write_text('#!/usr/bin/env node\nrequire("hello-berry/bin/hello.js");\n')
    (project/'.yarnrc.yml').write_text('enableTelemetry: false\n')
    def run(*args,**kwargs):
        return subprocess.run([str(arg) for arg in args],cwd=project,env=env,check=True,**kwargs)
    reference = 'path:'+snapshot+'#checks.'+system+'.composition-producer'
    run(cli,'lock','--system',system,'--input',reference)
    lockfile = project/'yarn-berry-purifier.lock.json'
    data = json.loads(lockfile.read_text())
    assert len(data['projectInputs']) == 1
    assert not data['downloads']
    before = lockfile.read_bytes(), (project/'yarn.lock').read_bytes()
    run(cli,'lock','--system',system)
    assert before == (lockfile.read_bytes(), (project/'yarn.lock').read_bytes())
    run(cli,'prefetch')
    run(cli.parent/'yarn','install','--immutable')
    run(cli.parent/'yarn','run','test')
    output = run(cli.parent/'yarn','exec','hello-berry',capture_output=True,text=True)
    assert output.stdout == 'hello-berry: built by the build script (3 is odd: true)\n'
    assert (project/'package.json').read_bytes() == original
    assert before == (lockfile.read_bytes(), (project/'yarn.lock').read_bytes())
    expression = temporary/'consumer.nix'
    expression.write_text('''{ source, project }:
      let f=builtins.getFlake ("path:"+source);
          pkgs=import f.inputs.nixpkgs {system=builtins.currentSystem;overlays=[f.overlays.default];};
          metadata=builtins.fromJSON(builtins.readFile (/. + project + "/yarn-berry-purifier.lock.json"));
          result=pkgs.yarn-berry-purifier.buildYarnBerryProject {src = /. + project;};
      in assert pkgs.yarn-berry-purifier.yarn.drvPath != "";
         assert pkgs.yarn-berry-purifier.yarn-berry-purifier.drvPath != "";
         assert builtins.all (entry: (entry.url or "") == metadata.yarn.url) result.fetches; result.tests
    ''')
    run('nix','build','--impure','--file',expression,'--argstr','source',snapshot,
        '--argstr','project',project,'--out-link',temporary/'pure')
    assert (project/'package.json').read_bytes() == original
    assert before == (lockfile.read_bytes(), (project/'yarn.lock').read_bytes())
    publication = temporary/'publication.nix'
    publication.write_text(expression.read_text().replace('result.tests',
        'result.packages."yarn-berry-composed".projections.npm'))
    repository = Path(subprocess.check_output(['nix','build','--impure','--file',str(publication),
        '--argstr','source',snapshot,'--argstr','project',str(project),
        '--out-link',str(temporary/'publication'),'--print-out-paths'],text=True).strip())
    catalog = Path(subprocess.check_output(['nix','eval','--impure','--raw','--file',str(publication),
        '--argstr','source',snapshot,'--argstr','project',str(project),'catalog'],text=True).strip())
    modules = json.loads(catalog.read_text())['modules']
    provided = next(item for item in modules if item['name'] == 'hello-berry')
    uploads = {provided['name']:(repository/provided['archive']).read_bytes()}
    put_names = []
    class Registry(BaseHTTPRequestHandler):
        def do_GET(self):
            route = unquote(urlsplit(self.path).path).lstrip('/')
            if route.startswith('tarballs/'):
                body = (repository/route).read_bytes()
            else:
                available = [item for item in modules if item['name'] == route and item['name'] in uploads]
                if not available:
                    self.send_error(404)
                    return
                versions = {item['version']:{**item['package'],'dist':{
                    'integrity':item['integrity'],'tarball':'http://'+self.headers['Host']+'/'+item['archive']}} for item in available}
                body = json.dumps({'name':route,'versions':versions,
                    'dist-tags':{'latest':available[0]['version']}}).encode()
            self.send_response(200)
            self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_PUT(self):
            document = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            put_names.append(document['name'])
            uploads[document['name']] = base64.b64decode(next(iter(document['_attachments'].values()))['data'])
            self.send_response(201)
            self.end_headers()
            self.wfile.write(b'{}')
        def log_message(self,*args): pass
    server = ThreadingHTTPServer(('127.0.0.1',0),Registry)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    url = 'http://127.0.0.1:'+str(server.server_port)+'/'
    (Path(env['HOME'])/'.yarnrc.yml').write_text('npmRegistryServer: '+url+'\nnpmPublishRegistry: '+url+'\nnpmAuthToken: local-fixture\nnpmAlwaysAuth: true\nunsafeHttpWhitelist:\n  - 127.0.0.1\n')
    try:
        run(cli,'publish','--access','public')
        assert provided['name'] not in put_names
        for item in modules:
            assert uploads[item['name']] == (repository/item['archive']).read_bytes(), (
                item['name'], item['version'], json.load(tarfile.open(fileobj=io.BytesIO(uploads[item['name']])).extractfile('package/package.json'))['version'])
        downstream = temporary/'ordinary'
        downstream.mkdir()
        (downstream/'package.json').write_text('{"name":"ordinary-npm-consumer","private":true}')
        version = next(item['version'] for item in modules if item['name'] == 'yarn-berry-composed')
        subprocess.run([str(sdk/'bin/npm'),'install','--no-audit','--no-fund','--registry',url,'--cache',str(temporary/'ordinary-cache'),
            'yarn-berry-composed@'+version],cwd=downstream,env=env,check=True)
        output = subprocess.check_output([str(sdk/'bin/node'),str(downstream/'node_modules/.bin/yarn-berry-composed')],cwd=downstream,env=env,text=True)
        assert 'hello-berry: built by the build script' in output
    finally:
        server.shutdown()
        server.server_close()
    assert before == (lockfile.read_bytes(), (project/'yarn.lock').read_bytes())
    assert (project/'package.json').read_bytes() == original
    binary = temporary/'binary'
    binary.mkdir()
    (binary/'package.json').write_text(json.dumps({'name':'berry-native-binary','version':'1.0.0','private':True,
        'packageManager':'yarn@4.18.1','scripts':{'test':'greet 42'},'dependencies':{'greet-cli':'>=99'}},indent=2)+'\n')
    binary_reference = 'github:nix-purifiers/npm-purifier/aa41139#checks.'+system+'.composition-producer'
    subprocess.run([str(cli),'lock','--system',system,'--input',binary_reference],cwd=binary,env=env,check=True)
    binary_meta = json.loads((binary/'yarn-berry-purifier.lock.json').read_text())
    assert not binary_meta['downloads']
    subprocess.run([str(cli),'prefetch'],cwd=binary,env=env,check=True)
    binary_output = subprocess.check_output([str(cli.parent/'yarn'),'exec','greet','42'],cwd=binary,env=env,text=True)
    assert binary_output.startswith('hello, number 42') and 'esbuild:' in binary_output,binary_output
    run('nix','build','--impure','--file',expression,'--argstr','source',snapshot,
        '--argstr','project',binary,'--out-link',temporary/'binary-pure')
    external = temporary/'external'
    external.mkdir()
    (external/'package.json').write_bytes(original)
    native = b'''__metadata:
  version: 8
  cacheKey: 10c0

"yarn-berry-composed@workspace:.":
  version: 0.0.0-use.local
  resolution: "yarn-berry-composed@workspace:."
  dependencies:
    hello-berry: "npm:>=99"
  languageName: unknown
  linkType: soft

"hello-berry@npm:>=99":
  version: 99.0.0
  resolution: "hello-berry@https://invalid.example/old.tgz"
  languageName: node
  linkType: hard
'''
    import copy, hashlib
    external_meta = copy.deepcopy(data)
    external_meta.pop('projectInputs',None)
    external_meta['downloads'] = [{'path':'https/invalid.example/old.tgz','url':'https://invalid.example/old.tgz','hash':'sha512-AAAA','systems':[system]}]
    external_meta['inputsHash'] = 'sha256-'+base64.b64encode(hashlib.sha256(native).digest()).decode()
    external_meta.pop('contentHash',None)
    external_meta['contentHash'] = 'sha256-'+base64.b64encode(hashlib.sha256(json.dumps(external_meta,sort_keys=True,separators=(',',':')).encode()).digest()).decode()
    (external/'yarn-berry-purifier.lock.json').write_text(json.dumps(external_meta))
    (external/'yarn.lock').write_bytes(native)
    external_expression = temporary/'external.nix'
    external_expression.write_text(expression.read_text().replace('src = /. + project;',
        'src = /. + project;dependencies=[f.checks.${builtins.currentSystem}.composition-producer];'))
    run('nix','build','--impure','--file',external_expression,'--argstr','source',snapshot,
        '--argstr','project',external,'--out-link',temporary/'external-pure')
    assert (external/'package.json').read_bytes() == original
    assert (external/'yarn.lock').read_bytes() == native
    outside_project = temporary/'outside-project'
    outside_project.mkdir()
    (outside_project/'package.json').write_bytes(original)
    outside_locks = temporary/'outside-locks'
    outside_locks.mkdir()
    outside_native = outside_locks/'yarn.lock'
    outside_native.write_bytes(before[1])
    outside_purifier = outside_locks/'yarn-berry-purifier.lock.json'
    outside_purifier.write_bytes(before[0])
    flags = ['--lockfile',str(outside_purifier),'--tool-lockfile',str(outside_native)]
    for command in ('lock','prefetch'):
        subprocess.run([str(cli),command,*(['--system',system] if command=='lock' else []),*flags],cwd=outside_project,env=env,check=True)
        assert not (outside_project/'yarn.lock').exists()
        assert (outside_project/'package.json').read_bytes() == original
    outside_env = dict(env,YARN_BERRY_PURIFIER_LOCKFILE=str(outside_purifier),
        YARN_BERRY_PURIFIER_TOOL_LOCKFILE=str(outside_native))
    subprocess.run([str(cli.parent/'yarn'),'install','--immutable'],cwd=outside_project,env=outside_env,check=True)
    subprocess.run([str(cli.parent/'yarn'),'run','test'],cwd=outside_project,env=outside_env,check=True)
    assert not (outside_project/'yarn.lock').exists()
    assert (outside_project/'package.json').read_bytes() == original
    assert (outside_purifier.read_bytes(), outside_native.read_bytes()) == before
    unpurified = temporary/'unpurified'
    unpurified.mkdir()
    fallback = subprocess.run([str(cli.parent/'yarn'),'--version'],cwd=unpurified,env=env,
        text=True,capture_output=True,check=True)
    assert 'yarn-berry-purifier.lock.json' in fallback.stderr and 'impure' in fallback.stderr
    assert fallback.stdout.strip()
print('YARN BERRY NATIVE REPOSITORY COMPOSITION PASSED')
