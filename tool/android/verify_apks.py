"""Verify signed, split release APKs, embedded architectures and 16 KiB compatibility."""
import hashlib,json,os,pathlib,re,struct,subprocess,zipfile
root=pathlib.Path(__file__).resolve().parents[2];sdk=pathlib.Path(os.environ['ANDROID_HOME']);tools=sdk/'build-tools/36.0.0'
packages=root/'build/android-packages';packages.mkdir(parents=True,exist_ok=True)
expected_cert=json.loads((root/'build/android-signing-public/signing-fingerprint.json').read_text())['certificateSha256']
results={}
def alignment(data):
 cls=data[4]
 if cls==2:offset=struct.unpack_from('<Q',data,32)[0];size,count=struct.unpack_from('<HH',data,54);fmt='<IIQQQQQQ'
 else:offset=struct.unpack_from('<I',data,28)[0];size,count=struct.unpack_from('<HH',data,42);fmt='<IIIIIIII'
 return [struct.unpack_from(fmt,data,offset+i*size)[-1] for i in range(count) if struct.unpack_from('<I',data,offset+i*size)[0]==1]
for abi,code in [('arm64-v8a',2014),('armeabi-v7a',1014),('x86_64',4014)]:
 source=root/f'build/app/outputs/flutter-apk/app-{abi}-release.apk';assert source.is_file(),source
 apk=packages/f'Tokiboshi-0.1.0-android-{abi}.apk';apk.write_bytes(source.read_bytes())
 check=subprocess.run([str(tools/'apksigner'),'verify','--verbose','--print-certs',str(apk)],capture_output=True,text=True,check=True).stdout
 match=re.search(r'Signer #1 certificate SHA-256 digest: ([0-9a-fA-F]+)',check);assert match and match[1].lower()==expected_cert
 assert 'Android Debug' not in check
 badging=subprocess.run([str(tools/'aapt'),'dump','badging',str(apk)],capture_output=True,text=True,check=True).stdout
 assert "name='site.kurumizafkiel.tokiboshi'" in badging and f"versionCode='{code}'" in badging and "versionName='0.1.0'" in badging
 assert "sdkVersion:'24'" in badging and "targetSdkVersion:'35'" in badging
 libraries={}
 with zipfile.ZipFile(apk) as z:
  assert z.testzip() is None
  abis={p.split('/')[1] for p in z.namelist() if p.startswith('lib/') and p.endswith('.so')};assert abis=={abi},abis
  for name in ['libapp.so','libflutter.so','librust_lib_tokiboshi.so','libbox.so']:
   data=z.read(f'lib/{abi}/{name}');load=alignment(data);assert load
   assert struct.unpack_from('<H',data,18)[0]=={'arm64-v8a':183,'armeabi-v7a':40,'x86_64':62}[abi]
   if abi!='armeabi-v7a':assert min(load)>=16384,(abi,name,load)
   libraries[name]={'sha256':hashlib.sha256(data).hexdigest(),'loadAlignments':load}
 subprocess.run([str(tools/'zipalign'),'-c','-P','16','4',str(apk)],capture_output=True,text=True,check=True)
 results[apk.name]={'abi':abi,'versionCode':code,'certificateSha256':expected_cert,'sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),'bytes':apk.stat().st_size,'libraries':libraries,'signatureVerified':True,'zipCrcPassed':True,'alignment16KiB':True}
(packages/'SHA256SUMS-android.txt').write_text(''.join(f"{value['sha256']}  {name}\n" for name,value in results.items()))
(packages/'android-package-verification.json').write_text(json.dumps({'releaseTag':'v0.1.0','packages':results,'passed':True},indent=2)+'\n')
print('Three signed APKs verified: ABI, version, signer, native libraries, CRC and alignment')
