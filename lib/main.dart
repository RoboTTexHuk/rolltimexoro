import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Platform, HttpHeaders, HttpClient, HttpClientRequest, HttpClientResponse;
import 'dart:math' as math;
import 'dart:ui';

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as appsflyer_core;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodChannel, SystemChrome, SystemUiOverlayStyle, MethodCall;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:orroll/pipu.dart';
// import 'package:ncup/psuh.dart' hide NcupLoaderPainter, NcupLoader;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;

import 'AppXO.dart';

// ============================================================================
// Константы
// ============================================================================

const String xoDressRetroLoadedOnceKey = 'loaded_once';
const String xoDressRetroStatEndpoint = 'https://myapp.rolltime.best/stat';
const String xoDressRetroCachedFcmKey = 'cached_fcm';
const String xoDressRetroCachedDeepKey = 'cached_deep_push_uri';

// ---------------------- Банк: схемы и домены ----------------------

const Set<String> xoBankSchemes = {
  'td',
  'rbc',
  'cibc',
  'scotiabank',
  'bmo',
  'bmodigitalbanking',
  'desjardins',
  'tangerine',
  'nationalbank',
  'simplii',
  'dominotoronto',
};

const Set<String> xoBankDomains = {
  'td.com',
  'tdcanadatrust.com',
  'easyweb.td.com',
  'rbc.com',
  'royalbank.com',
  'online.royalbank.com',
  'cibc.com',
  'cibc.ca',
  'online.cibc.com',
  'scotiabank.com',
  'scotiaonline.scotiabank.com',
  'bmo.com',
  'bmo.ca',
  'bmodigitalbanking.com',
  'desjardins.com',
  'tangerine.ca',
  'nbc.ca',
  'nationalbank.ca',
  'simplii.com',
  'simplii.ca',
  'dominotoronto.com',
  'dominobank.com',
};

// ============================================================================
// Лёгкие сервисы
// ============================================================================

class XOLoggerService {
  static final XOLoggerService xoSharedInstance =
  XOLoggerService._xoInternalConstructor();

  XOLoggerService._xoInternalConstructor();

  factory XOLoggerService() => xoSharedInstance;

  final Connectivity xoConnectivity = Connectivity();

  void xoLogInfo(Object xoMessage) => debugPrint('[I] $xoMessage');
  void xoLogWarn(Object xoMessage) => debugPrint('[W] $xoMessage');
  void xoLogError(Object xoMessage) => debugPrint('[E] $xoMessage');
}

class XONetworkService {
  final XOLoggerService xoLogger = XOLoggerService();

  Future<bool> xoIsOnline() async {
    final List<ConnectivityResult> xoResults =
    (await xoLogger.xoConnectivity.checkConnectivity()) as List<ConnectivityResult>;
    return xoResults.isNotEmpty && !xoResults.contains(ConnectivityResult.none);
  }

  Future<void> xoPostJson(
      String xoUrl,
      Map<String, dynamic> xoData,
      ) async {
    try {
      await http.post(
        Uri.parse(xoUrl),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(xoData),
      );
    } catch (xoError) {
      xoLogger.xoLogError('postJson error: $xoError');
    }
  }
}

// ============================================================================
// Профиль устройства
// ============================================================================

class XODeviceProfile {
  String? xoDeviceId;
  String? xoSessionId = 'retrocar-session';
  String? xoPlatformName;
  String? xoOsVersion;
  String? xoAppVersion;
  String? xoLanguageCode;
  String? xoTimezoneName;
  bool xoPushEnabled = false;

  Future<void> xoInitialize() async {
    final DeviceInfoPlugin xoDeviceInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo xoAndroidInfo = await xoDeviceInfoPlugin.androidInfo;
      xoDeviceId = xoAndroidInfo.id;
      xoPlatformName = 'android';
      xoOsVersion = xoAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo xoIosInfo = await xoDeviceInfoPlugin.iosInfo;
      xoDeviceId = xoIosInfo.identifierForVendor;
      xoPlatformName = 'ios';
      xoOsVersion = xoIosInfo.systemVersion;
    }

    final PackageInfo xoPackageInfo = await PackageInfo.fromPlatform();
    xoAppVersion = xoPackageInfo.version;
    xoLanguageCode = Platform.localeName.split('_').first;
    xoTimezoneName = tz_zone.local.name;
    xoSessionId = 'retrocar-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> xoToMap({String? xoFcmToken}) => <String, dynamic>{
    'fcm_token': xoFcmToken ?? 'missing_token',
    'device_id': xoDeviceId ?? 'missing_id',
    'app_name': 'rolltime',
    'instance_id': xoSessionId ?? 'missing_session',
    'platform': xoPlatformName ?? 'missing_system',
    'os_version': xoOsVersion ?? 'missing_build',
    'app_version': xoAppVersion ?? 'missing_app',
    'language': xoLanguageCode ?? 'en',
    'timezone': xoTimezoneName ?? 'UTC',
    'push_enabled': xoPushEnabled,
  };
}

// ============================================================================
// AppsFlyer Spy
// ============================================================================

class XOAnalyticsSpyService {
  appsflyer_core.AppsFlyerOptions? xoAppsFlyerOptions;
  appsflyer_core.AppsflyerSdk? xoAppsFlyerSdk;

  String xoAppsFlyerUid = '';
  String xoAppsFlyerData = '';

  void xoStartTracking({VoidCallback? xoOnUpdate}) {
    final appsflyer_core.AppsFlyerOptions xoConfig =
    appsflyer_core.AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6758861290',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    xoAppsFlyerOptions = xoConfig;
    xoAppsFlyerSdk = appsflyer_core.AppsflyerSdk(xoConfig);

    xoAppsFlyerSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    xoAppsFlyerSdk?.startSDK(
      onSuccess: () =>
          XOLoggerService().xoLogInfo('RetroCarAnalyticsSpy started'),
      onError: (int xoCode, String xoMsg) =>
          XOLoggerService().xoLogError('RetroCarAnalyticsSpy error $xoCode: $xoMsg'),
    );

    xoAppsFlyerSdk?.onInstallConversionData((dynamic xoValue) {
      xoAppsFlyerData = xoValue.toString();
      xoOnUpdate?.call();
    });

    xoAppsFlyerSdk?.getAppsFlyerUID().then((dynamic xoValue) {
      xoAppsFlyerUid = xoValue.toString();
      xoOnUpdate?.call();
    });
  }
}

// ============================================================================
// Provider: пример модели состояния
// ============================================================================

class XOLoaderState extends ChangeNotifier {
  double _xoProgress = 0.0;
  double get xoProgress => _xoProgress;

  void xoSetProgress(double xoValue) {
    _xoProgress = xoValue.clamp(0.0, 1.0);
    notifyListeners();
  }
}

// ============================================================================
// Loader — две золотые буквы X O + падающие звёздочки
// ============================================================================

class XOLoader extends StatefulWidget {
  const XOLoader({Key? key}) : super(key: key);

  @override
  State<XOLoader> createState() => _XOLoaderState();
}

class _XOLoaderState extends State<XOLoader> with SingleTickerProviderStateMixin {
  late AnimationController xoController;
  late List<_XOStarParticle> xoStars;

  @override
  void initState() {
    super.initState();
    xoStars = List<_XOStarParticle>.generate(
      35,
          (int xoIndex) => _XOStarParticle.xoRandom(),
    );

    xoController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )
      ..addListener(() {
        for (final _XOStarParticle xoStar in xoStars) {
          xoStar.xoUpdate(xoController.value);
        }
        setState(() {});
      })
      ..repeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final XOLoaderState? xoLoaderState = context.read<XOLoaderState?>();
      if (xoLoaderState != null) {
        xoController.addListener(() {
          xoLoaderState.xoSetProgress(xoController.value);
        });
      }
    });
  }

  @override
  void dispose() {
    xoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: XOLoaderPainter(
        xoAnimationValue: xoController.value,
        xoStars: xoStars,
      ),
      size: const Size(180, 180),
    );
  }
}

class _XOStarParticle {
  double xoX;
  double xoY;
  double xoSpeedY;
  double xoSize;
  double xoPhase;
  double xoOpacity;

  _XOStarParticle({
    required this.xoX,
    required this.xoY,
    required this.xoSpeedY,
    required this.xoSize,
    required this.xoPhase,
    required this.xoOpacity,
  });

  factory _XOStarParticle.xoRandom() {
    final math.Random xoRandom = math.Random();
    return _XOStarParticle(
      xoX: xoRandom.nextDouble(),
      xoY: xoRandom.nextDouble(),
      xoSpeedY: 0.2 + xoRandom.nextDouble() * 0.8,
      xoSize: 2.0 + xoRandom.nextDouble() * 4.0,
      xoPhase: xoRandom.nextDouble() * 2 * math.pi,
      xoOpacity: 0.4 + xoRandom.nextDouble() * 0.6,
    );
  }

  void xoUpdate(double xoT) {
    xoY += xoSpeedY * 0.02;
    if (xoY > 1.1) {
      xoY = -0.1;
    }
  }
}

class XOLoaderPainter extends CustomPainter {
  final double xoAnimationValue;
  final List<_XOStarParticle> xoStars;

  XOLoaderPainter({
    required this.xoAnimationValue,
    required this.xoStars,
  });

  @override
  void paint(Canvas xoCanvas, Size xoSize) {
    final Offset xoCenter = xoSize.center(Offset.zero);
    final Paint xoBgPaint = Paint()
      ..color = Colors.transparent
      ..style = PaintingStyle.fill;

    xoCanvas.drawRect(Offset.zero & xoSize, xoBgPaint);

    xoDrawStars(xoCanvas, xoSize);
    xoDrawXO(xoCanvas, xoCenter, xoSize);
  }

  void xoDrawStars(Canvas xoCanvas, Size xoSize) {
    for (final _XOStarParticle xoStar in xoStars) {
      final double xoPx = xoStar.xoX * xoSize.width;
      final double xoPy = xoStar.xoY * xoSize.height;

      final double xoFlicker =
          0.6 + 0.4 * math.sin(xoAnimationValue * 2 * math.pi + xoStar.xoPhase);
      final double xoRadius = xoStar.xoSize * xoFlicker;

      final Paint xoPaint = Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            Colors.amber.withOpacity(xoStar.xoOpacity),
            Colors.transparent,
          ],
        ).createShader(
          Rect.fromCircle(center: Offset(xoPx, xoPy), radius: xoRadius),
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

      xoCanvas.drawCircle(Offset(xoPx, xoPy), xoRadius, xoPaint);

      final double xoTailLength = xoStar.xoSize * 3;
      final Paint xoTailPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.amber.withOpacity(xoStar.xoOpacity * 0.7),
            Colors.transparent,
          ],
        ).createShader(
          Rect.fromLTWH(xoPx - 1, xoPy - xoTailLength, 2, xoTailLength),
        );
      xoCanvas.drawRect(
        Rect.fromLTWH(xoPx - 1, xoPy - xoTailLength, 2, xoTailLength),
        xoTailPaint,
      );
    }
  }

  void xoDrawXO(Canvas xoCanvas, Offset xoCenter, Size xoSize) {
    final double xoBaseSize = xoSize.shortestSide * 0.55;
    final double xoXRadius = xoBaseSize * 0.6;
    final double xoStrokeWidth = xoBaseSize * 0.20;

    final double xoScale = 1.0 + 0.04 * math.sin(xoAnimationValue * 2 * math.pi);
    final double xoRotation = 0.05 * math.sin(xoAnimationValue * 2 * math.pi);

    xoCanvas.save();
    xoCanvas.translate(xoCenter.dx, xoCenter.dy);
    xoCanvas.scale(xoScale);
    xoCanvas.rotate(xoRotation);

    final Rect xoGradRect = Rect.fromCenter(
      center: Offset.zero,
      width: xoBaseSize * 2,
      height: xoBaseSize * 2,
    );

    final Gradient xoGoldGradient = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[
        Color(0xFFFFF1B5),
        Color(0xFFFFD700),
        Color(0xFFFFA800),
        Color(0xFFFFF8DC),
      ],
      stops: <double>[0.0, 0.35, 0.7, 1.0],
    );

    final Paint xoPaint = Paint()
      ..shader = xoGoldGradient.createShader(xoGradRect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = xoStrokeWidth
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    final Path xoXPath = Path();
    final double xoHalf = xoXRadius;

    xoXPath.moveTo(-xoHalf, -xoHalf);
    xoXPath.lineTo(xoHalf, xoHalf);
    xoXPath.moveTo(-xoHalf, xoHalf);
    xoXPath.lineTo(xoHalf, -xoHalf);

    final Path xoOPath = Path()
      ..addOval(
        Rect.fromCircle(
          center: Offset(xoBaseSize * 1.1, 0),
          radius: xoXRadius,
        ),
      );

    final double xoAlphaPulse =
        0.75 + 0.25 * math.sin(xoAnimationValue * 2 * math.pi);
    xoPaint.colorFilter = ColorFilter.mode(
      Colors.white.withOpacity(xoAlphaPulse * 0.4),
      BlendMode.srcATop,
    );

    final Paint xoGlowPaint = Paint()
      ..shader = xoGoldGradient.createShader(xoGradRect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = xoStrokeWidth * 1.3
      ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 18);

    xoCanvas.drawPath(xoXPath, xoGlowPaint);
    xoCanvas.drawPath(xoOPath, xoGlowPaint);

    xoCanvas.drawPath(xoXPath, xoPaint);
    xoCanvas.drawPath(xoOPath, xoPaint);

    xoCanvas.restore();
  }

  @override
  bool shouldRepaint(covariant XOLoaderPainter xoOldDelegate) {
    return xoOldDelegate.xoAnimationValue != xoAnimationValue ||
        xoOldDelegate.xoStars != xoStars;
  }
}

// ============================================================================
// FCM фон
// ============================================================================

@pragma('vm:entry-point')
Future<void> xoFcmBackgroundHandler(RemoteMessage xoMessage) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  XOLoggerService().xoLogInfo('bg-fcm: ${xoMessage.messageId}');
  XOLoggerService().xoLogInfo('bg-data: ${xoMessage.data}');

  final dynamic xoLink = xoMessage.data['uri'];
  if (xoLink != null) {
    try {
      final SharedPreferences xoPrefs = await SharedPreferences.getInstance();
      await xoPrefs.setString(
        xoDressRetroCachedDeepKey,
        xoLink.toString(),
      );
    } catch (xoE) {
      XOLoggerService().xoLogError('bg-fcm save deep failed: $xoE');
    }
  }
}

// ============================================================================
// FCM Bridge
// ============================================================================

class XOFcmBridge {
  final XOLoggerService xoLogger = XOLoggerService();
  String? xoToken;
  final List<void Function(String)> xoTokenWaiters =
  <void Function(String)>[];

  String? get xoFcmToken => xoToken;

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
      final String? xoCachedToken = xoPrefs.getString(xoDressRetroCachedFcmKey);
      if (xoCachedToken != null && xoCachedToken.isNotEmpty) {
        xoSetToken(xoCachedToken, xoNotify: false);
      }
    } catch (_) {}
  }

  Future<void> xoPersistToken(String xoNewToken) async {
    try {
      final SharedPreferences xoPrefs = await SharedPreferences.getInstance();
      await xoPrefs.setString(xoDressRetroCachedFcmKey, xoNewToken);
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
      in List<void Function(String)>.from(xoTokenWaiters)) {
        try {
          xoCallback(xoNewToken);
        } catch (xoError) {
          xoLogger.xoLogWarn('fcm waiter error: $xoError');
        }
      }
      xoTokenWaiters.clear();
    }
  }

  Future<void> xoWaitForToken(
      Function(String xoToken) xoOnToken,
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

      xoTokenWaiters.add(xoOnToken);
    } catch (xoError) {
      xoLogger.xoLogError('waitToken error: $xoError');
    }
  }
}

// ============================================================================
// Splash / Hall
// ============================================================================

class XOHall extends StatefulWidget {
  const XOHall({Key? key}) : super(key: key);

  @override
  State<XOHall> createState() => _XOHallState();
}

class _XOHallState extends State<XOHall> {
  final XOFcmBridge xoFcmBridgeInstance = XOFcmBridge();
  bool xoNavigatedOnce = false;
  Timer? xoFallbackTimer;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    xoFcmBridgeInstance.xoWaitForToken((String xoToken) {
      xoGoToHarbor(xoToken);
    });

    xoFallbackTimer = Timer(
      const Duration(seconds: 8),
          () => xoGoToHarbor(''),
    );
  }

  void xoGoToHarbor(String xoSignal) {
    if (xoNavigatedOnce) return;
    xoNavigatedOnce = true;
    xoFallbackTimer?.cancel();

    Navigator.pushReplacement(
      context,
      MaterialPageRoute<Widget>(
        builder: (BuildContext xoContext) => XOHarbor(xoSignal: xoSignal),
      ),
    );
  }

  @override
  void dispose() {
    xoFallbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: const SafeArea(
        child: Center(
          child: XOLoader(),
        ),
      ),
    );
  }
}

// ============================================================================
// ViewModel + Courier
// ============================================================================

class XOBosunViewModel {
  final XODeviceProfile xoDeviceProfileInstance;
  final XOAnalyticsSpyService xoAnalyticsSpyInstance;

  XOBosunViewModel({
    required this.xoDeviceProfileInstance,
    required this.xoAnalyticsSpyInstance,
  });

  Map<String, dynamic> xoDeviceMap(String? xoFcmToken) =>
      xoDeviceProfileInstance.xoToMap( xoFcmToken: xoFcmToken);

  Map<String, dynamic> xoAppsFlyerPayload(
      String? xoToken, {
        String? xoDeepLink, String? deepLink,
      }) =>
      <String, dynamic>{
        'content': <String, dynamic>{
          'af_data': xoAnalyticsSpyInstance.xoAppsFlyerData,
          'af_id': xoAnalyticsSpyInstance.xoAppsFlyerUid,
          'fb_app_name': 'rolltime',
          'app_name': 'rolltime',
          'deep': xoDeepLink,
          'bundle_identifier': 'com.rolltime.xotime.orroll',
          'app_version': '1.0.0',
          'apple_id': '6758861290',
          'fcm_token': xoToken ?? 'no_token',
          'device_id': xoDeviceProfileInstance.xoDeviceId ?? 'no_device',
          'instance_id': xoDeviceProfileInstance.xoSessionId ?? 'no_instance',
          'platform': xoDeviceProfileInstance.xoPlatformName ?? 'no_type',
          'os_version': xoDeviceProfileInstance.xoOsVersion ?? 'no_os',
          'app_version': xoDeviceProfileInstance.xoAppVersion ?? 'no_app',
          'language': xoDeviceProfileInstance.xoLanguageCode ?? 'en',
          'timezone': xoDeviceProfileInstance.xoTimezoneName ?? 'UTC',
          'push_enabled': xoDeviceProfileInstance.xoPushEnabled,
          'useruid': xoAnalyticsSpyInstance.xoAppsFlyerUid,
        },
      };
}

class XOCourierService {
  final XOBosunViewModel xoBosun;
  final InAppWebViewController? Function() xoGetWebViewController;

  XOCourierService({
    required this.xoBosun,
    required this.xoGetWebViewController,
  });

  Future<void> xoPutDeviceToLocalStorage(String? xoToken) async {
    final InAppWebViewController? xoController = xoGetWebViewController();
    if (xoController == null) return;

    final Map<String, dynamic> xoMap = xoBosun.xoDeviceMap(xoToken);
    await xoController.evaluateJavascript(
      source:
      "localStorage.setItem('app_data', JSON.stringify(${jsonEncode(xoMap)}));",
    );
  }

  Future<void> xoSendRawToPage(
      String? xoToken, {
        String? xoDeepLink,
      }) async {
    final InAppWebViewController? xoController = xoGetWebViewController();
    if (xoController == null) return;

    final Map<String, dynamic> xoPayload =
    xoBosun.xoAppsFlyerPayload(xoToken, deepLink: xoDeepLink);
    final String xoJsonString = jsonEncode(xoPayload);

    XOLoggerService().xoLogInfo('SendRawData: $xoJsonString');

    await xoController.evaluateJavascript(
      source: 'sendRawData(${jsonEncode(xoJsonString)});',
    );
  }
}

// ============================================================================
// Статистика / переходы
// ============================================================================

Future<String> xoResolveFinalUrl(
    String xoStartUrl, {
      int xoMaxHops = 10,
    }) async {
  final HttpClient xoHttpClient = HttpClient();

  try {
    Uri xoCurrentUri = Uri.parse(xoStartUrl);

    for (int xoIndex = 0; xoIndex < xoMaxHops; xoIndex++) {
      final HttpClientRequest xoRequest = await xoHttpClient.getUrl(xoCurrentUri);
      xoRequest.followRedirects = false;
      final HttpClientResponse xoResponse = await xoRequest.close();

      if (xoResponse.isRedirect) {
        final String? xoLocationHeader =
        xoResponse.headers.value(HttpHeaders.locationHeader);
        if (xoLocationHeader == null || xoLocationHeader.isEmpty) {
          break;
        }

        final Uri xoNextUri = Uri.parse(xoLocationHeader);
        xoCurrentUri = xoNextUri.hasScheme
            ? xoNextUri
            : xoCurrentUri.resolveUri(xoNextUri);
        continue;
      }

      return xoCurrentUri.toString();
    }

    return xoCurrentUri.toString();
  } catch (xoError) {
    debugPrint('goldenLuxuryResolveFinalUrl error: $xoError');
    return xoStartUrl;
  } finally {
    xoHttpClient.close(force: true);
  }
}

Future<void> xoPostStat({
  required String xoEvent,
  required int xoTimeStart,
  required String xoUrl,
  required int xoTimeFinish,
  required String xoAppSid,
  int? xoFirstPageLoadTs,
}) async {
  try {
    final String xoResolvedUrl = await xoResolveFinalUrl(xoUrl);

    final Map<String, dynamic> xoPayload = <String, dynamic>{
      'event': xoEvent,
      'timestart': xoTimeStart,
      'timefinsh': xoTimeFinish,
      'url': xoResolvedUrl,
      'appleID': '6758861290',
      'open_count': '$xoAppSid/$xoTimeStart',
    };

    debugPrint('goldenLuxuryStat $xoPayload');

    final http.Response xoResponse = await http.post(
      Uri.parse('$xoDressRetroStatEndpoint/$xoAppSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(xoPayload),
    );

    debugPrint(
        'goldenLuxuryStat resp=${xoResponse.statusCode} body=${xoResponse.body}');
  } catch (xoError) {
    debugPrint('goldenLuxuryPostStat error: $xoError');
  }
}

// ============================================================================
// Утилиты для банковских ссылок
// ============================================================================

bool xoIsBankScheme(Uri xoUri) {
  final String xoScheme = xoUri.scheme.toLowerCase();
  return xoBankSchemes.contains(xoScheme);
}

bool xoIsBankDomain(Uri xoUri) {
  final String xoHost = xoUri.host.toLowerCase();
  if (xoHost.isEmpty) return false;

  for (final String xoBank in xoBankDomains) {
    final String xoBankHost = xoBank.toLowerCase();
    if (xoHost == xoBankHost || xoHost.endsWith('.$xoBankHost')) {
      return true;
    }
  }
  return false;
}

Future<bool> xoOpenBank(Uri xoUri) async {
  try {
    if (xoIsBankScheme(xoUri)) {
      final bool xoOk = await launchUrl(
        xoUri,
        mode: LaunchMode.externalApplication,
      );
      return xoOk;
    }

    if ((xoUri.scheme == 'http' || xoUri.scheme == 'https') &&
        xoIsBankDomain(xoUri)) {
      final bool xoOk = await launchUrl(
        xoUri,
        mode: LaunchMode.externalApplication,
      );
      return xoOk;
    }
  } catch (xoE) {
    debugPrint('NcupOpenBank error: $xoE; url=$xoUri');
  }
  return false;
}



// ============================================================================
// Главный WebView — Harbor
// ============================================================================

class XOHarbor extends StatefulWidget {
  final String? xoSignal;

  const XOHarbor({super.key, required this.xoSignal});

  @override
  State<XOHarbor> createState() => _XOHarborState();
}

class _XOHarborState extends State<XOHarbor> with WidgetsBindingObserver {
  InAppWebViewController? xoWebViewController;
  final String xoHomeUrl = 'https://myapp.rolltime.best/';

  int xoWebViewKeyCounter = 0;
  DateTime? xoSleepAt;
  bool xoVeilVisible = false;
  double xoWarmProgress = 0.0;
  late Timer xoWarmTimer;
  final int xoWarmSeconds = 6;
  bool xoCoverVisible = true;

  bool xoLoadedOnceSent = false;
  int? xoFirstPageTimestamp;

  XOCourierService? xoCourier;
  XOBosunViewModel? xoBosunInstance;

  String xoCurrentUrl = '';
  int xoStartLoadTimestamp = 0;

  final XODeviceProfile xoDeviceProfileInstance = XODeviceProfile();
  final XOAnalyticsSpyService xoAnalyticsSpyInstance = XOAnalyticsSpyService();

  final Set<String> xoSpecialSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'viber',
    'skype',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
    'bnl',
  };

  final Set<String> xoExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'm.me',
    'signal.me',
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

  String? xoDeepLinkFromPush;
  String? xoLocalFcmToken;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    xoFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;

    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          xoCoverVisible = false;
        });
      }
    });

    Future<void>.delayed(const Duration(seconds: 7), () {
      if (!mounted) return;
      setState(() {
        xoVeilVisible = true;
      });
    });

    xoBootHarbor();
    xoInitLocalFcmToken();
  }

  Future<void> xoInitLocalFcmToken() async {
    try {
      final String? xoT = await FirebaseMessaging.instance.getToken();
      if (mounted) {
        setState(() {
          xoLocalFcmToken = xoT;
        });
      }
    } catch (xoE) {
      XOLoggerService().xoLogError('getToken error: $xoE');
    }
  }

  Future<void> xoLoadLoadedFlag() async {
    final SharedPreferences xoPrefs = await SharedPreferences.getInstance();
    xoLoadedOnceSent = xoPrefs.getBool(xoDressRetroLoadedOnceKey) ?? false;
  }

  Future<void> xoSaveLoadedFlag() async {
    final SharedPreferences xoPrefs = await SharedPreferences.getInstance();
    await xoPrefs.setBool(xoDressRetroLoadedOnceKey, true);
    xoLoadedOnceSent = true;
  }

  Future<void> xoLoadCachedDeep() async {
    try {
      final SharedPreferences xoPrefs = await SharedPreferences.getInstance();
      final String? xoCached = xoPrefs.getString(xoDressRetroCachedDeepKey);
      if ((xoCached ?? '').isNotEmpty) {
        xoDeepLinkFromPush = xoCached;
      }
    } catch (_) {}
  }

  Future<void> xoSaveCachedDeep(String xoUri) async {
    try {
      final SharedPreferences xoPrefs = await SharedPreferences.getInstance();
      await xoPrefs.setString(xoDressRetroCachedDeepKey, xoUri);
    } catch (_) {}
  }

  Future<void> xoSendLoadedOnce({
    required String xoUrl,
    required int xoTimestart,
  }) async {
    if (xoLoadedOnceSent) {
      debugPrint('Loaded already sent, skip');
      return;
    }

    final int xoNow = DateTime.now().millisecondsSinceEpoch;

    await xoPostStat(
      xoEvent: 'Loaded',
      xoTimeStart: xoTimestart,
      xoTimeFinish: xoNow,
      xoUrl: xoUrl,
      xoAppSid: xoAnalyticsSpyInstance.xoAppsFlyerUid,
      xoFirstPageLoadTs: xoFirstPageTimestamp,
    );

    await xoSaveLoadedFlag();
  }

  void xoBootHarbor() {
    xoStartWarmProgress();
    xoWireFcmHandlers();
    xoAnalyticsSpyInstance.xoStartTracking(
      xoOnUpdate: () => setState(() {}),
    );
    xoBindNotificationTap();
    xoPrepareDeviceProfile();

    Future<void>.delayed(const Duration(seconds: 6), () async {
      await xoPushDeviceInfo();
      await xoPushAppsFlyerData();
    });
  }

  void xoWireFcmHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage xoMessage) async {
      final dynamic xoLink = xoMessage.data['uri'];
      if (xoLink != null) {
        final String xoUri = xoLink.toString();
        xoDeepLinkFromPush = xoUri;
        await xoSaveCachedDeep(xoUri);
        xoNavigateToUri(xoUri);
      } else {
        xoResetHomeAfterDelay();
      }
    });

    FirebaseMessaging.onMessageOpenedApp
        .listen((RemoteMessage xoMessage) async {
      final dynamic xoLink = xoMessage.data['uri'];
      if (xoLink != null) {
        final String xoUri = xoLink.toString();
        xoDeepLinkFromPush = xoUri;
        await xoSaveCachedDeep(xoUri);
        xoNavigateToUri(xoUri);
      } else {
        xoResetHomeAfterDelay();
      }
    });
  }

  void xoBindNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall xoCall) async {
      if (xoCall.method == 'onNotificationTap') {
        final Map<String, dynamic> xoPayload =
        Map<String, dynamic>.from(xoCall.arguments);
        if (xoPayload['uri'] != null &&
            !xoPayload['uri'].toString().contains('Нет URI')) {
          final String xoUri = xoPayload['uri'].toString();
          xoDeepLinkFromPush = xoUri;
          await xoSaveCachedDeep(xoUri);

          if (!mounted) return;

          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext xoContext) => XOTableView(xoUri),
            ),
                (Route<dynamic> xoRoute) => false,
          );
        }
      }
    });
  }

  Future<void> xoPrepareDeviceProfile() async {
    try {
      await xoDeviceProfileInstance.xoInitialize();

      final FirebaseMessaging xoMessaging = FirebaseMessaging.instance;
      final NotificationSettings xoSettings =
      await xoMessaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      xoDeviceProfileInstance.xoPushEnabled =
          xoSettings.authorizationStatus == AuthorizationStatus.authorized ||
              xoSettings.authorizationStatus == AuthorizationStatus.provisional;

      await xoLoadLoadedFlag();
      await xoLoadCachedDeep();

      xoBosunInstance = XOBosunViewModel(
        xoDeviceProfileInstance: xoDeviceProfileInstance,
        xoAnalyticsSpyInstance: xoAnalyticsSpyInstance,
      );

      xoCourier = XOCourierService(
        xoBosun: xoBosunInstance!,
        xoGetWebViewController: () => xoWebViewController,
      );
    } catch (xoError) {
      XOLoggerService().xoLogError('prepareDeviceProfile fail: $xoError');
    }
  }

  void xoNavigateToUri(String xoLink) async {
    try {
      await xoWebViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(xoLink)),
      );
    } catch (xoError) {
      XOLoggerService().xoLogError('navigate error: $xoError');
    }
  }

  void xoResetHomeAfterDelay() {
    Future<void>.delayed(const Duration(seconds: 3), () {
      try {
        xoWebViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(xoHomeUrl)),
        );
      } catch (_) {}
    });
  }

  String? xoResolveTokenForShip() {
    if (widget.xoSignal != null && widget.xoSignal!.isNotEmpty) {
      return widget.xoSignal;
    }
    if ((xoLocalFcmToken ?? '').isNotEmpty) {
      return xoLocalFcmToken;
    }
    return null;
  }

  Future<void> xoPushDeviceInfo() async {
    final String? xoToken = xoResolveTokenForShip();

    XOLoggerService().xoLogInfo('TOKEN ship $xoToken');
    try {
      await xoCourier?.xoPutDeviceToLocalStorage(xoToken);
    } catch (xoError) {
      XOLoggerService().xoLogError('pushDeviceInfo error: $xoError');
    }
  }

  Future<void> xoPushAppsFlyerData() async {
    final String? xoToken = xoResolveTokenForShip();

    try {
      await xoCourier?.xoSendRawToPage(
        xoToken,
        xoDeepLink: xoDeepLinkFromPush,
      );
    } catch (xoError) {
      XOLoggerService().xoLogError('pushAppsFlyerData error: $xoError');
    }
  }

  void xoStartWarmProgress() {
    int xoTick = 0;
    xoWarmProgress = 0.0;

    xoWarmTimer =
        Timer.periodic(const Duration(milliseconds: 100), (Timer xoTimer) {
          if (!mounted) return;

          setState(() {
            xoTick++;
            xoWarmProgress = xoTick / (xoWarmSeconds * 10);

            final XOLoaderState? xoLoaderState =
            context.read<XOLoaderState?>();
            xoLoaderState?.xoSetProgress(xoWarmProgress);

            if (xoWarmProgress >= 1.0) {
              xoWarmProgress = 1.0;
              xoWarmTimer.cancel();
            }
          });
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState xoState) {
    if (xoState == AppLifecycleState.paused) {
      xoSleepAt = DateTime.now();
    }

    if (xoState == AppLifecycleState.resumed) {
      if (Platform.isIOS && xoSleepAt != null) {
        final DateTime xoNow = DateTime.now();
        final Duration xoDrift = xoNow.difference(xoSleepAt!);

        if (xoDrift > const Duration(minutes: 25)) {
          xoReboardHarbor();
        }
      }
      xoSleepAt = null;
    }
  }

  void xoReboardHarbor() {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((Duration xoDuration) {
      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext xoContext) =>
              XOHarbor(xoSignal: widget.xoSignal),
        ),
            (Route<dynamic> xoRoute) => false,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    xoWarmTimer.cancel();
    super.dispose();
  }

  bool xoIsBareEmail(Uri xoUri) {
    final String xoScheme = xoUri.scheme;
    if (xoScheme.isNotEmpty) return false;
    final String xoRaw = xoUri.toString();
    return xoRaw.contains('@') && !xoRaw.contains(' ');
  }

  Uri xoToMailto(Uri xoUri) {
    final String xoFull = xoUri.toString();
    final List<String> xoParts = xoFull.split('?');
    final String xoEmail = xoParts.first;
    final Map<String, String> xoQueryParams = xoParts.length > 1
        ? Uri.splitQueryString(xoParts[1])
        : <String, String>{};

    return Uri(
      scheme: 'mailto',
      path: xoEmail,
      queryParameters: xoQueryParams.isEmpty ? null : xoQueryParams,
    );
  }

  bool xoIsPlatformLink(Uri xoUri) {
    final String xoScheme = xoUri.scheme.toLowerCase();
    if (xoSpecialSchemes.contains(xoScheme)) {
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

  String xoDigitsOnly(String xoSource) =>
      xoSource.replaceAll(RegExp(r'[^0-9+]'), '');

  Uri xoHttpizePlatformUri(Uri xoUri) {
    final String xoScheme = xoUri.scheme.toLowerCase();

    if (xoScheme == 'tg' || xoScheme == 'telegram') {
      final Map<String, String> xoQp = xoUri.queryParameters;
      final String? xoDomain = xoQp['domain'];

      if (xoDomain != null && xoDomain.isNotEmpty) {
        return Uri.https(
          't.me',
          '/$xoDomain',
          <String, String>{
            if (xoQp['start'] != null) 'start': xoQp['start']!,
          },
        );
      }

      final String xoPath = xoUri.path.isNotEmpty ? xoUri.path : '';

      return Uri.https(
        't.me',
        '/$xoPath',
        xoUri.queryParameters.isEmpty ? null : xoUri.queryParameters,
      );
    }

    if ((xoScheme == 'http' || xoScheme == 'https') &&
        xoUri.host.toLowerCase().endsWith('t.me')) {
      return xoUri;
    }

    if (xoScheme == 'viber') {
      return xoUri;
    }

    if (xoScheme == 'whatsapp') {
      final Map<String, String> xoQp = xoUri.queryParameters;
      final String? xoPhone = xoQp['phone'];
      final String? xoText = xoQp['text'];

      if (xoPhone != null && xoPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${xoDigitsOnly(xoPhone)}',
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

    if ((xoScheme == 'http' || xoScheme == 'https') &&
        (xoUri.host.toLowerCase().endsWith('wa.me') ||
            xoUri.host.toLowerCase().endsWith('whatsapp.com'))) {
      return xoUri;
    }

    if (xoScheme == 'skype') {
      return xoUri;
    }

    if (xoScheme == 'fb-messenger') {
      final String xoPath =
      xoUri.pathSegments.isNotEmpty ? xoUri.pathSegments.join('/') : '';
      final Map<String, String> xoQp = xoUri.queryParameters;

      final String xoId = xoQp['id'] ?? xoQp['user'] ?? xoPath;

      if (xoId.isNotEmpty) {
        return Uri.https(
          'm.me',
          '/$xoId',
          xoUri.queryParameters.isEmpty ? null : xoUri.queryParameters,
        );
      }

      return Uri.https(
        'm.me',
        '/',
        xoUri.queryParameters.isEmpty ? null : xoUri.queryParameters,
      );
    }

    if (xoScheme == 'sgnl') {
      final Map<String, String> xoQp = xoUri.queryParameters;
      final String? xoPhone = xoQp['phone'];
      final String? xoUsername = xoQp['username'];

      if (xoPhone != null && xoPhone.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#p/${xoDigitsOnly(xoPhone)}',
        );
      }

      if (xoUsername != null && xoUsername.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#u/$xoUsername',
        );
      }

      final String xoPath = xoUri.pathSegments.join('/');
      if (xoPath.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/$xoPath',
          xoUri.queryParameters.isEmpty ? null : xoUri.queryParameters,
        );
      }

      return xoUri;
    }

    if (xoScheme == 'tel') {
      return Uri.parse('tel:${xoDigitsOnly(xoUri.path)}');
    }

    if (xoScheme == 'mailto') {
      return xoUri;
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

  Future<bool> xoOpenMailWeb(Uri xoMailto) async {
    final Uri xoGmailUri = xoGmailizeMailto(xoMailto);
    return xoOpenWeb(xoGmailUri);
  }

  Uri xoGmailizeMailto(Uri xoMailUri) {
    final Map<String, String> xoQueryParams = xoMailUri.queryParameters;

    final Map<String, String> xoParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (xoMailUri.path.isNotEmpty) 'to': xoMailUri.path,
      if ((xoQueryParams['subject'] ?? '').isNotEmpty)
        'su': xoQueryParams['subject']!,
      if ((xoQueryParams['body'] ?? '').isNotEmpty)
        'body': xoQueryParams['body']!,
      if ((xoQueryParams['cc'] ?? '').isNotEmpty)
        'cc': xoQueryParams['cc']!,
      if ((xoQueryParams['bcc'] ?? '').isNotEmpty)
        'bcc': xoQueryParams['bcc']!,
    };

    return Uri.https('mail.google.com', '/mail/', xoParams);
  }

  Future<bool> xoOpenWeb(Uri xoUri) async {
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
      debugPrint('openInAppBrowser error: $xoError; url=$xoUri');
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

  Future<bool> xoOpenExternal(Uri xoUri) async {
    try {
      return await launchUrl(
        xoUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (xoError) {
      debugPrint('openExternal error: $xoError; url=$xoUri');
      return false;
    }
  }

  void xoHandleServerSavedata(String xoSavedata) {
    debugPrint('onServerResponse savedata: $xoSavedata');

    if (xoSavedata == 'false') {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext xoContext) => const XOLuckyHunterHelpLite(),
        ),
            (Route<dynamic> xoRoute) => false,
      );
    } else if (xoSavedata == 'true') {
      // остаёмся на вебе
    }
  }

  @override
  Widget build(BuildContext context) {
    xoBindNotificationTap();

    Widget xoContent = Column(
      children: <Widget>[
        Expanded(
          child: Stack(
            children: <Widget>[
              if (xoCoverVisible)
                const Center(child: XOLoader())
              else
                Container(
                  color: Colors.black,
                  child: Stack(
                    children: <Widget>[
                      InAppWebView(
                        key: ValueKey<int>(xoWebViewKeyCounter),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          disableDefaultErrorPage: true,
                          mediaPlaybackRequiresUserGesture: false,
                          allowsInlineMediaPlayback: true,
                          allowsPictureInPictureMediaPlayback: true,
                          useOnDownloadStart: true,
                          javaScriptCanOpenWindowsAutomatically: true,
                          useShouldOverrideUrlLoading: true,
                          supportMultipleWindows: true,
                          transparentBackground: true,
                        ),
                        initialUrlRequest: URLRequest(
                          url: WebUri(xoHomeUrl),
                        ),
                        onWebViewCreated:
                            (InAppWebViewController xoController) {
                          xoWebViewController = xoController;

                          xoBosunInstance ??= XOBosunViewModel(
                            xoDeviceProfileInstance: xoDeviceProfileInstance,
                            xoAnalyticsSpyInstance: xoAnalyticsSpyInstance,
                          );

                          xoCourier ??= XOCourierService(
                            xoBosun: xoBosunInstance!,
                            xoGetWebViewController: () => xoWebViewController,
                          );

                          xoController.addJavaScriptHandler(
                            handlerName: 'onServerResponse',
                            callback: (List<dynamic> xoArgs) {
                              debugPrint(
                                  'onServerResponse raw args: $xoArgs');

                              if (xoArgs.isEmpty) return null;

                              try {
                                if (xoArgs[0] is Map) {
                                  final dynamic xoRawSaved =
                                  (xoArgs[0] as Map)['savedata'];

                                  debugPrint(
                                      "saveDATA ${xoRawSaved.toString()}");
                                  xoHandleServerSavedata(
                                      xoRawSaved?.toString() ?? '');
                                } else if (xoArgs[0] is String) {
                                  xoHandleServerSavedata(
                                      xoArgs[0] as String);
                                } else if (xoArgs[0] is bool) {
                                  xoHandleServerSavedata(
                                      (xoArgs[0] as bool).toString());
                                }
                              } catch (xoE, xoSt) {
                                debugPrint(
                                    'onServerResponse error: $xoE\n$xoSt');
                              }

                              return null;
                            },
                          );
                        },
                        onLoadStart: (
                            InAppWebViewController xoController,
                            Uri? xoUri,
                            ) async {
                          setState(() {
                            xoStartLoadTimestamp =
                                DateTime.now().millisecondsSinceEpoch;
                          });

                          final Uri? xoViewUri = xoUri;
                          if (xoViewUri != null) {
                            if (xoIsBareEmail(xoViewUri)) {
                              try {
                                await xoController.stopLoading();
                              } catch (_) {}
                              final Uri xoMailto = xoToMailto(xoViewUri);
                              await xoOpenMailWeb(xoMailto);
                              return;
                            }

                            final String xoScheme =
                            xoViewUri.scheme.toLowerCase();

                            if (xoIsBankScheme(xoViewUri)) {
                              try {
                                await xoController.stopLoading();
                              } catch (_) {}
                              await xoOpenBank(xoViewUri);
                              return;
                            }

                            if (xoScheme != 'http' && xoScheme != 'https') {
                              try {
                                await xoController.stopLoading();
                              } catch (_) {}
                            }
                          }
                        },
                        onLoadError: (
                            InAppWebViewController xoController,
                            Uri? xoUri,
                            int xoCode,
                            String xoMessage,
                            ) async {
                          final int xoNow =
                              DateTime.now().millisecondsSinceEpoch;
                          final String xoEvent =
                              'InAppWebViewError(code=$xoCode, message=$xoMessage)';

                          await xoPostStat(
                            xoEvent: xoEvent,
                            xoTimeStart: xoNow,
                            xoTimeFinish: xoNow,
                            xoUrl: xoUri?.toString() ?? '',
                            xoAppSid: xoAnalyticsSpyInstance.xoAppsFlyerUid,
                            xoFirstPageLoadTs: xoFirstPageTimestamp,
                          );
                        },
                        onReceivedError: (
                            InAppWebViewController xoController,
                            WebResourceRequest xoRequest,
                            WebResourceError xoError,
                            ) async {
                          final int xoNow =
                              DateTime.now().millisecondsSinceEpoch;
                          final String xoDescription =
                          (xoError.description ?? '').toString();
                          final String xoEvent =
                              'WebResourceError(code=$xoError, message=$xoDescription)';

                          await xoPostStat(
                            xoEvent: xoEvent,
                            xoTimeStart: xoNow,
                            xoTimeFinish: xoNow,
                            xoUrl: xoRequest.url?.toString() ?? '',
                            xoAppSid: xoAnalyticsSpyInstance.xoAppsFlyerUid,
                            xoFirstPageLoadTs: xoFirstPageTimestamp,
                          );
                        },
                        onLoadStop: (
                            InAppWebViewController xoController,
                            Uri? xoUri,
                            ) async {
                          await xoPushDeviceInfo();
                          await xoPushAppsFlyerData();

                          setState(() {
                            xoCurrentUrl = xoUri.toString();
                          });

                          Future<void>.delayed(
                            const Duration(seconds: 20),
                                () {
                              xoSendLoadedOnce(
                                xoUrl: xoCurrentUrl.toString(),
                                xoTimestart: xoStartLoadTimestamp,
                              );
                            },
                          );
                        },
                        shouldOverrideUrlLoading: (
                            InAppWebViewController xoController,
                            NavigationAction xoAction,
                            ) async {
                          final Uri? xoUri = xoAction.request.url;
                          if (xoUri == null) {
                            return NavigationActionPolicy.ALLOW;
                          }

                          if (xoIsBareEmail(xoUri)) {
                            final Uri xoMailto = xoToMailto(xoUri);
                            await xoOpenMailWeb(xoMailto);
                            return NavigationActionPolicy.CANCEL;
                          }

                          final String xoScheme =
                          xoUri.scheme.toLowerCase();

                          if (xoIsBankScheme(xoUri)) {
                            await xoOpenBank(xoUri);
                            return NavigationActionPolicy.CANCEL;
                          }

                          if ((xoScheme == 'http' || xoScheme == 'https') &&
                              xoIsBankDomain(xoUri)) {
                            await xoOpenBank(xoUri);

                            if (xoIsAdobeRedirect(xoUri)) {
                              if (context.mounted) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        XOAdobeRedirectScreen(xoUri: xoUri),
                                  ),
                                );
                              }
                              return NavigationActionPolicy.CANCEL;
                            }
                            return NavigationActionPolicy.CANCEL;
                          }

                          if (xoScheme == 'mailto') {
                            await xoOpenMailWeb(xoUri);
                            return NavigationActionPolicy.CANCEL;
                          }

                          if (xoScheme == 'tel') {
                            await launchUrl(
                              xoUri,
                              mode: LaunchMode.externalApplication,
                            );
                            return NavigationActionPolicy.CANCEL;
                          }

                          final String xoHost =
                          xoUri.host.toLowerCase();
                          final bool xoIsSocial =
                              xoHost.endsWith('facebook.com') ||
                                  xoHost.endsWith('instagram.com') ||
                                  xoHost.endsWith('twitter.com') ||
                                  xoHost.endsWith('x.com');

                          if (xoIsSocial) {
                            await xoOpenExternal(xoUri);
                            return NavigationActionPolicy.CANCEL;
                          }

                          if (xoIsPlatformLink(xoUri)) {
                            final Uri xoWebUri = xoHttpizePlatformUri(xoUri);
                            await xoOpenExternal(xoWebUri);
                            return NavigationActionPolicy.CANCEL;
                          }

                          if (xoScheme != 'http' && xoScheme != 'https') {
                            return NavigationActionPolicy.CANCEL;
                          }

                          return NavigationActionPolicy.ALLOW;
                        },
                        onCreateWindow: (
                            InAppWebViewController xoController,
                            CreateWindowAction xoRequest,
                            ) async {
                          final Uri? xoUri = xoRequest.request.url;
                          if (xoUri == null) {
                            return false;
                          }

                          if (xoIsBankScheme(xoUri) ||
                              ((xoUri.scheme == 'http' ||
                                  xoUri.scheme == 'https') &&
                                  xoIsBankDomain(xoUri))) {
                            await xoOpenBank(xoUri);
                            return false;
                          }

                          if (xoIsBareEmail(xoUri)) {
                            final Uri xoMailto = xoToMailto(xoUri);
                            await xoOpenMailWeb(xoMailto);
                            return false;
                          }

                          final String xoScheme =
                          xoUri.scheme.toLowerCase();

                          if (xoScheme == 'mailto') {
                            await xoOpenMailWeb(xoUri);
                            return false;
                          }

                          if (xoScheme == 'tel') {
                            await launchUrl(
                              xoUri,
                              mode: LaunchMode.externalApplication,
                            );
                            return false;
                          }

                          final String xoHost =
                          xoUri.host.toLowerCase();
                          final bool xoIsSocial =
                              xoHost.endsWith('facebook.com') ||
                                  xoHost.endsWith('instagram.com') ||
                                  xoHost.endsWith('twitter.com') ||
                                  xoHost.endsWith('x.com');

                          if (xoIsSocial) {
                            await xoOpenExternal(xoUri);
                            return false;
                          }

                          if (xoIsPlatformLink(xoUri)) {
                            final Uri xoWebUri = xoHttpizePlatformUri(xoUri);
                            await xoOpenExternal(xoWebUri);
                            return false;
                          }

                          if (xoScheme == 'http' || xoScheme == 'https') {
                            xoController.loadUrl(
                              urlRequest: URLRequest(
                                url: WebUri(xoUri.toString()),
                              ),
                            );
                          }

                          return false;
                        },
                        onDownloadStartRequest: (
                            InAppWebViewController xoController,
                            DownloadStartRequest xoReq,
                            ) async {
                          await xoOpenExternal(xoReq.url);
                        },
                      ),
                      Visibility(
                        visible: !xoVeilVisible,
                        child: const Center(child: XOLoader()),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.expand(
          child: ColoredBox(
            color: Colors.black,
            child: xoContent,
          ),
        ),
      ),
    );
  }

  bool xoIsAdobeRedirect(Uri xoUri) {
    final String xoHost = xoUri.host.toLowerCase();
    return xoHost == 'c00.adobe.com';
  }
}

// ---------------------- Экран для c00.adobe.com ----------------------

class XOAdobeRedirectScreen extends StatelessWidget {
  final Uri xoUri;

  const XOAdobeRedirectScreen({super.key, required this.xoUri});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: const Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                "Go to the App Store and download the app.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                ),
              ),
              SizedBox(height: 24),
              SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}


// ============================================================================
// main()
// ============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(xoFcmBackgroundHandler);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  tz_data.initializeTimeZones();

  runApp(
    MultiProvider(
      providers: <SingleChildWidget>[
        ChangeNotifierProvider<XOLoaderState>(
          create: (_) => XOLoaderState(),
        ),
      ],
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: XOHall(),
      ),
    ),
  );
}

// ============================================================================
// Заглушка AppGameScreen, чтобы код собирался
// ============================================================================

class AppGameScreen extends StatelessWidget {
  const AppGameScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Game Screen'),
      ),
      body: const Center(
        child: Text('Here is your game'),
      ),
    );
  }
}