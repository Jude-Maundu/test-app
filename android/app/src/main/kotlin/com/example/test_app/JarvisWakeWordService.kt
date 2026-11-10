package com.example.test_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.core.app.NotificationCompat
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.concurrent.Executors

class JarvisWakeWordService : Service(), TextToSpeech.OnInitListener {
    companion object {
        const val ACTION_START = "com.assistant.app.action.START_WAKE_WORD"
        const val ACTION_STOP = "com.assistant.app.action.STOP_WAKE_WORD"
        const val EXTRA_BASE_URL = "ollama_base_url"
        const val EXTRA_MODEL = "ollama_model"
        const val EXTRA_PROVIDER = "llm_provider"
        const val EXTRA_API_KEY = "llm_api_key"
        const val EXTRA_USER_NAME = "user_name"

        private const val CHANNEL_ID = "jarvis_wake_word"
        private const val NOTIFICATION_ID = 4210
        private const val PREFS_NAME = "jarvis_wake_word"
        private const val PREF_BASE_URL = "base_url"
        private const val PREF_MODEL = "model"
        private const val PREF_PROVIDER = "provider"
        private const val PREF_USER_NAME = "user_name"
        private const val PREF_HISTORY = "conversation_history"
        @Volatile
        var isRunning = false
            private set
    }

    private val handler = Handler(Looper.getMainLooper())
    private val networkExecutor = Executors.newSingleThreadExecutor()
    private var speechRecognizer: SpeechRecognizer? = null
    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false
    private var isListening = false
    private var isBusy = false
    private var awaitingCommand = false
    private var baseUrl = ""
    private var model = ""
    private var provider = "ollama"
    private var apiKey = ""
    private var userName = "Jude"
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        textToSpeech = TextToSpeech(this, this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        val preferences = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        baseUrl = intent?.getStringExtra(EXTRA_BASE_URL)
            ?: preferences.getString(PREF_BASE_URL, "")
            ?: ""
        model = intent?.getStringExtra(EXTRA_MODEL)
            ?: preferences.getString(PREF_MODEL, "")
            ?: ""
        provider = intent?.getStringExtra(EXTRA_PROVIDER)
            ?: preferences.getString(PREF_PROVIDER, "ollama")
            ?: "ollama"
        apiKey = intent?.getStringExtra(EXTRA_API_KEY).orEmpty()
        userName = intent?.getStringExtra(EXTRA_USER_NAME)
            ?: preferences.getString(PREF_USER_NAME, "Jude")
            ?: "Jude"
        if (model.isBlank() ||
            (provider == "ollama" && baseUrl.isBlank()) ||
            (provider != "ollama" && apiKey.isBlank())
        ) {
            updateNotification("Provider settings are incomplete; open Jarvis")
            stopSelf()
            return START_NOT_STICKY
        }
        preferences.edit()
            .putString(PREF_BASE_URL, baseUrl)
            .putString(PREF_MODEL, model)
            .putString(PREF_PROVIDER, provider)
            .putString(PREF_USER_NAME, userName)
            .apply()

        isRunning = true
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (wakeLock == null) {
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "Jarvis::WakeWordLock"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        startForeground(NOTIFICATION_ID, createNotification())
        startWakeWordRecognition()
        return START_NOT_STICKY
    }

    override fun onInit(status: Int) {
        if (status != TextToSpeech.SUCCESS) return
        ttsReady = true
        textToSpeech?.language = Locale.US
        textToSpeech?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) = Unit

            override fun onDone(utteranceId: String?) {
                handler.post {
                    isBusy = false
                    startListening()
                }
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                handler.post {
                    isBusy = false
                    startListening()
                }
            }
        })
    }

    private fun startWakeWordRecognition() {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            updateNotification("Speech recognition is unavailable")
            stopSelf()
            return
        }
        if (speechRecognizer == null) {
            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).apply {
                setRecognitionListener(recognitionListener)
            }
        }
        startListening()
    }

    private fun startListening() {
        if (isListening || isBusy || speechRecognizer == null) return
        val recognitionIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.US.toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }
        try {
            isListening = true
            speechRecognizer?.startListening(recognitionIntent)
        } catch (_: Exception) {
            isListening = false
            handler.postDelayed({ startListening() }, 1500)
        }
    }

    private val recognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            updateNotification(if (awaitingCommand) "Listening for command..." else "Listening for 'Jarvis'...")
        }

        override fun onBeginningOfSpeech() = Unit
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() {
            isListening = false
        }

        override fun onError(error: Int) {
            isListening = false
            if (!isBusy) {
                updateNotification("Speech recognition error ($error); retrying")
                handler.postDelayed({ startListening() }, 1500)
            }
        }

        override fun onResults(results: Bundle?) {
            isListening = false
            val transcript = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                .orEmpty()
            handleTranscript(transcript)
        }

        override fun onPartialResults(partialResults: Bundle?) {
            val transcript = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                .orEmpty()
            val command = removeWakePhrase(transcript)
            if (command != null && command.isNotBlank()) {
                speechRecognizer?.cancel()
                isListening = false
                awaitingCommand = false
                processCommand(command)
            }
        }

        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }

    private fun handleTranscript(transcript: String) {
        if (isBusy) return
        if (awaitingCommand) {
            awaitingCommand = false
            if (transcript.isNotBlank()) {
                processCommand(transcript)
            } else {
                startListening()
            }
            return
        }

        val command = removeWakePhrase(transcript)
        if (command == null) {
            startListening()
            return
        }
        if (command.isBlank()) {
            awaitingCommand = true
            speak("At your service, $userName. How may I assist?")
            handler.postDelayed({
                if (awaitingCommand && !isBusy) {
                    awaitingCommand = false
                    startListening()
                }
            }, 12_000)
        } else {
            processCommand(command)
        }
    }

    private fun removeWakePhrase(transcript: String): String? {
        val phrase = Regex("""\b(?:hey|okay|ok)?\s*\bjarvis\b""", RegexOption.IGNORE_CASE)
        val match = phrase.find(transcript) ?: return null
        return (transcript.removeRange(match.range)).trim(' ', ',', '.', '!', '?')
    }

    private fun processCommand(command: String) {
        if (isBusy) return
        isBusy = true
        updateNotification("Processing task: $command")
        try {
            val taskIntent = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                putExtra("EXTRA_COMMAND", command)
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
                )
            }
            startActivity(taskIntent)
            handler.post {
                speak("Executing your request.")
            }
        } catch (error: Exception) {
            Log.e("JarvisWakeWord", "Could not start MainActivity for command, falling back to local query", error)
            networkExecutor.execute {
                try {
                    val result = askModel(command)
                    handler.post {
                        updateNotification("Listening for Hey Jarvis")
                        speak(result)
                    }
                } catch (llmError: Exception) {
                    handler.post {
                        Log.e("JarvisWakeWord", "Could not get an LLM response", llmError)
                        updateNotification("Assistant request failed; check network/provider")
                        speak("I couldn't process your request. Please check your assistant settings.")
                    }
                }
            }
        }
    }

    private fun askModel(command: String): String {
        val systemPrompt =
            "You are Jarvis, a helpful voice assistant. Keep replies short. " +
                "Address the user as $userName naturally from time to time, " +
                "especially in greetings, but do not repeat the name in every reply."
        val endpoint = when (provider) {
            "ollama" -> URL("${baseUrl.trimEnd('/')}/api/chat")
            "openAi" -> URL("https://api.openai.com/v1/chat/completions")
            "groq" -> URL("https://api.groq.com/openai/v1/chat/completions")
            "openRouter" -> URL("https://openrouter.ai/api/v1/chat/completions")
            "gemini" -> URL(
                "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey"
            )
            "anthropic" -> URL("https://api.anthropic.com/v1/messages")
            else -> throw IllegalArgumentException("Unsupported provider: $provider")
        }
        val connection = endpoint.openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.connectTimeout = 10_000
        connection.readTimeout = 120_000
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        when (provider) {
            "openAi", "groq", "openRouter" ->
                connection.setRequestProperty("Authorization", "Bearer $apiKey")
            "anthropic" -> {
                connection.setRequestProperty("x-api-key", apiKey)
                connection.setRequestProperty("anthropic-version", "2023-06-01")
            }
        }
        if (provider == "openAi" || provider == "groq" || provider == "openRouter") {
            connection.setRequestProperty("Authorization", "Bearer $apiKey")
        }
        try {
            val history = loadConversation()
            val body = when (provider) {
                "ollama" -> JSONObject()
                    .put("model", model)
                    .put("stream", false)
                    .put("messages", JSONArray().put(
                        JSONObject()
                            .put("role", "system")
                            .put("content", systemPrompt)
                    ).also { messages ->
                        history.forEach { messages.put(it) }
                        messages.put(JSONObject().put("role", "user").put("content", command))
                    })
                    .toString()
                "openAi", "groq", "openRouter" -> JSONObject()
                    .put("model", model)
                    .put("messages", JSONArray()
                        .put(JSONObject().put("role", "system").put(
                            "content",
                            systemPrompt,
                        ))
                        .also { messages ->
                            history.forEach { messages.put(it) }
                            messages.put(JSONObject().put("role", "user").put("content", command))
                        })
                    .toString()
                "anthropic" -> JSONObject()
                    .put("model", model)
                    .put("max_tokens", 500)
                    .put("system", systemPrompt)
                    .put("messages", JSONArray().also { messages ->
                        history.forEach { messages.put(it) }
                        messages.put(JSONObject().put("role", "user").put("content", command))
                    })
                    .toString()
                "gemini" -> JSONObject()
                    .put("systemInstruction", JSONObject().put(
                        "parts",
                        JSONArray().put(JSONObject().put(
                            "text",
                            systemPrompt,
                        )),
                    ))
                    .put("contents", JSONArray().also { contents ->
                        history.forEach { item ->
                            contents.put(
                                JSONObject()
                                    .put("role", if (item.optString("role") == "assistant") "model" else "user")
                                    .put("parts", JSONArray().put(JSONObject().put("text", item.optString("content")))),
                            )
                        }
                        contents.put(
                            JSONObject().put("role", "user").put(
                                "parts",
                                JSONArray().put(JSONObject().put("text", command)),
                            ),
                        )
                    })
                    .toString()
                else -> throw IllegalArgumentException("Unsupported provider: $provider")
            }
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val responseStream = if (status in 200..299) {
                connection.inputStream
            } else {
                connection.errorStream
            }
            val responseBody = responseStream.bufferedReader().use { it.readText() }
            if (status !in 200..299) {
                throw IllegalStateException("$provider returned HTTP $status")
            }
            val result = JSONObject(responseBody)
            val text = when (provider) {
                "ollama" -> result.optJSONObject("message")?.optString("content")
                "openAi", "groq", "openRouter" -> result
                    .optJSONArray("choices")?.optJSONObject(0)
                    ?.optJSONObject("message")?.optString("content")
                "anthropic" -> result.optJSONArray("content")
                    ?.optJSONObject(0)?.optString("text")
                "gemini" -> result.optJSONArray("candidates")
                    ?.optJSONObject(0)?.optJSONObject("content")
                    ?.optJSONArray("parts")?.optJSONObject(0)?.optString("text")
                else -> null
            }
            val reply = text?.takeIf { it.isNotBlank() } ?: "I didn't get a response."
            saveConversation(command, reply)
            return reply
        } finally {
            connection.disconnect()
        }
    }

    private fun loadConversation(): List<JSONObject> {
        val raw = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .getString(PREF_HISTORY, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { array.optJSONObject(it) }
        } catch (error: Exception) {
            Log.e("JarvisWakeWord", "Could not read conversation history", error)
            emptyList()
        }
    }

    private fun saveConversation(command: String, response: String) {
        val turns = loadConversation().toMutableList()
        turns.add(JSONObject().put("role", "user").put("content", command))
        turns.add(JSONObject().put("role", "assistant").put("content", response))
        val history = JSONArray()
        turns.takeLast(10).forEach { history.put(it) }
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
            .putString(PREF_HISTORY, history.toString())
            .apply()
    }

    private fun speak(text: String) {
        isBusy = false
        if (ttsReady) {
            isBusy = true
            textToSpeech?.speak(
                text,
                TextToSpeech.QUEUE_FLUSH,
                null,
                "jarvis-response"
            )
        } else {
            startListening()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Jarvis wake word",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Visible while Jarvis listens for its wake phrase."
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun updateNotification(message: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, createNotification(message))
    }

    private fun createNotification(message: String = "Listening for Hey Jarvis"): Notification {
        val stopIntent = Intent(this, JarvisWakeWordService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Jarvis is active")
            .setContentText(message)
            .setOngoing(true)
            .addAction(
                android.R.drawable.ic_media_pause,
                "Stop listening",
                stopPendingIntent
            )
            .build()
    }

    override fun onDestroy() {
        isRunning = false
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
        handler.removeCallbacksAndMessages(null)
        speechRecognizer?.destroy()
        speechRecognizer = null
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        networkExecutor.shutdownNow()
        getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
