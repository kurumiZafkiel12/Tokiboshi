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
 # CI may build a candidate with a temporary identity. It cannot be used for release.
 if os.environ.get('TOKIBOSHI_ANDROID_CANDIDATE_SIGNING') != '1':
  raise SystemExit('Restore the official Android signing key before building release packages')
 environment=dict(os.environ,TOKIBOSHI_SIGN_STORE=password,TOKIBOSHI_SIGN_KEY=key_password)
 result=subprocess.run(['keytool','-genkeypair','-keystore',str(key),'-storetype','JKS','-alias',alias,'-keyalg','RSA','-keysize','3072','-validity','10000','-dname','CN=Tokiboshi Android,O=Tokiboshi','-storepass:env','TOKIBOSHI_SIGN_STORE','-keypass:env','TOKIBOSHI_SIGN_KEY'],env=environment,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 if result.returncode:raise SystemExit('Release signing key generation failed')
key.chmod(0o600)
properties=root/'android/key.properties'
properties.write_text(f'storeFile={key}\nstorePassword={password}\nkeyAlias={alias}\nkeyPassword={key_password}\n');properties.chmod(0o600)
environment=dict(os.environ,TOKIBOSHI_SIGN_STORE=password)
certificate=public/'android-signer.der'
subprocess.run(['keytool','-exportcert','-keystore',str(key),'-alias',alias,'-storepass:env','TOKIBOSHI_SIGN_STORE','-file',str(certificate)],env=environment,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
subject=subprocess.run(['openssl','x509','-inform','DER','-in',str(certificate),'-noout','-subject'],capture_output=True,text=True,check=True).stdout
if 'Android Debug' in subject:raise SystemExit('Refusing a debug signing identity')
fingerprint=hashlib.sha256(certificate.read_bytes()).hexdigest()
expected='c91d88b4284c40e97e2e270677c0ba083c40789a8f8bc85bbb3c70d02b49c726'
if restore and fingerprint != expected:raise SystemExit('Restored Android signer does not match the published signing identity')
(public/'signing-fingerprint.json').write_text(json.dumps({'certificateSha256':fingerprint,'releaseKey':bool(restore),'restoredExistingKey':bool(restore)},indent=2)+'\n')
if not restore:
 print('Temporary candidate signer, do not publish:',fingerprint)
 raise SystemExit(0)
with tempfile.TemporaryDirectory(dir=private) as temp:
 directory=pathlib.Path(temp)
 (directory/'signing.json').write_text(json.dumps({'storePassword':password,'keyPassword':key_password,'keyAlias':alias,'certificateSha256':fingerprint}))
 archive=directory/'signing.tar'
 with tarfile.open(archive,'w') as tar:
  tar.add(key,arcname='tokiboshi-android.jks');tar.add(directory/'signing.json',arcname='signing.json')
 subprocess.run(['openssl','cms','-encrypt','-aes-256-gcm','-binary','-outform','DER','-in',str(archive),'-out',str(public/'Tokiboshi-Android-signing-backup.cms'),str(root/'tool/android/signing-recovery-public.pem'),str(root/'tool/android/signing-recovery-codex-public.pem')],check=True)
print('Release signing configured; certificate SHA256:',fingerprint)
