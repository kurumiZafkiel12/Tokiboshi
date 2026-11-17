"""Loopback-only test SOCKS/HTTP/DNS servers. No real subscriptions or credentials."""
import argparse,http.server,json,pathlib,socket,socketserver,struct,threading,time
parser=argparse.ArgumentParser();parser.add_argument('--output',required=True);args=parser.parse_args()
output=pathlib.Path(args.output);output.parent.mkdir(parents=True,exist_ok=True)
lock=threading.Lock()
def event(kind,**fields):
 with lock:
  with output.open('a') as stream:stream.write(json.dumps({'kind':kind,**fields})+'\n')
def read(sock,n):
 data=b''
 while len(data)<n:
  chunk=sock.recv(n-len(data))
  if not chunk:raise EOFError()
  data+=chunk
 return data
class Socks(socketserver.BaseRequestHandler):
 def handle(self):
  sock=self.request;sock.settimeout(10)
  try:
   header=read(sock,2);assert header[0]==5;read(sock,header[1]);sock.sendall(b'\x05\x00');header=read(sock,4)
   if header[3]==1:target=socket.inet_ntop(socket.AF_INET,read(sock,4))
   elif header[3]==4:target=socket.inet_ntop(socket.AF_INET6,read(sock,16))
   elif header[3]==3:target=read(sock,read(sock,1)[0]).decode()
   else:return
   port=int.from_bytes(read(sock,2),'big');sock.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
   head=b''
   while b'\r\n\r\n' not in head and len(head)<16384:head+=read(sock,1)
   marker=b'TOKIBOSHI_PROXY_A' if self.server.server_address[1]==18080 else b'TOKIBOSHI_PROXY_B'
   event('socks',proxy=marker.decode(),target=target,port=port)
   sock.sendall(b'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: '+str(len(marker)).encode()+b'\r\n\r\n'+marker)
  except (OSError,EOFError,AssertionError):pass
class Origin(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  body=b'TOKIBOSHI_DIRECT';self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);event('direct')
 def log_message(self,*args):pass
class Dns(socketserver.BaseRequestHandler):
 def handle(self):
  query,sock=self.request
  if len(query)<12:return
  i=12
  while i<len(query) and query[i]:i+=query[i]+1
  end=i+5
  if end>len(query):return
  response=query[:2]+b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00'+query[12:end]+b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x1e\x00\x04\xcb\x00\x71\x0a'
  sock.sendto(response,self.client_address);event('dns')
class Tcp(socketserver.ThreadingTCPServer):allow_reuse_address=True;daemon_threads=True
class Udp(socketserver.ThreadingUDPServer):allow_reuse_address=True;daemon_threads=True
servers=[Tcp(('127.0.0.1',18080),Socks),Tcp(('127.0.0.1',18082),Socks),http.server.ThreadingHTTPServer(('127.0.0.1',18081),Origin),Udp(('127.0.0.1',15353),Dns)]
for server in servers:threading.Thread(target=server.serve_forever,daemon=True).start()
event('ready')
try:
 while True:time.sleep(1)
finally:
 for server in servers:server.shutdown();server.server_close()
