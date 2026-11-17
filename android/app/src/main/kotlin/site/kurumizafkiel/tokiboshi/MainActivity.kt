package site.kurumizafkiel.tokiboshi

import android.app.Activity
import android.content.Intent
import android.content.ClipboardManager
import java.io.ByteArrayOutputStream
import android.net.VpnService
import android.os.Build
import android.Manifest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.libbox.Libbox
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingPermission: MethodChannel.Result? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "site.kurumizafkiel.tokiboshi/vpn")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "directories" -> result.success(mapOf("files" to filesDir.path, "cache" to cacheDir.path))
                        "version" -> result.success(Libbox.version())
                        "prepare" -> {
                            if (pendingPermission != null) { result.error("busy", "VPN 授权正在进行", null); return@setMethodCallHandler }
                            val consent = VpnService.prepare(this)
                            if (consent == null) result.success(true) else {
                                pendingPermission = result
                                startActivityForResult(consent, 9001)
                            }
                        }
                        "start" -> {
                            if (VpnService.prepare(this) != null) { result.error("permission", "请先允许 VPN 连接", null); return@setMethodCallHandler }
                            val path = call.argument<String>("configPath") ?: error("缺少配置路径")
                            val file = File(path).canonicalFile
                            require(file.path.startsWith(filesDir.canonicalPath + File.separator) && file.isFile) { "无效的私有配置文件" }
                            if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 9002)
                            val intent = Intent(this, TokiboshiVpnService::class.java).putExtra("configPath",file.path)
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                            result.success(null)
                        }
                        "stop" -> { TokiboshiVpnService.instance?.requestStop(); result.success(null) }
                        "status" -> result.success(VpnState.snapshot())
                        "logs" -> result.success(VpnState.logs())
                        "clipboardImage" -> {
                            val clipboard=getSystemService(ClipboardManager::class.java)
                            val uri=clipboard.primaryClip?.takeIf{it.itemCount>0}?.getItemAt(0)?.uri
                            if(uri==null || contentResolver.getType(uri)?.startsWith("image/")!=true)result.success(null)
                            else {
                                val bytes=contentResolver.openInputStream(uri)?.use { input ->
                                    val output=ByteArrayOutputStream();val buffer=ByteArray(8192)
                                    while(true){val n=input.read(buffer);if(n<0)break;require(output.size()+n<=20*1024*1024){"剪贴板图片超过20MiB"};output.write(buffer,0,n)}
                                    output.toByteArray()
                                };result.success(bytes)
                            }
                        }
                        "openUrl" -> { val url=call.argument<String>("url") ?: error("缺少链接"); require(url.startsWith("https://")); startActivity(Intent(Intent.ACTION_VIEW,android.net.Uri.parse(url)));result.success(null) }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) { result.error("android_vpn",e.message,null) }
            }
    }
    @Deprecated("Android activity result compatibility")
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if(requestCode==9001) { pendingPermission?.success(resultCode==Activity.RESULT_OK);pendingPermission=null }
    }
    override fun onDestroy() { pendingPermission?.error("cancelled","授权窗口已关闭",null);pendingPermission=null;super.onDestroy() }
}
