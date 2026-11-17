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
    private fun shell(command:String):ByteArray=instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
        android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use{it.readBytes()}
    }
    private fun await(reason:String,seconds:Int=30,predicate:()->Boolean){
        val deadline=System.currentTimeMillis()+seconds*1000
        while(System.currentTimeMillis()<deadline){if(predicate())return;Thread.sleep(150)}
        fail("$reason; phase=${VpnState.phase}; error=${VpnState.error}; logs=${VpnState.logs().takeLast(12)}")
    }
    private fun click(label:String){
        fun find()=device.findObject(By.text(label)) ?: device.findObject(By.desc(label)) ?: device.findObject(By.descContains(label))
        var view=find()
        if(view==null){for(i in 0..4){device.swipe(device.displayWidth/2,device.displayHeight*3/4,device.displayWidth/2,device.displayHeight/3,25);Thread.sleep(300);view=find();if(view!=null)break}}
        if(view==null){for(i in 0..5){device.swipe(device.displayWidth/2,device.displayHeight/3,device.displayWidth/2,device.displayHeight*3/4,25);Thread.sleep(300);view=find();if(view!=null)break}}
        (view ?: error("未找到界面操作：$label")).click();device.waitForIdle(3000)
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
        val request="GET /android-fixture HTTP/1.1
\nHost: fixture.example
\nConnection: close
\n
\n"
        return exchange("toybox timeout 12 toybox nc -w 8 -q 2 $target $port",request.toByteArray()).toString(Charsets.UTF_8)
    }
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
        val evidence=JSONObject()
        ActivityScenario.launch(MainActivity::class.java).use {
            device.wait(Until.hasObject(By.pkg(context.packageName).depth(0)),20000)
            Thread.sleep(2500)
            click("启动 VPN")
            await("Flutter → Rust 配置 → Android VPN 启动"){VpnState.phase=="running"}
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
            assertTrue(request("10.0.2.2",18081).contains("TOKIBOSHI_PROXY_B"))
            click("直连");await("直连模式"){runCatching{JSONObject(http("/configs").second).getString("mode").equals("direct",true)}.getOrDefault(false)}
            assertTrue(request("10.0.2.2",18081).contains("TOKIBOSHI_DIRECT"));evidence.put("globalDirectModes",true)
            click("规则");await("规则模式"){runCatching{JSONObject(http("/configs").second).getString("mode").equals("rule",true)}.getOrDefault(false)}
            device.pressHome();Thread.sleep(1000)
            assertEquals("running",VpnState.phase);assertTrue(request().contains("TOKIBOSHI_PROXY_B"));evidence.put("backgroundForegroundService",true)
            context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            click("停止 VPN");await("停止并关闭 VPN"){VpnState.phase=="stopped"&&TokiboshiVpnService.instance==null}
            evidence.put("cleanStop",true)
            click("启动 VPN");await("再次连接且不遗留端口或缓存锁"){VpnState.phase=="running"};assertTrue(request().contains("TOKIBOSHI_PROXY_B"))
            val images=File(context.getExternalFilesDir(null),"screenshots").apply{mkdirs()};device.takeScreenshot(File(images,"android-connected.png"))
            click("节点");device.takeScreenshot(File(images,"android-nodes.png"));click("设置");device.takeScreenshot(File(images,"android-settings.png"));click("连接")
            click("停止 VPN");await("二次停止"){VpnState.phase=="stopped"&&TokiboshiVpnService.instance==null};evidence.put("repeatConnect",true)
        }
        // Native DNS fixture exercises UDP interception from the independent shell UID.
        val original=JSONObject(File(context.filesDir,"config.json").readText())
        original.put("dns",JSONObject().put("servers",JSONArray().put(JSONObject().put("type","udp").put("tag","dns-fixture").put("server","10.0.2.2").put("server_port",15353))).put("final","dns-fixture"))
        original.getJSONObject("route").put("default_domain_resolver","dns-fixture")
        val dnsConfig=File(context.filesDir,"android-dns-fixture.json").apply{writeText(original.toString())}
        ActivityScenario.launch(MainActivity::class.java).use {
            context.startForegroundService(Intent(context,TokiboshiVpnService::class.java).putExtra("configPath",dnsConfig.path))
            await("DNS测试 VPN"){VpnState.phase=="running"}
            val query=byteArrayOf(0x12,0x34,1,0,0,1,0,0,0,0,0,0,7)+"fixture".toByteArray()+byteArrayOf(7)+"example".toByteArray()+byteArrayOf(0,0,1,0,1)
            val response=exchange("toybox timeout 8 toybox nc -u -w 4 -q 2 172.19.0.2 53",query)
            assertTrue("DNS响应必须包含正确事务与A记录",response.size>=16 && response[0]==0x12.toByte() && response[1]==0x34.toByte() && response.takeLast(4)==byteArrayOf(203.toByte(),0,113,10).toList())
            evidence.put("udpDnsHijack",true)
            context.stopService(Intent(context,TokiboshiVpnService::class.java));await("系统销毁服务清理"){VpnState.phase=="stopped"&&TokiboshiVpnService.instance==null};evidence.put("systemDestroyCleanup",true)
        }
        evidence.put("coreVersion",io.nekohasekai.libbox.Libbox.version()).put("passed",true)
        File(context.getExternalFilesDir(null),"android-vpn-results.json").writeText(evidence.toString(2))
    }
}
