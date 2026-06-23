package com.example.shesafe

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val SMS_CHANNEL = "com.shesafe.app/sms"
        private const val TAG = "SheSafe_SMS"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendSms" -> {
                        val phone   = call.argument<String>("phone")   ?: ""
                        val message = call.argument<String>("message") ?: ""
                        if (phone.isEmpty() || message.isEmpty()) {
                            result.error("INVALID_ARGS", "phone and message are required", null)
                            return@setMethodCallHandler
                        }
                        sendSms(phone, message, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun sendSms(phone: String, message: String, result: MethodChannel.Result) {
        val permGranted = checkSelfPermission(Manifest.permission.SEND_SMS) ==
                PackageManager.PERMISSION_GRANTED
        Log.d(TAG, "SEND_SMS permission granted: $permGranted")
        try {
            val smsManager = buildSmsManager()
            if (smsManager == null) {
                result.error("SMS_FAILED", "SmsManager unavailable", null)
                return
            }
            val parts = smsManager.divideMessage(message)
            if (parts.size == 1) {
                smsManager.sendTextMessage(phone, null, message, null, null)
            } else {
                smsManager.sendMultipartTextMessage(phone, null, parts, null, null)
            }
            Log.d(TAG, "sendTextMessage returned without exception -> $phone")
            result.success(true)
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException sending SMS: ${e.message}")
            result.error("NO_PERMISSION", "SEND_SMS permission denied: ${e.message}", null)
        } catch (e: Exception) {
            Log.e(TAG, "Exception sending SMS: ${e.javaClass.simpleName}: ${e.message}")
            result.error("SMS_FAILED", "${e.javaClass.simpleName}: ${e.message}", null)
        }
    }

    private fun buildSmsManager(): SmsManager? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val sm    = getSystemService(SmsManager::class.java) ?: return null
                val subId = SubscriptionManager.getDefaultSmsSubscriptionId()
                if (subId != SubscriptionManager.INVALID_SUBSCRIPTION_ID)
                    sm.createForSubscriptionId(subId)
                else
                    sm
            } else {
                @Suppress("DEPRECATION")
                val subId = SubscriptionManager.getDefaultSmsSubscriptionId()
                @Suppress("DEPRECATION")
                if (subId != SubscriptionManager.INVALID_SUBSCRIPTION_ID)
                    SmsManager.getSmsManagerForSubscriptionId(subId)
                else
                    SmsManager.getDefault()
            }
        } catch (e: Exception) {
            Log.e(TAG, "buildSmsManager failed: ${e.message}")
            @Suppress("DEPRECATION")
            try { SmsManager.getDefault() } catch (_: Exception) { null }
        }
    }
}
