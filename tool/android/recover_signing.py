"""Decrypt the owner recovery artifact without printing credentials or extracting arbitrary paths."""
import argparse,hashlib,json,os,pathlib,subprocess,tarfile,tempfile
parser=argparse.ArgumentParser()
parser.add_argument('--backup',required=True,type=pathlib.Path)
parser.add_argument('--private-key',required=True,type=pathlib.Path)
parser.add_argument('--output-dir',required=True,type=pathlib.Path)
args=parser.parse_args()
output=args.output_dir.resolve();output.mkdir(parents=True,exist_ok=True);output.chmod(0o700)
for name in ['tokiboshi-android.jks','signing.json','key.properties']:
 if (output/name).exists():raise SystemExit('Recovery output already contains signing material; use a new private directory')
with tempfile.TemporaryDirectory(dir=output) as temp:
 directory=pathlib.Path(temp);archive=directory/'decrypted.tar'
 result=subprocess.run(['openssl','cms','-decrypt','-binary','-inform','DER','-in',str(args.backup.resolve()),'-inkey',str(args.private_key.resolve()),'-out',str(archive)],capture_output=True)
 if result.returncode:raise SystemExit('Signing recovery decryption failed')
 with tarfile.open(archive) as tar:
  members=tar.getmembers();assert sorted(m.name for m in members)==['signing.json','tokiboshi-android.jks']
  assert all(m.isfile() and m.size<=65536 for m in members)
  key_data=tar.extractfile('tokiboshi-android.jks').read();metadata=json.load(tar.extractfile('signing.json'))
 key=directory/'candidate.jks';key.write_bytes(key_data);key.chmod(0o600)
 certificate=directory/'signer.der'
 environment=dict(os.environ,TOKIBOSHI_RECOVERY_PASSWORD=metadata['storePassword'])
 result=subprocess.run(['keytool','-exportcert','-keystore',str(key),'-alias',metadata['keyAlias'],'-storepass:env','TOKIBOSHI_RECOVERY_PASSWORD','-file',str(certificate)],env=environment,capture_output=True)
 if result.returncode:raise SystemExit('Recovered key could not export its signing certificate')
 fingerprint=hashlib.sha256(certificate.read_bytes()).hexdigest()
 if fingerprint!=metadata['certificateSha256']:raise SystemExit('Recovered certificate fingerprint mismatch')
 final_key=output/'tokiboshi-android.jks';final_key.write_bytes(key_data);final_key.chmod(0o600)
 secrets_file=output/'signing.json';secrets_file.write_text(json.dumps(metadata));secrets_file.chmod(0o600)
 def property_value(value):return str(value).replace('\\','\\\\').replace('\n','\\n').replace('\r','\\r')
 properties={'storeFile':str(final_key),'storePassword':metadata['storePassword'],'keyAlias':metadata['keyAlias'],'keyPassword':metadata['keyPassword']}
 properties_file=output/'key.properties';properties_file.write_text(''.join(f'{key}={property_value(value)}\n' for key,value in properties.items()));properties_file.chmod(0o600)
 (output/'recovery-report.json').write_text(json.dumps({'certificateSha256':fingerprint,'recoveredExistingIdentity':True},indent=2)+'\n')
 print('Recovered and verified signing identity:',fingerprint)
