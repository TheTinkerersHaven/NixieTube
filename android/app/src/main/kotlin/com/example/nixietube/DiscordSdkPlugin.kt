package com.example.nixietube

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import com.discord.socialsdk.rpc.IDiscordRpcCallback
import com.discord.socialsdk.rpc.IDiscordRpcConnection
import com.discord.socialsdk.rpc.IDiscordRpcService
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge to the Discord Social SDK (discord_partner_sdk.aar).
 *
 * Rich Presence on Android needs no OAuth and no native SDK load: the
 * installed Discord app hosts an AIDL service
 * (`com.discord.socialsdk.rpc.IDiscordRpcService`) that speaks the same
 * JSON RPC protocol as the desktop client. This plugin binds to it and
 * forwards frames between Dart and the Discord app.
 *
 * Channel "nixietube/discord_sdk" methods:
 *   isInstalled()            -> bool
 *   connect(appId: String)   -> bool (binds + connects; events follow)
 *   sendFrame(json: String)  -> void
 *   disconnect()             -> void
 * Events on "nixietube/discord_sdk/events" (List<dynamic> [kind, ...payload]):
 *   ["connected"], ["frame", json], ["closed", code, reason]
 */
class DiscordSdkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var events: MethodChannel? = null
    private var context: Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var service: IDiscordRpcService? = null
    private var connection: IDiscordRpcConnection? = null
    private var bound = false
    private var boundPackage: String? = null

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            service = IDiscordRpcService.Stub.asInterface(binder)
            mainHandler.post { connectPending() }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            service = null
            connection = null
            sendEvent(listOf("closed", -1, "service disconnected"))
        }
    }

    private val rpcCallback = object : IDiscordRpcCallback.Stub() {
        override fun onFrame(frame: String) {
            sendEvent(listOf("frame", frame))
        }

        override fun onClose(code: Int, message: String?) {
            sendEvent(listOf("closed", code, message ?: ""))
        }
    }

    private var pendingAppId: Long = 0L
    private var connectResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "nixietube/discord_sdk")
        channel?.setMethodCallHandler(this)
        events = MethodChannel(binding.binaryMessenger, "nixietube/discord_sdk/events")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        disconnectInternal()
        channel?.setMethodCallHandler(null)
        channel = null
        events = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isInstalled" -> result.success(isDiscordInstalled())
            "connect" -> {
                val appId = (call.argument<String>("appId"))?.toLongOrNull()
                if (appId == null) {
                    result.error("bad_app_id", "appId must be numeric", null)
                    return
                }
                connect(appId, result)
            }
            "sendFrame" -> {
                val frame = call.argument<String>("json")
                if (frame == null) {
                    result.error("bad_frame", "json required", null)
                    return
                }
                try {
                    connection?.sendFrame(frame)
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            "disconnect" -> {
                disconnectInternal()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun isDiscordInstalled(): Boolean {
        val ctx = context ?: return false
        for (pkg in DISCORD_PACKAGES) {
            val intent = Intent(RPC_ACTION).setPackage(pkg)
            if (runCatching { ctx.packageManager.resolveService(intent, 0) }.getOrNull() != null) {
                return true
            }
        }
        return false
    }

    private fun connect(appId: Long, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.success(false)
            return
        }
        // Already connected with this id: fine.
        if (connection != null) {
            result.success(true)
            return
        }
        if (connectResult != null) {
            // A connect is in flight; queue this result after it.
            result.success(false)
            return
        }
        val pkg = DISCORD_PACKAGES.firstNotNullOfOrNull { p ->
            val intent = Intent(RPC_ACTION).setPackage(p)
            if (runCatching { ctx.packageManager.resolveService(intent, 0) }.getOrNull() != null) p else null
        }
        if (pkg == null) {
            result.success(false)
            return
        }
        pendingAppId = appId
        connectResult = result
        boundPackage = pkg
        val intent = Intent(RPC_ACTION).setPackage(pkg)
        bound = runCatching {
            ctx.bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
        }.getOrDefault(false)
        if (!bound) {
            connectResult = null
            result.success(false)
        }
    }

    private fun connectPending() {
        val svc = service
        val result = connectResult
        val ctx = context
        if (svc == null || result == null || ctx == null) return
        try {
            connection = svc.connect(pendingAppId, ctx.packageName, rpcCallback)
            connectResult = null
            sendEvent(listOf("connected"))
            result.success(true)
        } catch (e: Exception) {
            Log.w(TAG, "rpc connect failed", e)
            connectResult = null
            result.success(false)
        }
    }

    private fun disconnectInternal() {
        try {
            connection?.disconnect()
        } catch (_: Exception) {
        }
        connection = null
        val ctx = context
        if (bound && ctx != null) {
            runCatching { ctx.unbindService(serviceConnection) }
        }
        bound = false
        service = null
        connectResult = null
    }

    private fun sendEvent(event: List<Any?>) {
        mainHandler.post { events?.invokeMethod("event", event) }
    }

    companion object {
        private const val TAG = "DiscordSdkPlugin"
        private const val RPC_ACTION = "com.discord.socialsdk.rpc.IDiscordRpcService"
        private val DISCORD_PACKAGES = listOf(
            "com.discord",
            "com.discord.canary",
            "com.discord.ptb",
            "com.discord.debug",
        )
    }
}
