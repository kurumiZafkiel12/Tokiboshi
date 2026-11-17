package site.kurumizafkiel.tokiboshi

import android.app.*
import android.content.Intent
import android.net.*
import android.os.*
import android.system.OsConstants
import io.nekohasekai.libbox.*
import java.io.File
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.NetworkInterface as JavaInterface
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** All core lifecycle operations are serialized; stopping invalidates in-flight starts. */
class TokiboshiVpnService : VpnService(), PlatformInterface, CommandServerHandler {
    companion object { @Volatile var instance:TokiboshiVpnService?=null; const val CHANNEL="tokiboshi-vpn" }
    private val worker=Executors.newSingleThreadExecutor()
    private val generation=AtomicInteger()
    private var server:CommandServer?=null
    private var logClient:CommandClient?=null
    private var tunnel:ParcelFileDescriptor?=null
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }
    @Volatile private var listener:InterfaceUpdateListener?=null
    @Volatile private var network:Network?=null
    private var monitorRegistered=false
    private val networks=java.util.concurrent.ConcurrentHashMap<Network,Boolean>()
    private val callback=object:ConnectivityManager.NetworkCallback(){
        override fun onAvailable(n:Network) { networks[n]=true; refreshNetwork() }
        override fun onLost(n:Network) { networks.remove(n); refreshNetwork() }
        override fun onLinkPropertiesChanged(n:Network,p:LinkProperties) { refreshNetwork() }
        override fun onCapabilitiesChanged(n:Network,c:NetworkCapabilities) { refreshNetwork() }
    }
    override fun onCreate(){super.onCreate();instance=this}
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        val token=generation.incrementAndGet()
        VpnState.phase="starting";VpnState.error=null
        showNotification("正在连接…")
        val path=intent?.getStringExtra("configPath")
        worker.execute {
            try {
                require(path!=null) {"缺少配置文件"}
                closeCore()
                if(token!=generation.get())return@execute
                val directory=filesDir.absolutePath
                Libbox.setup(SetupOptions().apply {
                    basePath=directory;workingPath=directory;tempPath=cacheDir.absolutePath
                    fixAndroidStack=true;logMaxLines=400;appVersion="0.0.9-r2-android";appMarketingVersion="0.0.9"
                })
                val content=File(path).readText()
                Libbox.checkConfig(content)
                val core=Libbox.newCommandServer(this,this);server=core
                core.start()
                core.startOrReloadService(content,OverrideOptions())
                if(token!=generation.get()){closeCore();return@execute}
                check(tunnel!=null){"VPN 网卡未建立"}
                VpnState.phase="running";VpnState.log("VPN 已连接 · sing-box ${Libbox.version()}")
                showNotification("VPN 已连接 · 点击打开应用")
                val options=CommandClientOptions().apply{addCommand(Libbox.CommandLog)}
                logClient=Libbox.newCommandClient(CoreLogs(),options).also{it.connect()}
            }catch(e:Exception){
                closeCore()
                if(token==generation.get()){
                    VpnState.error=e.message?.take(2000) ?: "VPN 启动失败"
                    VpnState.phase="error";VpnState.log("启动失败：${VpnState.error}")
                    stopForeground(STOP_FOREGROUND_REMOVE);stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }
    fun requestStop(){
        generation.incrementAndGet();VpnState.phase="stopping"
        worker.execute {closeCore();VpnState.phase="stopped";VpnState.error=null;VpnState.log("VPN 已断开");stopForeground(STOP_FOREGROUND_REMOVE);stopSelf()}
    }
    private fun closeCore(){
        runCatching{logClient?.disconnect()};logClient=null
        runCatching{server?.closeService()};runCatching{server?.close()};server=null
        runCatching{tunnel?.close()};tunnel=null
        if(monitorRegistered){runCatching{connectivity.unregisterNetworkCallback(callback)};monitorRegistered=false}
        listener=null;network=null;networks.clear()
    }
    override fun onRevoke(){requestStop();super.onRevoke()}
    override fun onDestroy(){
        generation.incrementAndGet();instance=null
        worker.execute{closeCore();if(VpnState.phase!="error")VpnState.phase="stopped"}
        worker.shutdown();super.onDestroy()
    }
    private fun showNotification(text:String){
        val manager=getSystemService(NotificationManager::class.java)
        if(Build.VERSION.SDK_INT>=26)manager.createNotificationChannel(NotificationChannel(CHANNEL,"VPN 连接",NotificationManager.IMPORTANCE_LOW))
        val pending=PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder=if(Build.VERSION.SDK_INT>=26)android.app.Notification.Builder(this,CHANNEL)else android.app.Notification.Builder(this)
        startForeground(1,builder.setSmallIcon(site.kurumizafkiel.tokiboshi.R.drawable.ic_vpn).setContentTitle("Tokiboshi · 時の星").setContentText(text).setContentIntent(pending).setOngoing(true).build())
    }
    override fun openTun(options:TunOptions):Int {
        check(prepare(this)==null){"VPN 授权已取消"}
        val b=Builder().setSession("Tokiboshi").setMtu(options.mtu)
        if(Build.VERSION.SDK_INT>=29)b.setMetered(false)
        val v4=options.inet4Address;while(v4.hasNext()){val p=v4.next();b.addAddress(p.address(),p.prefix())}
        val v6=options.inet6Address;while(v6.hasNext()){val p=v6.next();b.addAddress(p.address(),p.prefix())}
        if(options.autoRoute){
            val dns=options.dnsServerAddress;while(dns.hasNext())b.addDnsServer(dns.next())
            val routes4=options.inet4RouteRange;var has4=false
            while(routes4.hasNext()){val p=routes4.next();b.addRoute(p.address(),p.prefix());has4=true}
            if(!has4 && options.inet4Address.hasNext())b.addRoute("0.0.0.0",0)
            val routes6=options.inet6RouteRange;var has6=false
            while(routes6.hasNext()){val p=routes6.next();b.addRoute(p.address(),p.prefix());has6=true}
            if(!has6 && options.inet6Address.hasNext())b.addRoute("::",0)
        }
        // Own subscription/control traffic must never recurse through the tunnel.
        b.addDisallowedApplication(packageName)
        val descriptor=b.establish() ?: error("系统拒绝创建 VPN 网卡")
        tunnel=descriptor;return descriptor.fd
    }
    override fun usePlatformAutoDetectInterfaceControl()=true
    override fun autoDetectInterfaceControl(fd:Int){check(protect(fd)){"无法保护出站 socket"}}
    private fun physical(n:Network):Boolean=connectivity.getNetworkCapabilities(n)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)==true
    private fun refreshNetwork(){
        val chosen=connectivity.activeNetwork?.takeIf(::physical)
            ?: networks.keys.firstOrNull(::physical)
            ?: connectivity.allNetworks.firstOrNull(::physical)
        network=chosen
        val properties=chosen?.let(connectivity::getLinkProperties)
        val name=properties?.interfaceName ?: ""
        val index=if(name.isEmpty())-1 else runCatching{JavaInterface.getByName(name).index}.getOrDefault(-1)
        val caps=chosen?.let(connectivity::getNetworkCapabilities)
        listener?.updateDefaultInterface(name,index,caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)==false,false)
        if(chosen!=null)setUnderlyingNetworks(arrayOf(chosen))
    }
    override fun startDefaultInterfaceMonitor(update:InterfaceUpdateListener){
        listener=update
        if(!monitorRegistered){connectivity.registerNetworkCallback(NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(),callback);monitorRegistered=true}
        refreshNetwork()
    }
    override fun closeDefaultInterfaceMonitor(update:InterfaceUpdateListener){
        listener=null
        if(monitorRegistered){connectivity.unregisterNetworkCallback(callback);monitorRegistered=false}
    }
    override fun getInterfaces():NetworkInterfaceIterator {
        val values=mutableListOf<io.nekohasekai.libbox.NetworkInterface>()
        for(n in connectivity.allNetworks){
            if(!physical(n))continue
            val p=connectivity.getLinkProperties(n) ?: continue
            val caps=connectivity.getNetworkCapabilities(n) ?: continue
            val j=runCatching{JavaInterface.getByName(p.interfaceName)}.getOrNull() ?: continue
            values.add(io.nekohasekai.libbox.NetworkInterface().apply {
                name=j.name;index=j.index;mtu=runCatching{j.mtu}.getOrDefault(1500)
                addresses=Strings(j.interfaceAddresses.mapNotNull{ip->ip.address.hostAddress?.substringBefore('%')?.let{"$it/${ip.networkPrefixLength}"}})
                dnsServer=Strings(p.dnsServers.mapNotNull{it.hostAddress})
                gateway=Strings(p.routes.filter{it.isDefaultRoute}.mapNotNull{it.gateway?.hostAddress})
                flags=OsConstants.IFF_UP or OsConstants.IFF_RUNNING
                type=when{
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)->Libbox.InterfaceTypeWIFI
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)->Libbox.InterfaceTypeCellular
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)->Libbox.InterfaceTypeEthernet
                    else->Libbox.InterfaceTypeOther
                }
                metered=!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            })
        }
        return Interfaces(values)
    }
    override fun findConnectionOwner(protocol:Int,source:String,sourcePort:Int,dest:String,destPort:Int):ConnectionOwner {
        val owner=if(Build.VERSION.SDK_INT>=29)ConnectionOwner().apply {userId=connectivity.getConnectionOwnerUid(protocol,InetSocketAddress(source,sourcePort),InetSocketAddress(dest,destPort))}
            else Libbox.findConnectionOwner(protocol,source,sourcePort,dest,destPort)
        require(owner.userId>=0){"无法识别连接所属应用"}
        val packages=packageManager.getPackagesForUid(owner.userId)?.toList() ?: emptyList()
        owner.userName=packages.firstOrNull() ?: "";owner.setAndroidPackageNames(Strings(packages));return owner
    }
    override fun localDNSTransport():LocalDNSTransport = object:LocalDNSTransport {
        override fun raw()=false
        override fun exchange(ctx:ExchangeContext,message:ByteArray){throw UnsupportedOperationException("原始 DNS 交换未启用")}
        override fun lookup(ctx:ExchangeContext,kind:String,domain:String){
            val n=network ?: error("当前无可用物理网络")
            try {val result=n.getAllByName(domain).filter{(!kind.endsWith("4") || it is Inet4Address)&&(!kind.endsWith("6") || it is Inet6Address)}
                if(result.isEmpty())ctx.errorCode(3) else ctx.success(result.mapNotNull{it.hostAddress}.joinToString("\n"))
            }catch(_:java.net.UnknownHostException){ctx.errorCode(3)}
        }
    }
    override fun underNetworkExtension()=false
    override fun includeAllNetworks()=false
    override fun readWIFIState():WIFIState?=null
    override fun clearDNSCache(){}
    override fun sendNotification(notification:io.nekohasekai.libbox.Notification){VpnState.log("${notification.title}: ${notification.body}")}
    override fun cancelNotification(identifier:String,typeID:Int){}
    override fun startNeighborMonitor(update:NeighborUpdateListener){throw UnsupportedOperationException("不支持邻居监视")}
    override fun closeNeighborMonitor(update:NeighborUpdateListener){}
    override fun registerMyInterface(name:String){}
    override fun usePlatformShell()=false
    override fun checkPlatformShell(){throw UnsupportedOperationException("未启用系统 shell")}
    override fun openShellSession(user:PlatformUser?,command:String,environ:StringIterator?,term:String,rows:Int,cols:Int):ShellSession {throw UnsupportedOperationException("不支持系统 shell")}
    override fun lookupUser(username:String):PlatformUser {throw UnsupportedOperationException("不支持系统用户查询")}
    override fun lookupSFTPServer():String {throw UnsupportedOperationException("不支持 SFTP")}
    override fun readSystemSSHHostKey():String {throw UnsupportedOperationException("不支持 SSH")}
    override fun tailscaleHostname()="Tokiboshi"
    override fun usePlatformBridge()=false
    override fun createBridge(options:BridgeOptions):BridgeSession {throw UnsupportedOperationException("不支持系统桥接")}
    override fun serviceStop(){requestStop()}
    override fun serviceReload(){throw UnsupportedOperationException("请通过应用重新连接")}
    override fun getSystemProxyStatus()=SystemProxyStatus()
    override fun setSystemProxyEnabled(enabled:Boolean){require(!enabled){"Android 使用 VPN 模式"}}
    override fun triggerNativeCrash(){throw UnsupportedOperationException("未开放主动崩溃")}
    override fun writeDebugMessage(message:String){VpnState.log(message)}
    override fun connectSSHAgent() = -1
}

class Strings(private val values:List<String>):StringIterator {
    private val iterator=values.iterator()
    override fun hasNext()=iterator.hasNext()
    override fun next()=iterator.next()
    override fun len()=values.size
}
class Interfaces(values:List<io.nekohasekai.libbox.NetworkInterface>):NetworkInterfaceIterator {
    private val iterator=values.iterator()
    override fun hasNext()=iterator.hasNext()
    override fun next()=iterator.next()
}
class CoreLogs:CommandClientHandler {
    override fun connected(){}
    override fun disconnected(message:String){if(message.isNotEmpty())VpnState.log(message)}
    override fun setDefaultLogLevel(level:Int){}
    override fun clearLogs(){}
    override fun writeLogs(messages:LogIterator){while(messages.hasNext())VpnState.log(messages.next().message)}
    override fun writeStatus(message:StatusMessage){}
    override fun writeGroups(groups:OutboundGroupIterator){}
    override fun writeOutbounds(items:OutboundGroupItemIterator){}
    override fun initializeClashMode(modes:StringIterator,currentMode:String){}
    override fun updateClashMode(newMode:String){}
    override fun writeConnectionEvents(events:ConnectionEvents){}
}
