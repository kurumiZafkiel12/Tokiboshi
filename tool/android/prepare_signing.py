"""Create/restore a release key; encrypt recovery material to the owner's public certificate.
No key/password is printed, committed, or included in the public artifact directory.
"""
import base64,hashlib,json,os,pathlib,secrets,subprocess,tarfile,tempfile
root=pathlib.Path(__file__).resolve().parents[2]
private=root/'build/android-signing-private';public=root/'build/android-signing-public'
private.mkdir(parents=True,exist_ok=True);private.chmod(0o700);public.mkdir(parents=True,exist_ok=True)
key=private/'tokiboshi-android.jks';restore=os.environ.get('TOKIBOSHI_ANDROID_KEYSTORE_BASE64','')
password=os.environ.get('TOKIBOSHI_ANDROID_STORE_PASSWORD') or secrets.token_urlsafe(40)
key_password=os.environ.get('TOKIBOSHI_ANDROID_KEY_PASSWORD') or password
alias=os.environ.get('TOKIBOSHI_ANDROID_KEY_ALIAS') or 'tokiboshi'
if restore:
 if not os.environ.get('TOKIBOSHI_ANDROID_STORE_PASSWORD'):raise SystemExit('Existing key requires its password')
 key.write_bytes(base64.b64decode(restore,validate=True))
else:
 # Never silently rotate the signing identity of an already published Android build.
 check=subprocess.run(['gh','api','repos/kurumiZafkiel12/Tokiboshi/releases/tags/v0.0.9-android-r1'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if check.returncode!=0 and b'HTTP 404' not in check.stderr:raise SystemExit('Unable to verify prior Android signing identity')
 if check.returncode==0:raise SystemExit('Android release exists: restore the existing signing key; refusing automatic rotation')
 environment=dict(os.environ,TOKIBOSHI_SIGN_STORE=password,TOKIBOSHI_SIGN_KEY=key_password)
 result=subprocess.run(['keytool','-genkeypair','-keystore',str(key),'-storetype','JKS','-alias',alias,'-keyalg','RSA','-keysize','3072','-validity','10000','-dname','CN=Tokiboshi Android,O=Tokiboshi','-storepass:env','TOKIBOSHI_SIGN_STORE','-keypass:env','TOKIBOSHI_SIGN_KEY'],env=environment,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 if result.returncode:raise SystemExit('Release signing key generation failed')
key.chmod(0o600)
properties=root/'android/key.properties'
properties.write_text(f'storeFile={key}\nstorePassword={password}\nkeyAlias={alias}\nkeyPassword={key_password}\n');properties.chmod(0o600)
environment=dict(os.environ,TOKIBOSHI_SIGN_STORE=password)
certificate=public/'android-signer.der'
subprocess.run(['keytool','-exportcert','-keystore',str(key),'-alias',alias,'-storepass:env','TOKIBOSHI_SIGN_STORE','-file',str(certificate)],env=environment,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
fingerprint=hashlib.sha256(certificate.read_bytes()).hexdigest()
(public/'signing-fingerprint.json').write_text(json.dumps({'certificateSha256':fingerprint,'algorithm':'RSA3072/SHA256','releaseKey':True,'restoredExistingKey':bool(restore)},indent=2)+'\n')
with tempfile.TemporaryDirectory(dir=private) as temp:
 directory=pathlib.Path(temp)
 (directory/'signing.json').write_text(json.dumps({'storePassword':password,'keyPassword':key_password,'keyAlias':alias,'certificateSha256':fingerprint}))
 archive=directory/'signing.tar'
 with tarfile.open(archive,'w') as tar:
  tar.add(key,arcname='tokiboshi-android.jks');tar.add(directory/'signing.json',arcname='signing.json')
 subprocess.run(['openssl','cms','-encrypt','-aes-256-gcm','-binary','-outform','DER','-in',str(archive),'-out',str(public/'Tokiboshi-Android-signing-backup.cms'),str(root/'tool/android/signing-recovery-public.pem')],check=True)
print('Release signing configured; certificate SHA256:',fingerprint)
