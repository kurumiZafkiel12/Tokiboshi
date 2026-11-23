package site.kurumizafkiel.tokiboshi

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class VpnQuickTile : TileService() {
    private val handler = Handler(Looper.getMainLooper())
    private val refresh = object : Runnable {
        override fun run() {
            val tile = qsTile ?: return
            val state = when (VpnState.phase) {
                "running" -> Tile.STATE_ACTIVE
                "starting", "stopping" -> Tile.STATE_UNAVAILABLE
                else -> Tile.STATE_INACTIVE
            }
            if (tile.state != state) {
                tile.state = state
                tile.updateTile()
            }
            handler.postDelayed(this, 500)
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        handler.removeCallbacks(refresh)
        refresh.run()
    }

    override fun onStopListening() {
        handler.removeCallbacks(refresh)
        super.onStopListening()
    }

    override fun onDestroy() {
        handler.removeCallbacks(refresh)
        super.onDestroy()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { toggle() } else toggle()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun toggle() {
        when (VpnState.phase) {
            "running" -> TokiboshiVpnService.instance?.requestStop()
            "starting", "stopping" -> return
            else -> {
                val entry = Intent(this, MainActivity::class.java)
                    .setAction(MainActivity.ACTION_CONNECT)
                    .putExtra(MainActivity.EXTRA_CONNECT_TOKEN, MainActivity.connectToken)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                if (Build.VERSION.SDK_INT >= 34) {
                    startActivityAndCollapse(PendingIntent.getActivity(
                        this, 2, entry, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                    ))
                } else {
                    @Suppress("DEPRECATION")
                    startActivityAndCollapse(entry)
                }
            }
        }
    }
}
