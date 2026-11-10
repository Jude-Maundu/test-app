import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/providers/assistant_provider.dart';
import 'package:test_app/services/linux_platform_service.dart';
import 'package:test_app/services/platform_service.dart';
import 'package:test_app/services/tool_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
  });

  group('Linux Platform & Desktop Integration Tests', () {
    test('1. PlatformService identifies Linux environment', () {
      expect(PlatformService.isLinux, isTrue);
    });

    test('2. LinuxPlatformService correctly maps standard app names', () {
      expect(LinuxPlatformService.mapApp('chrome'), equals('google-chrome'));
      expect(LinuxPlatformService.mapApp('com.android.chrome'), equals('google-chrome'));
      expect(LinuxPlatformService.mapApp('browser'), equals('firefox'));
      expect(LinuxPlatformService.mapApp('code'), equals('code'));
      expect(LinuxPlatformService.mapApp('terminal'), equals('gnome-terminal'));
      expect(LinuxPlatformService.mapApp('settings'), equals('gnome-control-center'));
      expect(LinuxPlatformService.mapApp('files'), equals('nautilus'));
      expect(LinuxPlatformService.mapApp('calculator'), equals('gnome-calculator'));
    });

    test('3. Detects presence of standard Linux binaries or desktop entries', () async {
      // Common binaries like 'which' or web URLs
      expect(await LinuxPlatformService.isAppInstalled('which'), isTrue);
      expect(await LinuxPlatformService.isAppInstalled('https://google.com'), isTrue);
      expect(await LinuxPlatformService.isAppInstalled('youtube'), isTrue);
    });

    test('4. Linux device actions return valid responses', () async {
      final volUp = await LinuxPlatformService.performDeviceAction('volume_up');
      expect(volUp, contains('volume'));

      final volDown = await LinuxPlatformService.performDeviceAction('volume_down');
      expect(volDown, contains('volume'));

      final mute = await LinuxPlatformService.performDeviceAction('mute');
      expect(mute, contains('mute'));

      final battery = await LinuxPlatformService.performDeviceAction('battery_level');
      expect(battery, anyOf(contains('Battery is'), contains('unavailable')));

      final flashlight = await LinuxPlatformService.performDeviceAction('flashlight_on');
      expect(flashlight, contains('not available on Linux desktop'));
    });

    test('5. Linux media control handles actions gracefully', () async {
      final res = await LinuxPlatformService.mediaControl('play');
      expect(res, anyOf(contains('Sent play'), contains('No active media players')));
    });

    test('6. AssistantProvider enables voice features on Linux', () async {
      final assistant = AssistantProvider();
      expect(assistant.voiceSupported, isTrue);
      await assistant.init();
      expect(assistant.speechAvailable, isTrue);
    });

    test('7. LaunchAppTool resolves desktop packages on Linux', () {
      final tool = LaunchAppTool();
      expect(tool.validate({'package_name': 'firefox'}), isNull);
      expect(tool.validate({}), isNotNull);
    });

    test('8. SetTimerTool and SetAlarmTool execute properly', () async {
      final alarmRes = await LinuxPlatformService.setAlarm('12:30', 'Lunch');
      expect(alarmRes, contains('Alarm set for 12:30.'));

      final timerRes = await LinuxPlatformService.performDeviceAction('setTimer', arguments: {
        'seconds': 5,
        'label': 'Tea',
      });
      expect(timerRes, contains('Opened timer for 5 seconds.'));
    });
  });
}
