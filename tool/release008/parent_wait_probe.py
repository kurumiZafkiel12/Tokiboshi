import os,pathlib,subprocess,time,json
root=pathlib.Path(os.environ['T069_OUT']);root.mkdir(parents=True,exist_ok=True);ready=root/'parent-wait-ready'
parent=subprocess.Popen(['powershell','-NoProfile','-Command','Start-Sleep -Seconds 30'])
child=None
try:
 child=subprocess.Popen([os.environ['DART_BIN'],'run','tool/release008/parent_wait_probe.dart',str(parent.pid),str(ready)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 for _ in range(100):
  if ready.exists():break
  if child.poll() is not None:raise RuntimeError('Wait child failed before ready')
  time.sleep(.1)
 else:raise RuntimeError('Wait child not ready')
 time.sleep(.4);assert child.poll() is None,'Child did not wait for living parent'
 parent.terminate();parent.wait(timeout=5)
 stdout,stderr=child.communicate(timeout=10);result=json.loads(stdout)
 assert child.returncode==0 and result['parentExited'],stderr
 result['waitedWhileParentAlive']=True
 (root/'native-parent-wait.json').write_text(json.dumps(result,indent=2));print(result)
finally:
 for p in [child,parent]:
  if p is not None and p.poll() is None:p.kill();p.wait()
