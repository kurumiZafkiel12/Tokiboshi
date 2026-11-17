package site.kurumizafkiel.tokiboshi

object VpnState {
    @Volatile var phase="stopped"
    @Volatile var error:String?=null
    private val messages=ArrayDeque<String>()
    @Synchronized fun log(message:String) {
        if(messages.size>=400)messages.removeFirst()
        messages.addLast(message.take(2000))
    }
    @Synchronized fun logs():List<String> = messages.toList()
    fun snapshot():Map<String,Any?> = mapOf("phase" to phase,"running" to (phase=="running"),"error" to error)
}
