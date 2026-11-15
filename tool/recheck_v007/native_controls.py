"""Windows runner controls: real token/service and original socket handshake.
No GUI acceptance, real UAC click, registry/proxy changes or TUN creation.
"""
import ctypes, ctypes.wintypes as w, json, os, pathlib, socket, subprocess, threading
if os.name!='nt' or os.environ.get('GITHUB_ACTIONS')!='true':raise RuntimeError('Ephemeral Windows Actions runner required')
root=pathlib.Path(os.environ['RUNNER_TEMP']); repo=pathlib.Path(os.environ['GITHUB_WORKSPACE'])/'published'
def command(args):
 p=subprocess.run(args,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=60)
 return {'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
A=ctypes.WinDLL('advapi32',use_last_error=True);K=ctypes.WinDLL('kernel32',use_last_error=True)
K.GetCurrentProcess.restype=w.HANDLE
A.OpenProcessToken.argtypes=[w.HANDLE,w.DWORD,ctypes.POINTER(w.HANDLE)]
A.GetTokenInformation.argtypes=[w.HANDLE,ctypes.c_int,w.LPVOID,w.DWORD,ctypes.POINTER(w.DWORD)]
token=w.HANDLE();assert A.OpenProcessToken(K.GetCurrentProcess(),8,ctypes.byref(token))
elevated=w.DWORD();size=w.DWORD();assert A.GetTokenInformation(token,20,ctypes.byref(elevated),4,ctypes.byref(size));K.CloseHandle(token)
result={'tokenElevated':bool(elevated.value),'netSessionBefore':command(['net','session']), 'serviceBefore':command(['sc.exe','query','LanmanServer'])}
was_running='RUNNING' in result['serviceBefore']['stdout']
try:
 if was_running:
  result['stopServer']=command(['powershell','-NoProfile','-Command',"Stop-Service LanmanServer -Force -ErrorAction Stop; (Get-Service LanmanServer).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(20))"])
 result['netSessionServerOff']=command(['net','session'])
 result['serverOffFalseNegative']=bool(elevated.value) and result['netSessionServerOff']['exit']!=0
finally:
 if was_running:
  result['restoreServer']=command(['powershell','-NoProfile','-Command','Start-Service LanmanServer -ErrorAction Stop'])
# Extract the original single-instance block, only substitute window-show calls.
s=(repo/'lib/main.dart').read_text(encoding='utf-8')
a=s.index('  if (Platform.isWindows) {',s.index('Future<void> main()'))
b=s.index('  try {\n    await windowManager.ensureInitialized();',a)
block=s[a:b].replace('windowManager.show().catchError((_) {});','Future<void>.value();').replace('windowManager.focus().catchError((_) {});','Future<void>.value();')
script=root/'v007-original-single-instance.dart'
script.write_text("import 'dart:io';\nimport 'dart:async';\nconst int kInstanceLockPort=46513;\nFuture<void> main() async {\n"+block+"print('SECONDARY_REACHED_APP_START');\n}\n",encoding='utf-8')
server=socket.socket();server.bind(('127.0.0.1',46513));server.listen();received=[]
def primary():
 c,_=server.accept()
 with c:
  received.append(c.recv(1024).decode());c.sendall(b'tokiboshi-ok')
t=threading.Thread(target=primary,daemon=True);t.start()
try:
 child=command([os.environ['DART_BIN'],str(script)])
 result['singleInstanceChildWhileParentOwnsLock']={'child':child,'primaryReceived':received,'parentLockStillHeld':True,'childExitedBeforeAppStartup':child['exit']==0 and 'SECONDARY_REACHED_APP_START' not in child['stdout'] and received==['tokiboshi-show']}
finally:server.close()
result['scope']='Native token/service controls and original socket branch under held-parent schedule; no GUI/UAC/TUN acceptance, no actual non-admin token measurement'
(root/'v007-native-controls.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(result,ensure_ascii=False,indent=2))
assert result['singleInstanceChildWhileParentOwnsLock']['childExitedBeforeAppStartup']
assert result['serverOffFalseNegative']
