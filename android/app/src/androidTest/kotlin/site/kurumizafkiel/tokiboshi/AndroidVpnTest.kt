package site.kurumizafkiel.tokiboshi

import android.content.Intent
import android.net.VpnService
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.*
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Real Android system VPN, loaded Rust bridge and embedded Go core; synthetic servers only. */
@RunWith(AndroidJUnit4::class)
class AndroidVpnTest {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context=instrumentation.targetContext
    private val device=UiDevice.getInstance(instrumentation)
    private val evidence=JSONObject()
    @After fun captureDiagnostics(){
        val directory=File(context.getExternalFilesDir(null),"diagnostics").apply{mkdirs()}
        File(directory,"progress.json").writeText(evidence.toString(2))
        File(directory,"vpn-state.json").writeText(JSONObject()
            .put("phase",VpnState.phase).put("error",VpnState.error)
            .put("logs",JSONArray(VpnState.logs())).toString(2))
        runCatching{device.dumpWindowHierarchy(File(directory,"ui.xml"))}
    }
    private fun shell(command:String):ByteArray=instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
        android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use{it.readBytes()}
    }
    private fun await(reason:String,seconds:Int=30,predicate:()->Boolean){
        val deadline=System.currentTimeMillis()+seconds*1000
        while(System.currentTimeMillis()<deadline){if(predicate())return;Thread.sleep(150)}
        fail("$reason; phase=${VpnState.phase}; error=${VpnState.error}; logs=${VpnState.logs().takeLast(12)}")
    }
    private fun click(label:String){
        fun find():androidx.test.uiautomator.UiObject2? {
            // Flutter navigation descriptions include a tab suffix; broad contains
            // also matches the disabled "导入节点或订阅" button for "节点".
            val candidates=(device.findObjects(By.text(label).pkg(context.packageName).enabled(true))+
                device.findObjects(By.desc(label).pkg(context.packageName).enabled(true))+
                device.findObjects(By.descStartsWith(label).pkg(context.packageName).enabled(true)))
            val actionable=candidates.mapNotNull { candidate ->
                var current:androidx.test.uiautomator.UiObject2?=candidate
                while(current!=null && !current.isClickable)current=current.parent
                current?.takeIf{it.isEnabled && !it.visibleBounds.isEmpty}
            }
            return if(label in listOf("连接","节点","订阅","设置")) actionable.maxByOrNull{it.visibleBounds.centerY()}
                else actionable.firstOrNull()
        }
        var view=find()
        val deadline=System.currentTimeMillis()+8000
        while(view==null && System.currentTimeMillis()<deadline){Thread.sleep(200);view=find()}
        if(view==null){for(i in 0..4){device.swipe(device.displayWidth/2,device.displayHeight*3/4,device.displayWidth/2,device.displayHeight/3,25);Thread.sleep(300);view=find();if(view!=null)break}}
        if(view==null){for(i in 0..5){device.swipe(device.displayWidth/2,device.displayHeight/3,device.displayWidth/2,device.displayHeight*3/4,25);Thread.sleep(300);view=find();if(view!=null)break}}
        if(view==null){
            val evidence=File(context.getExternalFilesDir(null),"failure").apply{mkdirs()}
            device.dumpWindowHierarchy(File(evidence,"ui.xml"))
            device.takeScreenshot(File(evidence,"ui.png"))
            error("未找到可点击的界面操作：$label")
        }
        view.click();device.waitForIdle(3000)
        Thread.sleep(250)
    }
    private fun awaitConnectedUi(){
        await("Flutter 界面确认 VPN 已连接且可停止"){
            (device.hasObject(By.text("VPN 已连接").pkg(context.packageName)) ||
                device.hasObject(By.desc("VPN 已连接").pkg(context.packageName))) &&
                (device.hasObject(By.text("停止 VPN").pkg(context.packageName).enabled(true)) ||
                device.hasObject(By.desc("停止 VPN").pkg(context.packageName).enabled(true)))
        }
        device.waitForIdle(3000)
    }
    private fun http(path:String,authorized:Boolean=true):Pair<Int,String>{
        val conn=URL("http://127.0.0.1:19090$path").openConnection() as HttpURLConnection
        conn.connectTimeout=5000;conn.readTimeout=5000
        if(authorized)conn.setRequestProperty("Authorization","Bearer android-synthetic-secret")
        return try{val status=conn.responseCode;status to (if(status<400)conn.inputStream else conn.errorStream).bufferedReader().use{it.readText()}}finally{conn.disconnect()}
    }
    private fun exchange(command:String,input:ByteArray):ByteArray {
        // UiAutomation uses Runtime.exec, not a shell: pipes/quotes are not interpreted.
        // The child runs as shell UID, which is intentionally outside the app VPN exclusion.
        val descriptors=instrumentation.uiAutomation.executeShellCommandRw(command)
        val pool=Executors.newSingleThreadExecutor { runnable -> Thread(runnable,"vpn-probe-reader").apply{isDaemon=true} }
        val reader=pool.submit<ByteArray> {
            android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptors[0]).use{it.readBytes()}
        }
        try {
            android.os.ParcelFileDescriptor.AutoCloseOutputStream(descriptors[1]).use{it.write(input)}
            return reader.get(15,TimeUnit.SECONDS)
        } finally {
            runCatching{descriptors[0].close()};runCatching{descriptors[1].close()}
            reader.cancel(true);pool.shutdownNow()
        }
    }
    private fun request(target:String="203.0.113.10",port:Int=80):String {
        val crlf=13.toChar().toString()+10.toChar()
        val request=listOf("GET /android-fixture HTTP/1.1","Host: fixture.example","Connection: close","","").joinToString(crlf)
        return exchange("toybox timeout 12 toybox nc -w 8 -q 2 $target $port",request.toByteArray()).toString(Charsets.UTF_8)
    }
    private fun validDnsAnswer(bytes:ByteArray):Boolean = runCatching {
        fun number(i:Int)=((bytes[i].toInt() and 255) shl 8) or (bytes[i+1].toInt() and 255)
        fun skipName(start:Int):Int {
            var offset=start
            repeat(128) {
                val length=bytes[offset].toInt() and 255
                if(length==0)return offset+1
                if((length and 192)==192){require(offset+1<bytes.size);return offset+2}
                require(length<=63);offset+=length+1;require(offset<=bytes.size)
            }
            error("DNS名称超长")
        }
        require(bytes.size>=12 && number(0)==0x1234 && (number(2) and 0x800f)==0x8000)
        var offset=12
        repeat(number(4)){offset=skipName(offset)+4}
        var matched=false
        repeat(number(6)) {
            offset=skipName(offset)
            val type=number(offset);val klass=number(offset+2);val length=number(offset+8)
            offset+=10;require(offset+length<=bytes.size)
            if(type==1 && klass==1 && length==4 && bytes.copyOfRange(offset,offset+4).contentEquals(byteArrayOf(203.toByte(),0,113,10)))matched=true
            offset+=length
        }
        matched
    }.getOrDefault(false)
    private fun fixtureData(){
        val nodes=JSONArray()
        for((name,port) in listOf("Android Fixture A" to 18080,"Android Fixture B" to 18082)){
            val outbound=JSONObject().put("type","socks").put("server","10.0.2.2").put("server_port",port)
            nodes.put(JSONObject().put("name",name).put("outboundJson",outbound.toString()).put("source","").put("group",""))
        }
        val data=JSONObject().put("nodes",nodes).put("subscriptions",JSONArray()).put("selectedIndex",0)
            .put("mixedPort",17890).put("clashApiPort",19090).put("clashApiSecret","android-synthetic-secret")
            .put("blockAds",false).put("bypassCn",false).put("autoConnect",false).put("activeProfileId","")
            .put("desktop",JSONObject().put("autoRun",false).put("autoCheckUpdates",false))
            .put("ui",JSONObject().put("motion","reduced").put("followSystem",true))
        File(context.filesDir,"data.json").writeText(data.toString())
    }
    @Test fun realFlutterConnectSwitchBackgroundModesStopAndDns(){
        shell("appops set ${context.packageName} ACTIVATE_VPN ignore")
        assertNotNull("系统未授权时应要求确认",VpnService.prepare(context))
        shell("appops set ${context.packageName} ACTIVATE_VPN allow")
        shell("pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS")
        assertNull("系统授权后不应重复索要权限",VpnService.prepare(context))
        fixtureData()
        ActivityScenario.launch(MainActivity::class.java).use {
            device.wait(Until.hasObject(By.pkg(context.packageName).depth(0)),20000)
            Thread.sleep(2500)
            click("启动 VPN")
            await("Flutter → Rust 配置 → Android VPN 启动"){VpnState.phase=="running"}
            awaitConnectedUi()
            assertEquals(401,http("/version",false).first)
            assertEquals(200,http("/version").first)
            assertTrue(request().contains("TOKIBOSHI_PROXY_A"))
            evidence.put("flutterRustVpnIpv4",true).put("controller401And200",true)
            assertTrue(request("2001:db8::10").contains("TOKIBOSHI_PROXY_A"))
            evidence.put("vpnIpv6",true)
            click("节点");click("Android Fixture B");click("连接")
            await("运行中切换节点"){runCatching{JSONObject(http("/proxies/proxy").second).getString("now")=="Android Fixture B"}.getOrDefault(false)}
            assertTrue(request().contains("TOKIBOSHI_PROXY_B"));evidence.put("liveNodeSwitch",true)
            click("全局");await("全局模式"){runCatching{JSONObject(http("/configs").second).getString("mode").equals("global",true)}.getOrDefault(false)}
            assertTrue("全局模式的非局域网目标必须走所选代理",request().contains("TOKIBOSHI_PROXY_B"))
            // The no-profile template intentionally routes private IPs before mode rules.
            assertTrue("全局模式保留局域网直连",request("10.0.2.2",18081).contains("TOKIBOSHI_DIRECT"))
            click("直连");await("直连模式"){runCatching{JSONObject(http("/configs").second).getString("mode").equals("direct",true)}.getOrDefault(false)}
            assertFalse("直连模式不得把非局域网目标交给代理",request().contains("TOKIBOSHI_PROXY_"))
            assertTrue(request("10.0.2.2",18081).contains("TOKIBOSHI_DIRECT"));evidence.put("globalDirectModes",true)
            click("规则");await("规则模式"){runCatching{JSONObject(http("/configs").second).getString("mode").equals("rule",true)}.getOrDefault(false)}
            device.pressHome();Thread.sleep(1000)
            assertEquals("running",VpnState.phase);assertTrue(request().contains("TOKIBOSHI_PROXY_B"));evidence.put("backgroundForegroundService",true)
            context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            click("停止 VPN");await("停止并关闭 VPN"){VpnState.phase=="stopped"&&TokiboshiVpnService.instance==null}
            evidence.put("cleanStop",true)
            click("启动 VPN");await("再次连接且不遗留端口或缓存锁"){VpnState.phase=="running"};assertTrue(request().contains("TOKIBOSHI_PROXY_B"))
            awaitConnectedUi()
            val images=File(context.getExternalFilesDir(null),"screenshots").apply{mkdirs()};device.takeScreenshot(File(images,"android-connected.png"))
            click("节点");device.takeScreenshot(File(images,"android-nodes.png"));click("设置");device.takeScreenshot(File(images,"android-settings.png"));click("连接")
            click("停止 VPN");await("二次停止"){VpnState.phase=="stopped"&&TokiboshiVpnService.instance==null};evidence.put("repeatConnect",true)

            val shared = "https://fixture.example/subscription"
            shell("am start -n ${context.packageName}/.MainActivity -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT $shared")
            await("系统分享填入导入编辑器"){device.hasObject(By.text(shared).pkg(context.packageName))}
            device.pressBack()
            // Back first hides the keyboard if the system opened it.
            if (device.hasObject(By.text(shared).pkg(context.packageName))) device.pressBack()
            await("取消分享导入"){!device.hasObject(By.text(shared).pkg(context.packageName))}
            evidence.put("sharedLinkReview",true)

            val tile = "${context.packageName}/.VpnQuickTile"
            shell("cmd statusbar add-tile $tile")
            shell("cmd statusbar expand-settings")
            Thread.sleep(750)
            shell("cmd statusbar click-tile $tile")
            await("快捷磁贴从已保存的出口启动 VPN"){VpnState.phase=="running"}
            assertTrue(request().contains("TOKIBOSHI_PROXY_B"))
            evidence.put("quickTile", true)
            val manager=context.getSystemService(android.app.NotificationManager::class.java)
            val action=manager.activeNotifications.flatMap{it.notification.actions?.toList().orEmpty()}
                .single{it.title.toString()=="断开 VPN"}
            action.actionIntent.send()
            await("通知动作停止 VPN 并清理接口"){VpnState.phase=="stopped"&&TokiboshiVpnService.instance==null}
            shell("cmd statusbar remove-tile $tile")
            shell("cmd statusbar collapse")
            evidence.put("notificationStop",true)
        }
        // Native DNS fixture exercises UDP interception from the independent shell UID.
        val original=JSONObject(File(context.filesDir,"config.json").readText())
        original.put("dns",JSONObject().put("servers",JSONArray().put(JSONObject().put("type","udp").put("tag","dns-fixture").put("server","10.0.2.2").put("server_port",15353))).put("final","dns-fixture"))
        original.getJSONObject("route").put("default_domain_resolver","dns-fixture")
        val dnsConfig=File(context.filesDir,"android-dns-fixture.json").apply{writeText(original.toString())}
        ActivityScenario.launch(MainActivity::class.java).use {
            val onlySettings=Intent(context,TokiboshiVpnService::class.java)
                .putExtra("configPath",dnsConfig.path)
                .putStringArrayListExtra("includedApps",arrayListOf("com.android.settings"))
            context.startForegroundService(onlySettings)
            await("指定应用 VPN 建立"){VpnState.phase=="running"}
            assertFalse("未列入的 shell UID 不得走代理",request().contains("TOKIBOSHI_PROXY_"))
            assertTrue(request("10.0.2.2",18081).contains("TOKIBOSHI_DIRECT"))
            TokiboshiVpnService.instance?.requestStop()
            await("分应用 VPN 已停止"){VpnState.phase=="stopped"&&TokiboshiVpnService.instance==null}
            evidence.put("appAllowList",true)
            context.startForegroundService(Intent(context,TokiboshiVpnService::class.java).putExtra("configPath",dnsConfig.path))
            await("DNS测试 VPN"){VpnState.phase=="running"}
            val query=byteArrayOf(0x12,0x34,1,0,0,1,0,0,0,0,0,0,7)+"fixture".toByteArray()+byteArrayOf(7)+"example".toByteArray()+byteArrayOf(0,0,1,0,1)
            val testApk=instrumentation.context.packageCodePath
            val targetApk=context.packageCodePath
            val response=exchange("env CLASSPATH=$testApk:$targetApk app_process /system/bin site.kurumizafkiel.tokiboshi.DnsShellProbe",query)
            File(context.getExternalFilesDir(null),"dns-response.bin").writeBytes(response)
            assertTrue("DNS响应必须包含正确事务与A记录，收到${response.size}字节",validDnsAnswer(response))
            evidence.put("udpDnsHijack",true)
            // stopService alone does not destroy an active VPN: Android still binds
            // its service. Revoke consent, then prepare again so system_server resets
            // the TUN, delivers onRevoke and unbinds (AOSP Vpn.prepareInternal).
            shell("appops set ${context.packageName} ACTIVATE_VPN ignore")
            assertNotNull("撤销授权后必须重新确认",VpnService.prepare(context))
            await("系统撤销 VPN 授权并销毁服务"){VpnState.phase=="stopped"&&TokiboshiVpnService.instance==null}
            evidence.put("systemRevokeCleanup",true).put("systemDestroyCleanup",true)
        }
        evidence.put("coreVersion",io.nekohasekai.libbox.Libbox.version()).put("passed",true)
        File(context.getExternalFilesDir(null),"android-vpn-results.json").writeText(evidence.toString(2))
    }
}
