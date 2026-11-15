"""Native Windows audit of the immutable v0.0.5 release and its exact Store source.
All files are synthetic. No system proxy, DNS, TUN or user APPDATA is changed.
"""
import ctypes, ctypes.wintypes as w
import hashlib, json, os, pathlib, shutil, subprocess, time
ROOT = pathlib.Path(os.environ['AUDIT_ROOT'])
SOURCE = pathlib.Path(os.environ['AUDIT_SOURCE'])
OUT = ROOT / 'results'; OUT.mkdir(parents=True, exist_ok=True)
TAGS = ['geosite-category-ads-all', 'geosite-cn', 'geoip-cn']
subject = ROOT / 'subject.dart'
subject.write_text((pathlib.Path(__file__).parent/'subject.dart.template').read_text().replace('@@SOURCE@@', SOURCE.as_uri()), encoding='utf-8')
CMD = [os.environ['DART_BIN'], '--packages='+str(SOURCE/'.dart_tool/package_config.json'), str(subject)]
K = ctypes.WinDLL('kernel32', use_last_error=True)
K.CreateFileW.argtypes = [w.LPCWSTR,w.DWORD,w.DWORD,w.LPVOID,w.DWORD,w.DWORD,w.HANDLE]
K.CreateFileW.restype = w.HANDLE
K.CloseHandle.argtypes = [w.HANDLE]
def lock(path):
    h = K.CreateFileW(str(path), 0x80000000, 1, None, 3, 0x80, None)
    if h == ctypes.c_void_p(-1).value: raise ctypes.WinError(ctypes.get_last_error())
    return h
def run(mode, folder):
    p = subprocess.run(CMD+[mode,str(folder)], capture_output=True,text=True,encoding='utf-8',timeout=250)
    if p.returncode: raise RuntimeError(p.stderr)
    return json.loads(p.stdout)
def save(name, result):
    (OUT/(name+'.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
def rule_case(name):
    p=ROOT/name; (p/'core').mkdir(parents=True)
    shutil.copy2(os.environ['AUDIT_CORE'],p/'core/sing-box.exe')
    return p
results = {}
# Real empty-directory download must commit three real SRS files.
fresh=rule_case('rules-download')
r=run('rules-download',fresh)
r['passed']=r['complete'] and len(r['files'])==3 and r['configCheckExit']==0 and len(r['generatedTags'])==3 and any('3/3 就绪' in s for s in r['logs']) and not r['coreRunning']
results['download_3_of_3']=r;save('rules-download',r)
# Three-state summary: actual write obstruction, partial obstruction, and fresh real files.
for name, keep in [('rules-zero',0),('rules-two',2),('rules-three',3)]:
    p=rule_case(name);(p/'rules').mkdir()
    for i,tag in enumerate(TAGS):
        if i<keep: shutil.copyfile(fresh/'rules'/f'{tag}.srs',p/'rules'/f'{tag}.srs')
        else: (p/'rules'/f'{tag}.srs.tmp').mkdir()
    r=run('rules-summary',p)
    expected=f'{keep}/3 '+('就绪' if keep==3 else '可用')
    r['passed']=r['complete'] and any(expected in s for s in r['logs']) and (keep==3 or not any('3/3 就绪' in s for s in r['logs']))
    results[name]=r;save(name,r)
# Lock an actual valid old SRS; do not pre-seed tmp to mask a missing-write regression.
p=rule_case('rules-locked');(p/'rules').mkdir()
for tag in TAGS: shutil.copyfile(fresh/'rules'/f'{tag}.srs',p/'rules'/f'{tag}.srs')
target=p/'rules/geoip-cn.srs';old=hashlib.sha256(target.read_bytes()).hexdigest();past=time.time()-172800;os.utime(target,(past,past))
h=lock(target)
try:
    r=run('rules-summary',p)
    r['oldFilePreserved']=hashlib.sha256(target.read_bytes()).hexdigest()==old
    r['passed']=r['complete'] and r['oldFilePreserved'] and not r['tmpFiles'] and any('提交失败' in s for s in r['logs']) and any('2/3 可用' in s for s in r['logs'])
finally:K.CloseHandle(h)
results['locked_rule_rename']=r;save('rules-locked',r)
# Save under a real Windows lock; backup bytes and tmp must survive, then load recovers tmp.
p=ROOT/'store-locked';p.mkdir();main=p/'data.json';bak=p/'data.json.bak'
main.write_text(json.dumps({'mixedPort':18991,'nodes':[]}),encoding='utf-8');bak.write_text(json.dumps({'mixedPort':18990,'nodes':[]}),encoding='utf-8');old_bak=bak.read_bytes()
os.utime(main,(time.time()-60,time.time()-60));h=lock(main)
try:
    r=run('store-save',p);r['backupBytesPreserved']=bak.exists() and bak.read_bytes()==old_bak
finally:K.CloseHandle(h)
r['afterUnlock']=run('store-load',p)
r['passed']=r['errorType']=='StoreSaveException' and r['backupBytesPreserved'] and r['tmpExists'] and r['tmpPort']==18992 and r['mainPort']==18991 and r['afterUnlock']['loadedPort']==18992 and not r['afterUnlock']['tmpExists']
results['locked_main_save']=r;save('store-locked',r)
# Use explicit Windows mtime gaps, not sleeps or filesystem timestamp coincidence.
for name,newer in [('tmp-newer',True),('tmp-older',False),('tmp-equal',None)]:
    p=ROOT/name;p.mkdir();main=p/'data.json';tmp=p/'data.json.tmp'
    main.write_text(json.dumps({'mixedPort':18991,'nodes':[]}),encoding='utf-8');tmp.write_text(json.dumps({'mixedPort':18992,'nodes':[]}),encoding='utf-8')
    now=time.time()-120;os.utime(main,(now,now));tm=now+(30 if newer else -30 if newer is False else 0);os.utime(tmp,(tm,tm))
    r=run('store-load',p);r['mainMtimeBefore']=now;r['tmpMtimeBefore']=tm;r['passed']=r['loadedPort']==(18992 if newer else 18991) and r['mainPort']==r['loadedPort']
    results[name]=r;save(name,r)
save('summary',{'release':'v0.0.5','source':'a2bbaf34eb4dab54c272bda02a46d2c15f4bdb28','cases':{k:v['passed'] for k,v in results.items()},'allPassed':all(v['passed'] for v in results.values()),'scope':'actual release DLL/core, original Store; no system network changes; not GUI/TUN/focus acceptance'})
print(json.dumps({k:v['passed'] for k,v in results.items()}))
if not all(v['passed'] for v in results.values()):raise SystemExit(1)
