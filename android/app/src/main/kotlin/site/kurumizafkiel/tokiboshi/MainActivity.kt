package site.kurumizafkiel.tokiboshi

import android.app.Activity
import android.app.StatusBarManager
import android.content.ComponentName
import android.graphics.drawable.Icon
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
    private var entryChannel: MethodChannel? = null
    private var pendingEntry: Map<String, String>? = null

    private fun stageEntry(intent: Intent) {
        val entry = when (intent.action) {
            ACTION_CONNECT -> if (intent.getStringExtra(EXTRA_CONNECT_TOKEN) == connectToken) mapOf("type" to "connect") else null
            Intent.ACTION_SEND -> intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
                ?.toString()?.takeIf { it.isNotBlank() && it.length <= 65536 }
                ?.let { mapOf("type" to "share", "text" to it) }
            else -> null
        } ?: return
        intent.action = Intent.ACTION_MAIN
        intent.removeExtra(Intent.EXTRA_TEXT)
        intent.removeExtra(EXTRA_CONNECT_TOKEN)
        pendingEntry = entry
        entryChannel?.invokeMethod("entryChanged", null)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // External actions are transient. Keep the activity launch intent stable.
        stageEntry(Intent(intent))
    }

    private var pendingBackup: Pair<File, MethodChannel.Result>? = null
    private var pendingPermission: MethodChannel.Result? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "site.kurumizafkiel.tokiboshi/vpn")
        entryChannel = channel
        stageEntry(intent)
        channel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "takeEntry" -> {
                            result.success(pendingEntry)
                            pendingEntry = null
                        }
                        "addQuickTile" -> {
                            if (Build.VERSION.SDK_INT < 33) {
                                result.success(null)
                            } else {
                                getSystemService(StatusBarManager::class.java).requestAddTileService(
                                    ComponentName(this, VpnQuickTile::class.java), getString(R.string.app_name),
                                    Icon.createWithResource(this, R.drawable.ic_vpn), mainExecutor
                                ) { code -> result.success(code) }
                            }
                        }
                        "directories" -> result.success(mapOf("files" to filesDir.path, "cache" to cacheDir.path))
                        "vpnApps" -> {
                            val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                            val apps = packageManager.queryIntentActivities(launcher, 0)
                                .filter { it.activityInfo.packageName != packageName }
                                .distinctBy { it.activityInfo.packageName }
                                .map { mapOf("id" to it.activityInfo.packageName,
                                    "name" to it.loadLabel(packageManager).toString()) }
                            result.success(apps)
                        }
                        "vpnSettings" -> {
                            startActivity(Intent(android.provider.Settings.ACTION_VPN_SETTINGS))
                            result.success(null)
                        }
                        "notificationSettings" -> {
                            val settings = if (Build.VERSION.SDK_INT >= 26)
                                Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                    .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                            else Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                android.net.Uri.fromParts("package", packageName, null))
                            startActivity(settings)
                            result.success(null)
                        }
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
                            if (Build.VERSION.SDK_INT >= 33 &&
                                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED &&
                                !getPreferences(MODE_PRIVATE).getBoolean("notificationAsked", false)) {
                                getPreferences(MODE_PRIVATE).edit().putBoolean("notificationAsked", true).apply()
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 9002)
                            }
                            val intent = Intent(this, TokiboshiVpnService::class.java).putExtra("configPath",file.path)
                            val excluded = call.argument<List<String>>("excludedApps").orEmpty()
                            require(excluded.size <= 512) { "排除应用过多" }
                            val included = call.argument<List<String>>("includedApps")
                            require(included == null || (included.isNotEmpty() && included.size <= 512)) { "请选择允许通过 VPN 的应用" }
                            intent.putStringArrayListExtra("excludedApps", ArrayList(excluded))
                            if (included != null) intent.putStringArrayListExtra("includedApps", ArrayList(included))
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
                        "exportBackup" -> {
                            check(pendingBackup == null) { "已有备份导出正在进行" }
                            val path = call.argument<String>("path") ?: error("缺少备份路径")
                            val file = File(path).canonicalFile
                            require(file.path.startsWith(filesDir.canonicalPath + File.separator) &&
                                file.isFile && file.length() <= 64L * 1024 * 1024) { "无效的备份文件" }
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/json"
                                putExtra(Intent.EXTRA_TITLE, "Tokiboshi-backup.json")
                            }
                            pendingBackup = file to result
                            try {
                                startActivityForResult(intent, 9003)
                            } catch (error: Exception) {
                                pendingBackup = null
                                throw error
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
        if (requestCode == 9003) {
            val (file, result) = pendingBackup ?: return
            pendingBackup = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                result.success(false)
                return
            }
            Thread {
                try {
                    val output = contentResolver.openOutputStream(uri, "wt")
                        ?: error("无法写入所选文件")
                    output.use { target -> file.inputStream().use { it.copyTo(target) } }
                    runOnUiThread { result.success(true) }
                } catch (error: Exception) {
                    runOnUiThread { result.error("backup", "无法写入所选文件", null) }
                }
            }.start()
        }
        if(requestCode==9001) { pendingPermission?.success(resultCode==Activity.RESULT_OK);pendingPermission=null }
    }
    override fun onDestroy() {
        entryChannel?.setMethodCallHandler(null)
        entryChannel = null
        pendingBackup?.second?.success(false)
        pendingBackup = null
        pendingPermission?.error("cancelled","授权窗口已关闭",null);pendingPermission=null;super.onDestroy() }
    companion object {
        val connectToken: String = java.util.UUID.randomUUID().toString()
        const val EXTRA_CONNECT_TOKEN = "connectToken"
        const val ACTION_CONNECT = "site.kurumizafkiel.tokiboshi.CONNECT"
    }
}
