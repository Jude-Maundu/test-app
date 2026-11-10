package com.example.test_app

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ComponentName
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.BatteryManager
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.MediaStore
import android.provider.Settings
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.SearchManager
import android.app.role.RoleManager
import android.telephony.SmsManager
import android.view.KeyEvent
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val platformChannel = "com.assistant.app/platform"
    private val wakeWordChannel = "com.assistant.app/wakeword"
    private var pendingCommand: String? = null
    private var flutterChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val command = intent?.getStringExtra("EXTRA_COMMAND")
        if (!command.isNullOrBlank()) {
            pendingCommand = command
            flutterChannel?.invokeMethod("onBackgroundCommand", command)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, platformChannel)
        flutterChannel = channel
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPendingCommand" -> {
                        val cmd = pendingCommand
                        pendingCommand = null
                        result.success(cmd)
                    }
                    "launchApp" -> {
                        val packageName = call.argument<String>("packageName")
                        if (packageName.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Package name is required", null)
                        } else {
                            launchApp(packageName, result)
                        }
                    }
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "URL is required", null)
                        } else {
                            openUrl(url, result)
                        }
                    }
                    "sendWhatsApp" -> {
                        val phoneNumber = call.argument<String>("phoneNumber")
                        val message = call.argument<String>("message") ?: ""
                        sendWhatsApp(phoneNumber, message, result)
                    }
                    "isAppInstalled" -> {
                        val packageName = call.argument<String>("packageName")
                        if (packageName.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Package name is required", null)
                        } else {
                            result.success(isAppInstalled(packageName))
                        }
                    }
                    "setAlarm" -> {
                        val time = call.argument<String>("time")
                        if (time.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Time is required", null)
                        } else {
                            setAlarm(time, call.argument("label"), result)
                        }
                    }
                    "makeCall" -> {
                        val phoneNumber = call.argument<String>("phoneNumber")
                        if (phoneNumber.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Phone number is required", null)
                        } else {
                            makeCall(phoneNumber, result)
                        }
                    }
                    "sendSms" -> {
                        val phoneNumber = call.argument<String>("phoneNumber")
                        val message = call.argument<String>("message")
                        if (phoneNumber.isNullOrBlank() || message == null) {
                            result.error("INVALID_ARGUMENT", "Phone number and message are required", null)
                        } else {
                            sendSms(phoneNumber, message, result)
                        }
                    }
                    "findContacts" -> {
                        val name = call.argument<String>("name")
                        if (name.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Contact name is required", null)
                        } else {
                            try {
                                result.success(findContacts(name))
                            } catch (error: SecurityException) {
                                result.error("PERMISSION_DENIED", "Contacts permission is required", null)
                            } catch (error: Exception) {
                                result.error("CONTACT_LOOKUP_FAILED", error.message, null)
                            }
                        }
                    }
                    "findContactEmails" -> {
                        val name = call.argument<String>("name")
                        if (name.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Contact name is required", null)
                        } else {
                            try {
                                result.success(findContactEmails(name))
                            } catch (error: SecurityException) {
                                result.error("PERMISSION_DENIED", "Contacts permission is required", null)
                            } catch (error: Exception) {
                                result.error("CONTACT_LOOKUP_FAILED", error.message, null)
                            }
                        }
                    }
                    "deviceAction" -> {
                        val action = call.argument<String>("action")
                        if (action.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Action is required", null)
                        } else {
                            try {
                                result.success(
                                    performDeviceAction(
                                        action,
                                        call.argument("arguments"),
                                    ),
                                )
                            } catch (error: Exception) {
                                result.error("DEVICE_ACTION_FAILED", error.message, null)
                            }
                        }
                    }
                    "readNotifications" -> result.success(
                        "Notification reading requires notification access to be enabled in Android Settings.",
                    )
                    "requestAssistantRole" -> requestAssistantRole(result)
                    "requestNotificationAccess" -> requestNotificationAccess(result)
                    "mediaControl" -> {
                        val action = call.argument<String>("action")
                        if (action.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Media action is required", null)
                        } else {
                            mediaControl(action, result)
                        }
                    }
                    "playMediaFromSearch" -> {
                        val query = call.argument<String>("query")
                        val isYouTube = call.argument<Boolean>("isYouTube") ?: false
                        val artist = call.argument<String>("artist")
                        val title = call.argument<String>("title")
                        if (query.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Query is required", null)
                        } else {
                            playMediaFromSearch(query, isYouTube, artist, title, result)
                        }
                    }
                    "sendEmail" -> {
                        val to = call.argument<String>("to") ?: ""
                        val subject = call.argument<String>("subject") ?: "Message from Jarvis"
                        val body = call.argument<String>("body") ?: ""
                        sendEmail(to, subject, body, result)
                    }
                    "openGmail" -> {
                        val query = call.argument<String>("query")
                        openGmail(query, result)
                    }
                    "showNotification" -> {
                        val title = call.argument<String>("title") ?: "Jarvis"
                        val message = call.argument<String>("message") ?: ""
                        showNotification(title, message, result)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wakeWordChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> startWakeWordService(call, result)
                    "stop" -> {
                        stopService(Intent(this, JarvisWakeWordService::class.java))
                        result.success(null)
                    }
                    "isRunning" -> result.success(JarvisWakeWordService.isRunning)
                    else -> result.notImplemented()
                }
            }
    }

    private fun startWakeWordService(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val baseUrl = call.argument<String>("baseUrl")
        val model = call.argument<String>("model")
        val provider = call.argument<String>("provider")
        val apiKey = call.argument<String>("apiKey")
        val userName = call.argument<String>("userName")?.trim().orEmpty()
        if (model.isNullOrBlank() ||
            provider.isNullOrBlank() ||
            (provider == "ollama" && baseUrl.isNullOrBlank()) ||
            (provider != "ollama" && apiKey.isNullOrBlank())
        ) {
            result.error("INVALID_ARGUMENT", "Provider, model, and required credentials are needed.", null)
            return
        }

        val serviceIntent = Intent(this, JarvisWakeWordService::class.java).apply {
            action = JarvisWakeWordService.ACTION_START
            putExtra(JarvisWakeWordService.EXTRA_BASE_URL, baseUrl)
            putExtra(JarvisWakeWordService.EXTRA_MODEL, model)
            putExtra(JarvisWakeWordService.EXTRA_PROVIDER, provider)
            putExtra(JarvisWakeWordService.EXTRA_API_KEY, apiKey)
            putExtra(JarvisWakeWordService.EXTRA_USER_NAME, userName.ifEmpty { "Jude" })
        }
        try {
            startForegroundService(serviceIntent)
            result.success(null)
        } catch (error: Exception) {
            result.error("START_FAILED", error.message, null)
        }
    }

    private fun findContacts(query: String): List<Map<String, String>> {
        val matches = mutableListOf<Map<String, String>>()
        val cursor = contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            ),
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?",
            arrayOf("%$query%"),
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} COLLATE NOCASE ASC",
        )
        cursor?.use {
            val nameIndex = it.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            )
            val numberIndex = it.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            )
            while (it.moveToNext() && matches.size < 10) {
                matches.add(
                    mapOf(
                        "name" to it.getString(nameIndex),
                        "phoneNumber" to it.getString(numberIndex),
                    ),
                )
            }
        }
        return matches
    }

    private fun findContactEmails(query: String): List<Map<String, String>> {
        val matches = mutableListOf<Map<String, String>>()
        val cursor = contentResolver.query(
            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Email.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Email.ADDRESS,
            ),
            "${ContactsContract.CommonDataKinds.Email.DISPLAY_NAME} LIKE ?",
            arrayOf("%$query%"),
            "${ContactsContract.CommonDataKinds.Email.DISPLAY_NAME} COLLATE NOCASE ASC",
        )
        cursor?.use {
            val nameIndex = it.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Email.DISPLAY_NAME,
            )
            val addressIndex = it.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Email.ADDRESS,
            )
            while (it.moveToNext() && matches.size < 10) {
                matches.add(
                    mapOf(
                        "name" to it.getString(nameIndex),
                        "email" to it.getString(addressIndex),
                    ),
                )
            }
        }
        return matches
    }

    private fun performDeviceAction(
        action: String,
        arguments: Map<String, Any>?,
    ): String {
        when (action) {
            "setTimer" -> {
                val seconds = (arguments?.get("seconds") as? Number)?.toInt()
                    ?: throw IllegalArgumentException("Timer duration is required")
                require(seconds > 0) { "Timer duration must be positive" }
                startActivity(
                    Intent(AlarmClock.ACTION_SET_TIMER)
                        .putExtra(AlarmClock.EXTRA_LENGTH, seconds)
                        .putExtra(
                            AlarmClock.EXTRA_MESSAGE,
                            arguments?.get("label") as? String ?: "Jarvis timer",
                        )
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                return "Opened timer for $seconds seconds."
            }
            "navigate" -> {
                val destination = arguments?.get("destination") as? String
                require(!destination.isNullOrBlank()) { "Destination is required" }
                startActivity(
                    Intent(
                        Intent.ACTION_VIEW,
                        Uri.parse("google.navigation:q=${Uri.encode(destination)}"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                return "Opening navigation."
            }
            "webSearch" -> {
                val query = arguments?.get("query") as? String ?: ""
                startActivity(
                    Intent(Intent.ACTION_WEB_SEARCH)
                        .putExtra("query", query)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                return "Searching the web."
            }
            "weather" -> {
                val location = arguments?.get("location") as? String ?: ""
                val uri = Uri.parse(
                    "https://www.google.com/search?q=${Uri.encode("weather $location")}",
                )
                startActivity(
                    Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                return "Opening the weather search."
            }
            "calendarEvent" -> {
                val title = arguments?.get("title") as? String
                    ?: throw IllegalArgumentException("Event title is required")
                val startTime = arguments?.get("start_time") as? String
                    ?: throw IllegalArgumentException("Event time is required")
                val startMillis = java.time.OffsetDateTime.parse(startTime)
                    .toInstant().toEpochMilli()
                val duration = (arguments?.get("duration_minutes") as? Number)
                    ?.toLong() ?: 60L
                startActivity(
                    Intent(
                        Intent.ACTION_INSERT,
                        CalendarContract.Events.CONTENT_URI,
                    )
                        .putExtra(CalendarContract.Events.TITLE, title)
                        .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, startMillis)
                        .putExtra(
                            CalendarContract.EXTRA_EVENT_END_TIME,
                            startMillis + duration * 60_000,
                        )
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                return "Opened the calendar form. Review and save the event there."
            }
            "volume_up", "volume_down", "mute" -> {
                val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val adjustment = when (action) {
                    "volume_up" -> AudioManager.ADJUST_RAISE
                    "volume_down" -> AudioManager.ADJUST_LOWER
                    else -> AudioManager.ADJUST_MUTE
                }
                audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, adjustment, 0)
                return "Updated media volume."
            }
            "flashlight_on", "flashlight_off" -> {
                val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
                val cameraId = manager.cameraIdList.firstOrNull()
                    ?: throw IllegalStateException("No camera flash is available")
                manager.setTorchMode(cameraId, action == "flashlight_on")
                return if (action == "flashlight_on") "Flashlight on." else "Flashlight off."
            }
            "battery_level" -> {
                val battery = registerReceiver(
                    null,
                    IntentFilter(Intent.ACTION_BATTERY_CHANGED),
                ) ?: throw IllegalStateException("Battery information is unavailable")
                val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                require(level >= 0 && scale > 0) { "Battery level is unavailable" }
                return "Battery is ${level * 100 / scale}%."
            }
            "wifi_settings" -> startActivity(
                Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            "bluetooth_settings" -> startActivity(
                Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            "do_not_disturb_settings" -> startActivity(
                Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            "brightness_settings" -> startActivity(
                Intent(Settings.ACTION_DISPLAY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            else -> throw IllegalArgumentException("Unsupported phone action: $action")
        }
        return "Opened the related phone settings."
    }

    private fun requestAssistantRole(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "UNSUPPORTED",
                "Android default assistant selection requires Android 10 or newer.",
                null,
            )
            return
        }
        val roleManager = getSystemService(RoleManager::class.java)
        if (!roleManager.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) {
            result.error("UNAVAILABLE", "This device does not expose the assistant role.", null)
            return
        }
        if (roleManager.isRoleHeld(RoleManager.ROLE_ASSISTANT)) {
            result.success("Jarvis is already the default assistant.")
            return
        }
        try {
            startActivity(roleManager.createRequestRoleIntent(RoleManager.ROLE_ASSISTANT))
            result.success("Choose Jarvis in the Android confirmation screen.")
        } catch (error: Exception) {
            result.error("ROLE_REQUEST_FAILED", error.message, null)
        }
    }

    private fun requestNotificationAccess(result: MethodChannel.Result) {
        try {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            result.success("Enable Jarvis media controls in Notification access.")
        } catch (error: Exception) {
            result.error("SETTINGS_UNAVAILABLE", error.message, null)
        }
    }

    private fun mediaControl(action: String, result: MethodChannel.Result) {
        val normalizedAction = action.lowercase().trim()
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Volume adjustments
        if (normalizedAction == "volume_up") {
            audioManager.adjustStreamVolume(
                AudioManager.STREAM_MUSIC,
                AudioManager.ADJUST_RAISE,
                AudioManager.FLAG_SHOW_UI,
            )
            result.success("Increased volume, sir.")
            return
        }
        if (normalizedAction == "volume_down") {
            audioManager.adjustStreamVolume(
                AudioManager.STREAM_MUSIC,
                AudioManager.ADJUST_LOWER,
                AudioManager.FLAG_SHOW_UI,
            )
            result.success("Decreased volume, sir.")
            return
        }

        // Try active MediaSessionManager first (if notification access is enabled)
        try {
            val manager = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            val component = ComponentName(this, JarvisNotificationListenerService::class.java)
            val sessions = manager.getActiveSessions(component)
            if (sessions.isNotEmpty()) {
                val controller = when (normalizedAction) {
                    "pause" -> sessions.firstOrNull {
                        it.playbackState?.state == PlaybackState.STATE_PLAYING
                    } ?: sessions.first()
                    "play", "resume" -> sessions.firstOrNull {
                        it.playbackState?.state != PlaybackState.STATE_PLAYING
                    } ?: sessions.first()
                    "next", "previous" -> sessions.first()
                    else -> sessions.first()
                }
                when (normalizedAction) {
                    "play", "resume" -> controller.transportControls.play()
                    "pause" -> controller.transportControls.pause()
                    "next" -> controller.transportControls.skipToNext()
                    "previous" -> controller.transportControls.skipToPrevious()
                    else -> throw IllegalArgumentException("Unsupported media action: $action")
                }
                result.success("Sent $action to ${controller.packageName}, sir.")
                return
            }
        } catch (_: Exception) {
            // Fall back to media key dispatching below
        }

        // Universal fallback: Dispatch media key event directly via AudioManager
        try {
            val keyCode = when (normalizedAction) {
                "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
                "play", "resume" -> KeyEvent.KEYCODE_MEDIA_PLAY
                "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
                "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
                else -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            }
            audioManager.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            audioManager.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
            result.success("Sent $action command, sir.")
        } catch (error: Exception) {
            result.error("MEDIA_CONTROL_FAILED", error.message, null)
        }
    }

    private fun playMediaFromSearch(
        query: String,
        isYouTube: Boolean,
        artist: String?,
        title: String?,
        result: MethodChannel.Result
    ) {
        if (isYouTube) {
            try {
                val ytIntent = Intent(Intent.ACTION_SEARCH).apply {
                    setPackage("com.google.android.youtube")
                    putExtra("query", query)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                if (ytIntent.resolveActivity(packageManager) != null) {
                    startActivity(ytIntent)
                    result.success("Playing \"$query\" on YouTube, sir.")
                } else {
                    val webUri = Uri.parse("https://www.youtube.com/results?search_query=${Uri.encode(query)}")
                    startActivity(Intent(Intent.ACTION_VIEW, webUri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success("Opening \"$query\" on YouTube, sir.")
                }
            } catch (e: Exception) {
                result.error("YOUTUBE_PLAY_FAILED", "Could not open YouTube: ${e.message}", null)
            }
            return
        }

        // Standard music playback: Android MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH
        try {
            val intent = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH).apply {
                putExtra(SearchManager.QUERY, query)
                if (!artist.isNullOrBlank()) {
                    putExtra(MediaStore.EXTRA_MEDIA_ARTIST, artist)
                }
                if (!title.isNullOrBlank()) {
                    putExtra(MediaStore.EXTRA_MEDIA_TITLE, title)
                }
                putExtra(MediaStore.EXTRA_MEDIA_FOCUS, "vnd.android.cursor.item/*")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            val resolveInfo = intent.resolveActivity(packageManager)
            if (resolveInfo != null) {
                startActivity(intent)
                result.success("Playing \"$query\" on your default music player, sir.")
                return
            }

            // Check well-known installed music players if no generic handler was registered
            val musicPackages = listOf(
                "com.spotify.music",
                "com.google.android.apps.youtube.music",
                "com.sec.android.app.music",
                "com.amazon.mp3",
                "com.apple.android.music",
                "deezer.android.app",
                "com.maxmpz.audioplayer"
            )
            for (pkg in musicPackages) {
                if (isAppInstalled(pkg)) {
                    val pkgIntent = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH).apply {
                        setPackage(pkg)
                        putExtra(SearchManager.QUERY, query)
                        if (!artist.isNullOrBlank()) {
                            putExtra(MediaStore.EXTRA_MEDIA_ARTIST, artist)
                        }
                        if (!title.isNullOrBlank()) {
                            putExtra(MediaStore.EXTRA_MEDIA_TITLE, title)
                        }
                        putExtra(MediaStore.EXTRA_MEDIA_FOCUS, "vnd.android.cursor.item/*")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(pkgIntent)
                    result.success("Playing \"$query\" on installed music player, sir.")
                    return
                }
            }

            // No music app found to handle the intent
            result.error(
                "NO_MUSIC_APP",
                "No music player application was found on this device to handle the request.",
                null
            )
        } catch (e: Exception) {
            result.error("MEDIA_PLAY_FAILED", "Failed to start media playback: ${e.message}", null)
        }
    }

    private fun launchApp(packageName: String, result: MethodChannel.Result) {
        try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                startActivity(intent)
                result.success("Launched $packageName")
            } else {
                result.error("NOT_FOUND", "App not found", null)
            }
        } catch (error: Exception) {
            result.error("ERROR", error.message, null)
        }
    }

    private fun setAlarm(time: String, label: String?, result: MethodChannel.Result) {
        try {
            val parts = time.split(":")
            require(parts.size == 2) { "Time must use HH:mm format" }
            val hour = parts[0].toInt()
            val minute = parts[1].toInt()
            require(hour in 0..23 && minute in 0..59) { "Time is out of range" }
            val intent = Intent(AlarmClock.ACTION_SET_ALARM)
                .putExtra(AlarmClock.EXTRA_MESSAGE, label)
                .putExtra(AlarmClock.EXTRA_HOUR, hour)
                .putExtra(AlarmClock.EXTRA_MINUTES, minute)
            startActivity(intent)
            result.success("Alarm set for $time")
        } catch (error: Exception) {
            result.error("ERROR", error.message, null)
        }
    }

    private fun makeCall(phoneNumber: String, result: MethodChannel.Result) {
        if (checkSelfPermission(android.Manifest.permission.CALL_PHONE) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            result.error("PERMISSION_DENIED", "CALL_PHONE permission is required to place calls directly.", null)
            return
        }
        try {
            startActivity(
                Intent(Intent.ACTION_CALL, Uri.parse("tel:$phoneNumber"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            result.success("Calling $phoneNumber, sir.")
        } catch (error: Exception) {
            result.error("ERROR", error.message, null)
        }
    }

    private fun sendSms(phoneNumber: String, message: String, result: MethodChannel.Result) {
        try {
            SmsManager.getDefault().sendTextMessage(phoneNumber, null, message, null, null)
            result.success("SMS sent to $phoneNumber")
        } catch (error: Exception) {
            result.error("ERROR", error.message, null)
        }
    }

    private fun isAppInstalled(packageName: String): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(packageName, android.content.pm.PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun openUrl(url: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(url)
            val intent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            result.success("Opened URL: $url")
        } catch (error: Exception) {
            result.error("ERROR", error.message, null)
        }
    }

    private fun sendWhatsApp(phoneNumber: String?, message: String, result: MethodChannel.Result) {
        try {
            val isWhatsappInstalled = isAppInstalled("com.whatsapp") || isAppInstalled("com.whatsapp.w4b")
            if (!isWhatsappInstalled) {
                result.error("NOT_INSTALLED", "WhatsApp is not installed on this device.", null)
                return
            }

            val cleanPhone = phoneNumber?.replace(Regex("[^0-9+]"), "") ?: ""
            val uri = if (cleanPhone.isNotEmpty()) {
                val digitsOnly = cleanPhone.replace("+", "")
                Uri.parse("https://api.whatsapp.com/send?phone=$digitsOnly&text=${Uri.encode(message)}")
            } else {
                Uri.parse("https://api.whatsapp.com/send?text=${Uri.encode(message)}")
            }

            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                setPackage("com.whatsapp")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            try {
                startActivity(intent)
            } catch (_: Exception) {
                val genericIntent = Intent(Intent.ACTION_VIEW, uri).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(genericIntent)
            }
            result.success("WhatsApp opened with prepared message")
        } catch (error: Exception) {
            result.error("ERROR", error.message, null)
        }
    }

    private fun sendEmail(to: String, subject: String, body: String, result: MethodChannel.Result) {
        try {
            val mailtoUri = Uri.parse("mailto:$to")
            val intent = Intent(Intent.ACTION_SENDTO, mailtoUri).apply {
                putExtra(Intent.EXTRA_SUBJECT, subject)
                putExtra(Intent.EXTRA_TEXT, body)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (isAppInstalled("com.google.android.gm")) {
                intent.setPackage("com.google.android.gm")
            }
            startActivity(intent)
            result.success("Email drafted to $to")
        } catch (error: Exception) {
            try {
                val fallbackIntent = Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:$to")).apply {
                    putExtra(Intent.EXTRA_SUBJECT, subject)
                    putExtra(Intent.EXTRA_TEXT, body)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(fallbackIntent)
                result.success("Email drafted to $to")
            } catch (e: Exception) {
                result.error("ERROR", e.message, null)
            }
        }
    }

    private fun openGmail(query: String?, result: MethodChannel.Result) {
        try {
            if (isAppInstalled("com.google.android.gm")) {
                val launchIntent = packageManager.getLaunchIntentForPackage("com.google.android.gm")
                if (launchIntent != null) {
                    if (!query.isNullOrBlank()) {
                        launchIntent.action = Intent.ACTION_SEARCH
                        launchIntent.putExtra("query", query)
                    }
                    startActivity(launchIntent)
                    result.success("Opened Gmail")
                    return
                }
            }
            val webUrl = if (!query.isNullOrBlank()) {
                "https://mail.google.com/mail/u/0/#search/${Uri.encode(query)}"
            } else {
                "https://mail.google.com"
            }
            openUrl(webUrl, result)
        } catch (error: Exception) {
            result.error("ERROR", error.message, null)
        }
    }

    private fun showNotification(title: String, message: String, result: MethodChannel.Result) {
        try {
            val channelId = "jarvis_tasks_channel"
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    channelId,
                    "Jarvis Tasks & Updates",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notifications for Jarvis automated tasks and status"
                }
                notificationManager.createNotificationChannel(channel)
            }

            val notification = NotificationCompat.Builder(this, channelId)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(message)
                .setStyle(NotificationCompat.BigTextStyle().bigText(message))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .build()

            val notificationId = (System.currentTimeMillis() % 100000).toInt()
            notificationManager.notify(notificationId, notification)
            result.success("Notification posted")
        } catch (error: Exception) {
            result.error("ERROR", error.message, null)
        }
    }
}
