"""Use built DLL through Dart bridge, then actual generated-config Rule/Global/Direct requests.
All endpoints synthetic loopback, no proxy registration, no TUN or external nodes.
"""
import http.client,http.server,json,os,pathlib,socket,struct,subprocess,threading,time,urllib.request
out=pathlib.Path(os.environ['T069_OUT']);out.mkdir(parents=True,exist_ok=True)
listeners=[]
def bind():
 s=socket.socket();s.bind(('127.0.0.1',0));s.listen();listeners.append(s);return s
def read(c,n):
 b=b''
 while len(b)<n:
  q=c.recv(n-len(b))
  if not q:raise EOFError()
  b+=q
 return b
def handle(c,marker):
 try:
  c.settimeout(8);head=read(c,2);read(c,head[1]);c.sendall(b'\x05\x00');head=read(c,4)
  if head[3]==1:read(c,4)
  elif head[3]==3:read(c,read(c,1)[0])
  elif head[3]==4:read(c,16)
  read(c,2);c.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x01')
  request=b''
  while b'\r\n\r\n' not in request:request+=read(c,1)
  body=marker.encode();c.sendall(b'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body)
 except (OSError,EOFError):pass
 finally:c.close()
def serve(s,marker):
 while True:
  try:c,_=s.accept()
  except OSError:return
  threading.Thread(target=handle,args=(c,marker),daemon=True).start()
a,b=bind(),bind()
for s,m in [(a,'NODE_A'),(b,'NODE_B')]:threading.Thread(target=serve,args=(s,m),daemon=True).start()
def port():
 s=socket.socket();s.bind(('127.0.0.1',0));p=s.getsockname()[1];s.close();return p
mixed,api=port(),port()
env=dict(os.environ,T069_NODE_A=str(a.getsockname()[1]),T069_NODE_B=str(b.getsockname()[1]),T069_MIXED=str(mixed),T069_API=str(api))
class Origin(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200);self.send_header('Content-Length','13');self.send_header('Connection','close');self.end_headers();self.wfile.write(b'DIRECT_ORIGIN')
 def log_message(self,*args):pass
origin=http.server.ThreadingHTTPServer(('127.0.0.1',0),Origin);threading.Thread(target=origin.serve_forever,daemon=True).start()
core=None;result={}
try:
 p=subprocess.run([env['DART_BIN'],'run','tool/t069_codegen/bridge_probe.dart'],env=env,capture_output=True,text=True,encoding='utf-8',timeout=120)
 result['bridgeProcess']={'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
 if p.returncode:raise RuntimeError('Dart bridge probe failed')
 (out/'ui').mkdir(exist_ok=True);(out/'ui/index.html').write_text('isolated probe',encoding='utf-8')
 log=open(out/'runtime-core.log','w',encoding='utf-8')
 core=subprocess.Popen([env['SING_BOX'],'run','-c',str(out/'bridge-runtime.json')],stdout=log,stderr=log)
 client=urllib.request.build_opener(urllib.request.ProxyHandler({}))
 for _ in range(120):
  try:client.open(f'http://127.0.0.1:{api}/version',timeout=.2);break
  except Exception:
   if core.poll() is not None:raise RuntimeError('core exited before API ready')
   time.sleep(.1)
 else:raise RuntimeError('API timeout')
 responses={};result['modeResponses']=responses
 for mode,expect in [('rule','NODE_B'),('global','NODE_A'),('direct','DIRECT_ORIGIN')]:
  req=urllib.request.Request(f'http://127.0.0.1:{api}/configs',data=json.dumps({'mode':mode}).encode(),method='PATCH',headers={'Content-Type':'application/json'})
  client.open(req,timeout=3).read()
  conn=http.client.HTTPConnection('127.0.0.1',mixed,timeout=15)
  conn.request('GET',f'http://localhost:{origin.server_address[1]}/fixture',headers={'Connection':'close'})
  response=conn.getresponse();body=response.read().decode();conn.close()
  responses[mode]={'status':response.status,'body':body,'expected':expect,'passed':body==expect}
 result['modeResponses']=responses
 # A reject match must never reach either marker endpoint.
 req=urllib.request.Request(f'http://127.0.0.1:{api}/configs',data=b'{"mode":"rule"}',method='PATCH',headers={'Content-Type':'application/json'});client.open(req,timeout=3).read()
 conn=http.client.HTTPConnection('127.0.0.1',mixed,timeout=5)
 try:
  conn.request('GET','http://blocked.example/fixture');r=conn.getresponse();body=r.read().decode();result['reject']={'blocked':r.status>=400,'status':r.status,'body':body}
 except (OSError,http.client.HTTPException) as e:result['reject']={'blocked':True,'errorType':type(e).__name__}
 finally:conn.close()
 result['passed']=all(v['passed'] for v in responses.values()) and result['reject']['blocked']
 if not result['passed']:raise RuntimeError('mode routing semantic mismatch')
finally:
 if core:
  core.terminate()
  try:core.wait(timeout=5)
  except subprocess.TimeoutExpired:core.kill();core.wait()
 for s in listeners:s.close()
 origin.shutdown()
 (out/'runtime-results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
 print(json.dumps(result,ensure_ascii=False,indent=2))
