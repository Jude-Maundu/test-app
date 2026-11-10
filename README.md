# test_app

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Ollama (local models)

Install and start [Ollama](https://ollama.com/) on the machine that will host
the model. The app connects to its HTTP API; it does not install or run the
Ollama server itself. In **Settings**, choose **Ollama (Local)**, enter the
server URL and a model name (for example `llama3.2`), then choose **Pull Model**.
After the download finishes, commands are sent to that model through Ollama.
The **Pull Gemma 3 4B** button downloads `gemma3:4b` and makes it Jarvis's
selected Ollama model. The download is around 3 GB. Ollama runs the model on
the computer hosting Ollama, not directly on the phone; after download,
inference can work without internet while the computer and phone remain
connected on the local network.

In **Settings → Personalization**, set the name Jarvis should call you. Jarvis
greets you by name when the app opens and uses your name naturally in model
replies, including local Ollama conversations and Android hands-free requests.

The default URL is `http://localhost:11434` on desktop and in Chrome on the
same computer, and `http://10.0.2.2:11434` on the Android emulator. Android's `localhost` refers
to the device itself, not your computer, so use the emulator URL when Ollama
runs on your computer. For a physical Android device, use the computer's LAN
IP address and configure Ollama to listen on the LAN (for example,
`OLLAMA_HOST=0.0.0.0:11434`). Only expose Ollama on a trusted network: its
standard HTTP API does not provide authentication. Android permits HTTP
connections for this app so it can reach a local Ollama server.

For a physical phone, the phone and computer must be on the same non-guest
Wi-Fi network, and the router must not isolate wireless clients. On the Linux
computer, verify the service locally and through its LAN address:

```sh
curl http://127.0.0.1:11434/api/tags
curl http://192.168.1.61:11434/api/tags
```

Replace `192.168.1.61` with the computer's current LAN address. If the first
request works but the second does not, Ollama is only listening on loopback or
the host firewall is blocking port 11434. Configure `OLLAMA_HOST=0.0.0.0:11434`
for the Ollama service and allow TCP port 11434 only from your trusted LAN.
Then use that LAN address in Jarvis. Also temporarily disable VPN/private DNS
on the phone while diagnosing connection-aborted or host-lookup errors.

### Pulling a model from Chrome

The browser contacts Ollama directly. Ollama must allow the browser's origin,
otherwise Chrome blocks the request (including `/api/pull`) even when Ollama is
running correctly. For local development on Linux, add this to the Ollama
service with `sudo systemctl edit ollama`:

```ini
[Service]
Environment="OLLAMA_ORIGINS=*"
```

Then restart it with `sudo systemctl daemon-reload && sudo systemctl restart
ollama` and reload Jarvis. `*` allows any browser origin, so use it only on a
trusted computer/network and prefer the native Android app for normal use. On
a physical phone, also configure `OLLAMA_HOST=0.0.0.0:11434`, use the computer's
LAN IP in Jarvis, and allow port 11434 only on a trusted local network.

## Android hands-free mode

In Settings, configure the provider and model (and Ollama URL if applicable),
then tap **Start listening** under **Hands-free mode**. Say “Hey Jarvis”
followed by your request. The
Android foreground service keeps a visible notification while listening; use
its **Stop listening** action or Settings to stop it. Microphone and
notification permissions are required. The service can answer through Ollama
while the app is not open, provided the phone can still reach the configured
Ollama server. Android may stop it after a force-stop, restart, or due to
device-specific battery management; launch the app and start it again.

Wake-word detection uses the speech-recognition service installed on the
device, with offline recognition requested when supported. The recognition
provider may still use network services, so this is not guaranteed to be
fully offline or private. The Ollama model runs on the configured host, not
on the phone. Hands-free mode is currently Android-only.

The service reports recognition errors in its ongoing notification and retries
after transient stops. If it reports that recognition is unavailable, install
or enable a speech-recognition service in Android settings.

## Cloud model providers

Settings supports Anthropic, OpenAI, Google Gemini, Groq, and OpenRouter.
Choose a provider, paste its API key, and save; the model is optional and Jarvis
uses a provider default if none is entered. **Check key & choose model** asks
the provider for chat models the key can access and saves a recommended one.
If Gemini says a saved model is retired, Jarvis refreshes the available model
list and retries once automatically. **Get an API key** opens the provider's
key page. Keys are stored in secure device storage; providers may charge for
requests. An `insufficient_quota`/credit-balance response means the provider
account needs billing or credits; changing the model or re-entering the same
key does not resolve that account limit. The hands-free service uses the
selected provider and model as well.

When running in Chrome, cloud API requests are made directly by the browser.
Some providers or browser origins can reject these requests because of CORS;
use the native Android build if the UI reports a browser network/CORS error.
Do not use browser builds to protect production API keys: client-side keys can
be extracted. A production web deployment should route provider calls through
an authenticated backend.

## Jarvis capabilities

Jarvis can search contacts (after permission) and requires an explicit tap or
spoken confirmation before calling or sending SMS. Recent conversation turns
are stored on-device for follow-up questions. The interface includes a
voice-reactive orb, chat history, text entry, saved local notes, speech
rate/voice settings, and a stop-speaking control.

Supported Android actions can set alarms and timers, open calendar event
forms, launch map navigation and web/weather searches, adjust media volume,
toggle the flashlight, report battery level, or open Wi-Fi/Bluetooth/Do Not
Disturb/brightness settings. Android retains control over sensitive settings
changes and calendar saving.

The Quick Settings tile and launcher shortcut open Jarvis. Android default
assistant selection is available in Settings where the device supports the
assistant role; it opens the Jarvis app from the system assistant gesture but
does not provide always-on hotword detection. A dedicated wake-word engine and
sentence streaming are not implemented. Media-session control requires
notification access and support from the active media app. The wake phrase currently
relies on Android's speech-recognition service, which may use network
recognition and has device-specific reliability and battery behavior.

Anthropic may also use a build-time key, but device Settings is recommended.
Create a root `.env` file in JSON format:

Create a root `.env` file in JSON format and put a rotated key in it:

```json
{"LLM_API_KEY":"replace-with-your-new-key"}
```

Run or build with `--dart-define-from-file=.env`, for example:

```sh
flutter run --dart-define-from-file=.env
```

The app checks the key saved in Settings first, then falls back to `LLM_API_KEY`.
Build-time defines are compiled into the client app and are not suitable for
protecting a production secret; use a backend to keep a provider key private.
