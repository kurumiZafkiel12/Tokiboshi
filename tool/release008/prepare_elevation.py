"""Copy immutable v007 main; replace external process/exit seams, expose state for tests.
Business methods and dialog branches remain original, not reimplemented models.
"""
import pathlib,sys,shutil
p=pathlib.Path(sys.argv[1])
s=(p/'lib/main.dart').read_text(encoding='utf-8')
s=s.replace("Process.run('net', ['session'])", "auditProcessRun('net', ['session'])")
s=s.replace("Process.run('powershell', [", "auditProcessRun('powershell', [")
s=s.replace('exit(0);','auditExit(0);')
s+='''
// Test-only public access; production files remain untouched.
late Future<ProcessResult> Function(String, List<String>) auditProcessRun;
int? auditExitCode;
void auditExit(int code) { auditExitCode = code; }
Future<bool> auditElevation() => _isElevated();
Future<void> auditToggle(State s) => (s as _ShellPageState)._toggleCore();
Future<void> auditTun(State s, bool v) => (s as _ShellPageState)._setTun(v);
Future<void> auditRelaunch(State s) => (s as _ShellPageState)._relaunchElevated();
void auditPrepare(State s, {required bool running}) {
 final x=s as _ShellPageState; x._statusTimer?.cancel(); x._running=running;
}
Map<String,dynamic> auditSnapshot(State s) {
 final x=s as _ShellPageState;
 return {'running':x._running,'busy':x._busy,'cleanExit':x._data.cleanExit,
 'runningAtExit':x._data.runningAtExit,'resumeConnect':x._data.resumeConnect,'enableTun':x._data.enableTun,
 'trayReady':x._trayReady,'message':x._message,'saveFailed':x._saveFailed};
}
'''
(p/'lib/main_v007_audit.dart').write_text(s,encoding='utf-8')
shutil.copyfile(pathlib.Path(__file__).parent/'elevation_test.dart.template',p/'test/elevation_generated_test.dart')
