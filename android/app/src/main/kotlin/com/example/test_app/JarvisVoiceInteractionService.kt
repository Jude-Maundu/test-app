package com.example.test_app

import android.os.Bundle
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService

class JarvisVoiceInteractionService : VoiceInteractionService()

class JarvisVoiceInteractionSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession =
        JarvisVoiceInteractionSession(this)
}

private class JarvisVoiceInteractionSession(
    private val appContext: android.content.Context,
) : VoiceInteractionSession(appContext) {
    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        appContext.startActivity(
            android.content.Intent(appContext, MainActivity::class.java).apply {
                addFlags(
                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                        android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP,
                )
            },
        )
        finish()
    }
}
