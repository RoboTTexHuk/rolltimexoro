import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as XOMath;
import 'dart:ui';

import 'package:appsflyer_sdk/appsflyer_sdk.dart'
    show AppsFlyerOptions, AppsflyerSdk;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, SystemUiOverlayStyle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as XOTimezoneData;
import 'package:timezone/timezone.dart' as XOTimezone;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// Если эти классы есть в main.dart – оставь импорт.
import 'main.dart' show MafiaHarbor, CaptainHarbor, BillHarbor;

// ============================================================================
// XO инфраструктура (бывшая Ncup инфраструктура / Dress Retro инфраструктура)
// ============================================================================

class XOLogger {
  const XOLogger();

  void xoLogInfo(Object xoMessage) =>
      debugPrint('[DressRetroLogger] $xoMessage');

  void xoLogWarn(Object xoMessage) =>
      debugPrint('[DressRetroLogger/WARN] $xoMessage');

  void xoLogError(Object xoMessage) =>
      debugPrint('[DressRetroLogger/ERR] $xoMessage');
}

class XOVault {
  static final XOVault xoSharedInstance = XOVault._xoInternalConstructor();
  XOVault._xoInternalConstructor();
  factory XOVault() => xoSharedInstance;

  final XOLogger xoLoggerInstance = const XOLogger();
}

// ============================================================================
// Константы (статистика/кеш) — строки в кавычках не меняем
// ============================================================================

const String XOmetrLoadedOnceKey = 'wheel_loaded_once';
const String XOmetrStatEndpoint = 'https://getgame.portalroullete.bar/stat';
const String XOmetrCachedFcmKey = 'wheel_cached_fcm';

// ============================================================================
// Утилиты: XOKit (бывший NcupKit / DressRetroKit)
// ============================================================================

class XOKit {
  static bool xoLooksLikeBareMail(Uri xoUri) {
    final String xoScheme = xoUri.scheme;
    if (xoScheme.isNotEmpty) return false;
    final String xoRaw = xoUri.toString();
    return xoRaw.contains('@') && !xoRaw.contains(' ');
  }

  static Uri xoToMailto(Uri xoUri) {
    final String xoFull = xoUri.toString();
    final List<String> xoBits = xoFull.split('?');
    final String xoWho = xoBits.first;
    final Map<String, String> xoQuery =
    xoBits.length > 1 ? Uri.splitQueryString(xoBits[1]) : <String, String>{};
    return Uri(
      scheme: 'mailto',
      path: xoWho,
      queryParameters: xoQuery.isEmpty ? null : xoQuery,
    );
  }

  static Uri xoGmailize(Uri xoMailUri) {
    final Map<String, String> xoQp = xoMailUri.queryParameters;
    final Map<String, String> xoParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (xoMailUri.path.isNotEmpty) 'to': xoMailUri.path,
      if ((xoQp['subject'] ?? '').isNotEmpty) 'su': xoQp['subject']!,
      if ((xoQp['body'] ?? '').isNotEmpty) 'body': xoQp['body']!,
      if ((xoQp['cc'] ?? '').isNotEmpty) 'cc': xoQp['cc']!,
      if ((xoQp['bcc'] ?? '').isNotEmpty) 'bcc': xoQp['bcc']!,
    };
    return Uri.https('mail.google.com', '/mail/', xoParams);
  }

  static String xoDigitsOnly(String xoSource) =>
      xoSource.replaceAll(RegExp(r'[^0-9+]'), '');
}

// ============================================================================
// Сервис открытия ссылок: XOLinker (бывший NcupLinker / DressRetroLinker)
// ============================================================================

class XOLinker {
  static Future<bool> xoOpen(Uri xoUri) async {
    try {
      if (await launchUrl(
        xoUri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }
      return await launchUrl(
        xoUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (xoError) {
      debugPrint('DressRetroLinker error: $xoError; url=$xoUri');
      try {
        return await launchUrl(
          xoUri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }
}

// ============================================================================
// FCM Background Handler
// ============================================================================

@pragma('vm:entry-point')
Future<void> xoFcmBackgroundHandler(RemoteMessage xoMessage) async {
  debugPrint("Spin ID: ${xoMessage.messageId}");
  debugPrint("Spin Data: ${xoMessage.data}");
}

// ============================================================================
// XODeviceProfile (бывший NcupDeviceProfile / DressRetroDeviceProfile)
// ============================================================================

class XODeviceProfile {
  String? xoDeviceId;
  String? xoSessionId = 'wheel-one-off';
  String? xoPlatformKind;
  String? xoOsBuild;
  String? xoAppVersion;
  String? xoLocaleCode;
  String? xoTimezoneName;
  bool xoPushEnabled = true;

  Future<void> xoInitialize() async {
    final DeviceInfoPlugin xoInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo xoAndroidInfo = await xoInfoPlugin.androidInfo;
      xoDeviceId = xoAndroidInfo.id;
      xoPlatformKind = 'android';
      xoOsBuild = xoAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo xoIosInfo = await xoInfoPlugin.iosInfo;
      xoDeviceId = xoIosInfo.identifierForVendor;
      xoPlatformKind = 'ios';
      xoOsBuild = xoIosInfo.systemVersion;
    }

    final PackageInfo xoPackageInfo = await PackageInfo.fromPlatform();
    xoAppVersion = xoPackageInfo.version;
    xoLocaleCode = Platform.localeName.split('_').first;
    xoTimezoneName = XOTimezone.local.name;
    xoSessionId = 'wheel-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> xoAsMap({String? xoFcmToken}) => <String, dynamic>{
    'fcm_token': xoFcmToken ?? 'missing_token',
    'device_id': xoDeviceId ?? 'missing_id',
    'app_name': 'joiler',
    'instance_id': xoSessionId ?? 'missing_session',
    'platform': xoPlatformKind ?? 'missing_system',
    'os_version': xoOsBuild ?? 'missing_build',
    'app_version': xoAppVersion ?? 'missing_app',
    'language': xoLocaleCode ?? 'en',
    'timezone': xoTimezoneName ?? 'UTC',
    'push_enabled': xoPushEnabled,
  };
}

// ============================================================================
// AppsFlyer шпион: XOSpy (бывший NcupSpy / DressRetroSpy)
// ============================================================================

class XOSpy {
  AppsFlyerOptions? xoOptions;
  AppsflyerSdk? xoSdk;

  String xoAppsFlyerUid = '';
  String xoAppsFlyerData = '';

  void xoStart({VoidCallback? xoOnUpdate}) {
    final AppsFlyerOptions xoOpts = AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6756072063',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    xoOptions = xoOpts;
    xoSdk = AppsflyerSdk(xoOpts);

    xoSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    xoSdk?.startSDK(
      onSuccess: () =>
          XOVault().xoLoggerInstance.xoLogInfo('WheelSpy started'),
      onError: (xoCode, xoMsg) =>
          XOVault().xoLoggerInstance.xoLogError('WheelSpy error $xoCode: $xoMsg'),
    );

    xoSdk?.onInstallConversionData((xoValue) {
      xoAppsFlyerData = xoValue.toString();
      xoOnUpdate?.call();
    });

    xoSdk?.getAppsFlyerUID().then((xoValue) {
      xoAppsFlyerUid = xoValue.toString();
      xoOnUpdate?.call();
    });
  }
}

// ============================================================================
// Мост для FCM токена: XOFcmBridge (бывший NcupFcmBridge / DressRetroFcmBridge)
// ============================================================================

class XOFcmBridge {
  final XOLogger xoLog = const XOLogger();
  String? xoToken;
  final List<void Function(String)> xoWaiters = <void Function(String)>[];

  String? get xoCurrentToken => xoToken;

  XOFcmBridge() {
    const MethodChannel('com.example.fcm/token')
        .setMethodCallHandler((MethodCall xoCall) async {
      if (xoCall.method == 'setToken') {
        final String xoTokenString = xoCall.arguments as String;
        if (xoTokenString.isNotEmpty) {
          xoSetToken(xoTokenString);
        }
      }
    });

    xoRestoreToken();
  }

  Future<void> xoRestoreToken() async {
    try {
      final SharedPreferences xoPrefs = await SharedPreferences.getInstance();
      final String? xoCached = xoPrefs.getString(XOmetrCachedFcmKey);
      if (xoCached != null && xoCached.isNotEmpty) {
        xoSetToken(xoCached, xoNotify: false);
      }
    } catch (_) {}
  }

  Future<void> xoPersistToken(String xoNewToken) async {
    try {
      final SharedPreferences xoPrefs = await SharedPreferences.getInstance();
      await xoPrefs.setString(XOmetrCachedFcmKey, xoNewToken);
    } catch (_) {}
  }

  void xoSetToken(
      String xoNewToken, {
        bool xoNotify = true,
      }) {
    xoToken = xoNewToken;
    xoPersistToken(xoNewToken);
    if (xoNotify) {
      for (final void Function(String) xoCallback
      in List<void Function(String)>.from(xoWaiters)) {
        try {
          xoCallback(xoNewToken);
        } catch (xoErr) {
          xoLog.xoLogWarn('fcm waiter error: $xoErr');
        }
      }
      xoWaiters.clear();
    }
  }

  Future<void> xoWaitForToken(
      Function(String xoTokenValue) xoOnToken,
      ) async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if ((xoToken ?? '').isNotEmpty) {
        xoOnToken(xoToken!);
        return;
      }

      xoWaiters.add(xoOnToken);
    } catch (xoErr) {
      xoLog.xoLogError('wheelWaitToken error: $xoErr');
    }
  }
}

// ============================================================================
// XO Loader — такой же по виду (N + CUP), но в XO-стиле
// ============================================================================

class XOLoader extends StatefulWidget {
  const XOLoader({Key? key}) : super(key: key);

  @override
  State<XOLoader> createState() => _XOLoaderState();
}

class _XOLoaderState extends State<XOLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController xoController;

  static const Color xoBackgroundColor = Color(0xFF05071B);

  @override
  void initState() {
    super.initState();

    xoController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    xoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: xoBackgroundColor,
      child: AnimatedBuilder(
        animation: xoController,
        builder: (BuildContext context, Widget? child) {
          final double xoPhase = xoController.value * 2 * XOMath.pi;
          return CustomPaint(
            painter: XOLoaderPainter(
              xoPhase: xoPhase,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

///
/// XOLoaderPainter
/// Рисует тот же стиль: мягкий фон + большая красная "N" и "CUP" под ней.
///
class XOLoaderPainter extends CustomPainter {
  final double xoPhase;

  XOLoaderPainter({
    required this.xoPhase,
  });

  @override
  void paint(Canvas xoCanvas, Size xoSize) {
    final double xoWidth = xoSize.width;
    final double xoHeight = xoSize.height;

    final Paint xoBackgroundPaint = Paint()
      ..color = const Color(0xFF05071B)
      ..style = PaintingStyle.fill;
    xoCanvas.drawRect(Offset.zero & xoSize, xoBackgroundPaint);

    final double xoPulse = (XOMath.sin(xoPhase) + 1) / 2; // 0..1

    final Paint xoCirclePaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.red.withOpacity(0.14 + 0.16 * xoPulse),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(xoWidth * 0.5, xoHeight * 0.45),
          radius: xoHeight * (0.4 + 0.15 * xoPulse),
        ),
      );

    xoCanvas.drawCircle(
      Offset(xoWidth * 0.5, xoHeight * 0.45),
      xoHeight * (0.4 + 0.15 * xoPulse),
      xoCirclePaint,
    );

    final Paint xoOuterPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.redAccent.withOpacity(0.10 + 0.10 * (1 - xoPulse)),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(xoWidth * 0.5, xoHeight * 0.45),
          radius: xoHeight * (0.55 + 0.10 * (1 - xoPulse)),
        ),
      );
    xoCanvas.drawCircle(
      Offset(xoWidth * 0.5, xoHeight * 0.45),
      xoHeight * (0.55 + 0.10 * (1 - xoPulse)),
      xoOuterPaint,
    );

    final double xoBaseSize = xoWidth * 0.35;
    final double xoFontSize =
        xoBaseSize + xoPulse * (xoBaseSize * 0.15);

    const String xoLetter = 'N';
    const String xoWord = 'CUP';

    final TextPainter xoLetterPainter = TextPainter(
      text: TextSpan(
        text: xoLetter,
        style: TextStyle(
          fontSize: xoFontSize,
          fontWeight: FontWeight.w900,
          color: Colors.red.shade600,
          letterSpacing: 4,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.8),
              blurRadius: 22 + 18 * xoPulse,
              offset: const Offset(0, 0),
            ),
            Shadow(
              color: Colors.black.withOpacity(0.8),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: xoWidth);

    final double xoLetterX = (xoWidth - xoLetterPainter.width) / 2;
    final double xoLetterY = (xoHeight - xoLetterPainter.height) / 2;

    final Offset xoLetterOffset = Offset(xoLetterX, xoLetterY);

    final Rect xoLetterRect = Rect.fromCenter(
      center: Offset(xoWidth / 2, xoHeight / 2),
      width: xoLetterPainter.width * 1.4,
      height: xoLetterPainter.height * 1.6,
    );

    final Paint xoGlowPaint = Paint()
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        28 + 24 * xoPulse,
      )
      ..color = Colors.red.withOpacity(0.7 + 0.2 * xoPulse);

    xoCanvas.saveLayer(xoLetterRect, xoGlowPaint);
    xoLetterPainter.paint(xoCanvas, xoLetterOffset);
    xoCanvas.restore();

    xoLetterPainter.paint(xoCanvas, xoLetterOffset);

    final double xoCupFontSize = xoWidth * 0.11;

    final TextPainter xoCupPainter = TextPainter(
      text: const TextSpan(
        text: xoWord,
        style: TextStyle(
          fontSize: 0, // будет заменён ниже
        ),
      ),
      textDirection: TextDirection.ltr,
    );

    final TextPainter xoCupPainterActual = TextPainter(
      text: TextSpan(
        text: xoWord,
        style: TextStyle(
          fontSize: xoCupFontSize,
          fontWeight: FontWeight.w600,
          color: Colors.red.shade100.withOpacity(0.95),
          letterSpacing: 5,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.7),
              blurRadius: 12 + 10 * xoPulse,
              offset: const Offset(0, 0),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: xoWidth);

    final double xoCupX = (xoWidth - xoCupPainterActual.width) / 2;
    final double xoCupY =
        xoLetterY + xoLetterPainter.height + xoHeight * 0.03;

    final Offset xoCupOffset = Offset(xoCupX, xoCupY);
    xoCupPainterActual.paint(xoCanvas, xoCupOffset);
  }

  @override
  bool shouldRepaint(covariant XOLoaderPainter xoOldDelegate) =>
      xoOldDelegate.xoPhase != xoPhase;
}

// ============================================================================
// Статистика (xoFinalUrl / xoPostStat) — строки в кавычках не трогаем
// ============================================================================

Future<String> xoFinalUrl(
    String xoStartUrl, {
      int xoMaxHops = 10,
    }) async {
  final HttpClient xoClient = HttpClient();

  try {
    Uri xoCurrentUri = Uri.parse(xoStartUrl);

    for (int xoI = 0; xoI < xoMaxHops; xoI++) {
      final HttpClientRequest xoRequest = await xoClient.getUrl(xoCurrentUri);
      xoRequest.followRedirects = false;
      final HttpClientResponse xoResponse = await xoRequest.close();

      if (xoResponse.isRedirect) {
        final String? xoLoc =
        xoResponse.headers.value(HttpHeaders.locationHeader);
        if (xoLoc == null || xoLoc.isEmpty) break;

        final Uri xoNextUri = Uri.parse(xoLoc);
        xoCurrentUri = xoNextUri.hasScheme
            ? xoNextUri
            : xoCurrentUri.resolveUri(xoNextUri);
        continue;
      }

      return xoCurrentUri.toString();
    }

    return xoCurrentUri.toString();
  } catch (xoError) {
    debugPrint('wheelFinalUrl error: $xoError');
    return xoStartUrl;
  } finally {
    xoClient.close(force: true);
  }
}

Future<void> xoPostStat({
  required String xoEvent,
  required int xoTimeStart,
  required String xoUrl,
  required int xoTimeFinish,
  required String xoAppSid,
  int? xoFirstPageTs,
}) async {
  try {
    final String xoResolvedUrl = await xoFinalUrl(xoUrl);
    final Map<String, dynamic> xoPayload = <String, dynamic>{
      'event': xoEvent,
      'timestart': xoTimeStart,
      'timefinsh': xoTimeFinish,
      'url': xoResolvedUrl,
      'appleID': '6755681349',
      'open_count': '$xoAppSid/$xoTimeStart',
    };

    debugPrint('wheelStat $xoPayload');

    final http.Response xoResp = await http.post(
      Uri.parse('$XOmetrStatEndpoint/$xoAppSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(xoPayload),
    );

    debugPrint('wheelStat resp=${xoResp.statusCode} body=${xoResp.body}');
  } catch (xoError) {
    debugPrint('wheelPostStat error: $xoError');
  }
}

// ============================================================================
// WebView-экран: XOTableView (бывший NcupTableView / DressRetroTableView)
// ============================================================================

class XOTableView extends StatefulWidget with WidgetsBindingObserver {
  String xoStartingUrl;
  XOTableView(this.xoStartingUrl, {super.key});

  @override
  State<XOTableView> createState() => _XOTableViewState(xoStartingUrl);
}

class _XOTableViewState extends State<XOTableView> with WidgetsBindingObserver {
  _XOTableViewState(this.xoCurrentUrl);

  final XOVault xoVaultInstance = XOVault();

  late InAppWebViewController xoWebViewController;
  String? xoPushToken;
  final XODeviceProfile xoDeviceProfileInstance = XODeviceProfile();
  final XOSpy xoSpyInstance = XOSpy();

  bool xoOverlayBusy = false;
  String xoCurrentUrl;
  DateTime? xoLastPausedAt;

  bool xoLoadedOnceSent = false;
  int? xoFirstPageTimestamp;
  int xoStartLoadTimestamp = 0;

  final Set<String> xoExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'bnl.com',
    'www.bnl.com',
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'instagram.com',
    'www.instagram.com',
    'twitter.com',
    'www.twitter.com',
    'x.com',
    'www.x.com',
  };

  final Set<String> xoExternalSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'bnl',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
  };

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    FirebaseMessaging.onBackgroundMessage(xoFcmBackgroundHandler);

    xoFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;

    xoInitPushAndGetToken();
    xoDeviceProfileInstance.xoInitialize();
    xoWireForegroundPushHandlers();
    xoBindPlatformNotificationTap();
    xoSpyInstance.xoStart(xoOnUpdate: () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState xoState) {
    if (xoState == AppLifecycleState.paused) {
      xoLastPausedAt = DateTime.now();
    }
    if (xoState == AppLifecycleState.resumed) {
      if (Platform.isIOS && xoLastPausedAt != null) {
        final DateTime xoNow = DateTime.now();
        final Duration xoDrift = xoNow.difference(xoLastPausedAt!);
        if (xoDrift > const Duration(minutes: 25)) {
          xoForceReloadToLobby();
        }
      }
      xoLastPausedAt = null;
    }
  }

  void xoForceReloadToLobby() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration xoDuration) {
      if (!mounted) return;
      // Здесь можно вернуть в лобби (MafiaHarbor / CaptainHarbor / BillHarbor),
      // если нужно.
    });
  }

  // --------------------------------------------------------------------------
  // Push / FCM
  // --------------------------------------------------------------------------

  void xoWireForegroundPushHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage xoMsg) {
      if (xoMsg.data['uri'] != null) {
        xoNavigateTo(xoMsg.data['uri'].toString());
      } else {
        xoReturnToCurrentUrl();
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage xoMsg) {
      if (xoMsg.data['uri'] != null) {
        xoNavigateTo(xoMsg.data['uri'].toString());
      } else {
        xoReturnToCurrentUrl();
      }
    });
  }

  void xoNavigateTo(String xoNewUrl) async {
    await xoWebViewController.loadUrl(
      urlRequest: URLRequest(url: WebUri(xoNewUrl)),
    );
  }

  void xoReturnToCurrentUrl() async {
    Future<void>.delayed(const Duration(seconds: 3), () {
      xoWebViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(xoCurrentUrl)),
      );
    });
  }

  Future<void> xoInitPushAndGetToken() async {
    final FirebaseMessaging xoFm = FirebaseMessaging.instance;
    await xoFm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    xoPushToken = await xoFm.getToken();
  }

  // --------------------------------------------------------------------------
  // Привязка канала: тап по уведомлению из native
  // --------------------------------------------------------------------------

  void xoBindPlatformNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall xoCall) async {
      if (xoCall.method == "onNotificationTap") {
        final Map<String, dynamic> xoPayload =
        Map<String, dynamic>.from(xoCall.arguments);
        debugPrint("URI from platform tap: ${xoPayload['uri']}");
        final String? xoUriString = xoPayload["uri"]?.toString();
        if (xoUriString != null && !xoUriString.contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext xoContext) => XOTableView(xoUriString),
            ),
                (Route<dynamic> xoRoute) => false,
          );
        }
      }
    });
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    xoBindPlatformNotificationTap();

    final bool xoIsDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: xoIsDark ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: <Widget>[
            InAppWebView(
              initialSettings:  InAppWebViewSettings(
                javaScriptEnabled: true,
                disableDefaultErrorPage: true,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                allowsPictureInPictureMediaPlayback: true,
                useOnDownloadStart: true,
                javaScriptCanOpenWindowsAutomatically: true,
                useShouldOverrideUrlLoading: true,
                supportMultipleWindows: true,
              ),
              initialUrlRequest: URLRequest(
                url: WebUri(xoCurrentUrl),
              ),
              onWebViewCreated: (InAppWebViewController xoController) {
                xoWebViewController = xoController;

                xoWebViewController.addJavaScriptHandler(
                  handlerName: 'onServerResponse',
                  callback: (List<dynamic> xoArgs) {
                    xoVaultInstance.xoLoggerInstance
                        .xoLogInfo("JS Args: $xoArgs");
                    try {
                      return xoArgs.reduce(
                              (dynamic xoV, dynamic xoE) => xoV + xoE);
                    } catch (_) {
                      return xoArgs.toString();
                    }
                  },
                );
              },
              onLoadStart: (
                  InAppWebViewController xoController,
                  Uri? xoUri,
                  ) async {
                xoStartLoadTimestamp = DateTime.now().millisecondsSinceEpoch;

                if (xoUri != null) {
                  if (XOKit.xoLooksLikeBareMail(xoUri)) {
                    try {
                      await xoController.stopLoading();
                    } catch (_) {}
                    final Uri xoMailto = XOKit.xoToMailto(xoUri);
                    await XOLinker.xoOpen(
                      XOKit.xoGmailize(xoMailto),
                    );
                    return;
                  }

                  final String xoScheme = xoUri.scheme.toLowerCase();
                  if (xoScheme != 'http' && xoScheme != 'https') {
                    try {
                      await xoController.stopLoading();
                    } catch (_) {}
                  }
                }
              },
              onLoadStop: (
                  InAppWebViewController xoController,
                  Uri? xoUri,
                  ) async {
                await xoController.evaluateJavascript(
                  source: "console.log('Hello from Roulette JS!');",
                );

                setState(() {
                  xoCurrentUrl = xoUri?.toString() ?? xoCurrentUrl;
                });

                Future<void>.delayed(const Duration(seconds: 20), () {
                  xoSendLoadedOnce();
                });
              },
              shouldOverrideUrlLoading: (
                  InAppWebViewController xoController,
                  NavigationAction xoNav,
                  ) async {
                final Uri? xoUri = xoNav.request.url;
                if (xoUri == null) {
                  return NavigationActionPolicy.ALLOW;
                }

                if (XOKit.xoLooksLikeBareMail(xoUri)) {
                  final Uri xoMailto = XOKit.xoToMailto(xoUri);
                  await XOLinker.xoOpen(
                    XOKit.xoGmailize(xoMailto),
                  );
                  return NavigationActionPolicy.CANCEL;
                }

                final String xoScheme = xoUri.scheme.toLowerCase();

                if (xoScheme == 'mailto') {
                  await XOLinker.xoOpen(
                    XOKit.xoGmailize(xoUri),
                  );
                  return NavigationActionPolicy.CANCEL;
                }

                if (xoScheme == 'tel') {
                  await launchUrl(
                    xoUri,
                    mode: LaunchMode.externalApplication,
                  );
                  return NavigationActionPolicy.CANCEL;
                }

                final String xoHost = xoUri.host.toLowerCase();
                final bool xoIsSocial =
                    xoHost.endsWith('facebook.com') ||
                        xoHost.endsWith('instagram.com') ||
                        xoHost.endsWith('twitter.com') ||
                        xoHost.endsWith('x.com');

                if (xoIsSocial) {
                  await XOLinker.xoOpen(xoUri);
                  return NavigationActionPolicy.CANCEL;
                }

                if (xoIsExternalDestination(xoUri)) {
                  final Uri xoMapped = xoMapExternalToHttp(xoUri);
                  await XOLinker.xoOpen(xoMapped);
                  return NavigationActionPolicy.CANCEL;
                }

                if (xoScheme != 'http' && xoScheme != 'https') {
                  return NavigationActionPolicy.CANCEL;
                }

                return NavigationActionPolicy.ALLOW;
              },
              onCreateWindow: (
                  InAppWebViewController xoController,
                  CreateWindowAction xoReq,
                  ) async {
                final Uri? xoUrl = xoReq.request.url;
                if (xoUrl == null) return false;

                if (XOKit.xoLooksLikeBareMail(xoUrl)) {
                  final Uri xoMail = XOKit.xoToMailto(xoUrl);
                  await XOLinker.xoOpen(
                    XOKit.xoGmailize(xoMail),
                  );
                  return false;
                }

                final String xoScheme = xoUrl.scheme.toLowerCase();

                if (xoScheme == 'mailto') {
                  await XOLinker.xoOpen(
                    XOKit.xoGmailize(xoUrl),
                  );
                  return false;
                }

                if (xoScheme == 'tel') {
                  await launchUrl(
                    xoUrl,
                    mode: LaunchMode.externalApplication,
                  );
                  return false;
                }

                final String xoHost = xoUrl.host.toLowerCase();
                final bool xoIsSocial =
                    xoHost.endsWith('facebook.com') ||
                        xoHost.endsWith('instagram.com') ||
                        xoHost.endsWith('twitter.com') ||
                        xoHost.endsWith('x.com');

                if (xoIsSocial) {
                  await XOLinker.xoOpen(xoUrl);
                  return false;
                }

                if (xoIsExternalDestination(xoUrl)) {
                  final Uri xoMapped = xoMapExternalToHttp(xoUrl);
                  await XOLinker.xoOpen(xoMapped);
                  return false;
                }

                if (xoScheme == 'http' || xoScheme == 'https') {
                  xoController.loadUrl(
                    urlRequest: URLRequest(url: WebUri(xoUrl.toString())),
                  );
                }

                return false;
              },
            ),
            if (xoOverlayBusy)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black87,
                  child: Center(
                    child: XOLoader(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ========================================================================
  // Внешние “столы” (протоколы/мессенджеры/соцсети)
  // ========================================================================

  bool xoIsExternalDestination(Uri xoUri) {
    final String xoScheme = xoUri.scheme.toLowerCase();
    if (xoExternalSchemes.contains(xoScheme)) {
      return true;
    }

    if (xoScheme == 'http' || xoScheme == 'https') {
      final String xoHost = xoUri.host.toLowerCase();
      if (xoExternalHosts.contains(xoHost)) {
        return true;
      }
      if (xoHost.endsWith('t.me')) return true;
      if (xoHost.endsWith('wa.me')) return true;
      if (xoHost.endsWith('m.me')) return true;
      if (xoHost.endsWith('signal.me')) return true;
      if (xoHost.endsWith('facebook.com')) return true;
      if (xoHost.endsWith('instagram.com')) return true;
      if (xoHost.endsWith('twitter.com')) return true;
      if (xoHost.endsWith('x.com')) return true;
    }

    return false;
  }

  Uri xoMapExternalToHttp(Uri xoUri) {
    final String xoScheme = xoUri.scheme.toLowerCase();

    if (xoScheme == 'tg' || xoScheme == 'telegram') {
      final Map<String, String> xoQp = xoUri.queryParameters;
      final String? xoDomain = xoQp['domain'];
      if (xoDomain != null && xoDomain.isNotEmpty) {
        return Uri.https('t.me', '/$xoDomain', <String, String>{
          if (xoQp['start'] != null) 'start': xoQp['start']!,
        });
      }
      final String xoPath = xoUri.path.isNotEmpty ? xoUri.path : '';
      return Uri.https(
        't.me',
        '/$xoPath',
        xoUri.queryParameters.isEmpty ? null : xoUri.queryParameters,
      );
    }

    if (xoScheme == 'whatsapp') {
      final Map<String, String> xoQp = xoUri.queryParameters;
      final String? xoPhone = xoQp['phone'];
      final String? xoText = xoQp['text'];
      if (xoPhone != null && xoPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${XOKit.xoDigitsOnly(xoPhone)}',
          <String, String>{
            if (xoText != null && xoText.isNotEmpty) 'text': xoText,
          },
        );
      }
      return Uri.https(
        'wa.me',
        '/',
        <String, String>{
          if (xoText != null && xoText.isNotEmpty) 'text': xoText,
        },
      );
    }

    if (xoScheme == 'bnl') {
      final String xoNewPath = xoUri.path.isNotEmpty ? xoUri.path : '';
      return Uri.https(
        'bnl.com',
        '/$xoNewPath',
        xoUri.queryParameters.isEmpty ? null : xoUri.queryParameters,
      );
    }

    return xoUri;
  }

  Future<void> xoSendLoadedOnce() async {
    if (xoLoadedOnceSent) {
      debugPrint('Wheel Loaded already sent, skip');
      return;
    }

    final int xoNow = DateTime.now().millisecondsSinceEpoch;

    await xoPostStat(
      xoEvent: 'Loaded',
      xoTimeStart: xoStartLoadTimestamp,
      xoTimeFinish: xoNow,
      xoUrl: xoCurrentUrl,
      xoAppSid: xoSpyInstance.xoAppsFlyerUid,
      xoFirstPageTs: xoFirstPageTimestamp,
    );

    xoLoadedOnceSent = true;
  }
}