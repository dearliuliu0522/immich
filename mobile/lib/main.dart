import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:auto_route/auto_route.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/generated/intl_keys.g.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/platform/background_worker_lock_api.g.dart';
import 'package:immich_mobile/providers/app_life_cycle.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/share_intent_upload.provider.dart';
import 'package:immich_mobile/providers/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/background.service.dart';
import 'package:immich_mobile/services/deep_link.service.dart';
import 'package:immich_mobile/services/local_notification.service.dart';
import 'package:immich_mobile/theme/dynamic_theme.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/utils/cache/widgets_binding.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/utils/http_ssl_options.dart';
import 'package:immich_mobile/utils/licenses.dart';
import 'package:immich_mobile/utils/migration.dart';
import 'package:immich_mobile/wm_executor.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:logging/logging.dart';
import 'package:timezone/data/latest.dart';

void main() async {
  ImmichWidgetsBinding();
  // 后台 Worker 锁，防止后台任务重复启动
  unawaited(BackgroundWorkerLockService(BackgroundWorkerLockApi()).lock());
  // 数据库初始化。isar是本地数据库，drift是SQL，logDb是日志
  final (isar, drift, logDb) = await Bootstrap.initDB();
  // Domain 层初始化
  await Bootstrap.initDomain(isar, drift, logDb);
  // App 全局初始化
  await initApp();
  // Warm-up isolate pool for worker manager
  // 创建 isolate 池
  await workerManagerPatch.init(dynamicSpawning: true, isolatesCount: max(Platform.numberOfProcessors - 1, 5));
  // 数据库 migration
  await migrateDatabaseIfNeeded(isar, drift);
  // SSL 配置
  HttpSSLOptions.apply();

  runApp(
    // ProviderScope 注入
    ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(isar),
        isarProvider.overrideWithValue(isar),
        driftProvider.overrideWith(driftOverride(drift)),
      ],
      child: const MainWidget(),
    ),
  );
}

Future<void> initApp() async {
  await EasyLocalization.ensureInitialized();
  // 日期国际化
  await initializeDateFormatting();

  if (Platform.isAndroid) {
    try {
      // Android 高刷新率
      await FlutterDisplayMode.setHighRefreshRate();
      dPrint(() => "Enabled high refresh mode");
    } catch (e) {
      dPrint(() => "Error setting high refresh rate: $e");
    }
  }

  // 动态主题
  await DynamicTheme.fetchSystemPalette();

  final log = Logger("ImmichErrorLogger");

  // 全局 Error 捕获
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    log.severe(
      'FlutterError - Catch all',
      "${details.toString()}\nException: ${details.exception}\nLibrary: ${details.library}\nContext: ${details.context}",
      details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    log.severe('PlatformDispatcher - Catch all', error, stack);
    return true;
  };

  // timezone 初始化
  initializeTimeZones();

  // FileDownloader 初始化
  await FileDownloader().configure(
    // maxConcurrent: 6, maxConcurrentByHost(server):6, maxConcurrentByGroup: 3

    // On Android, if files are larger than 256MB, run in foreground service
    globalConfig: [(Config.holdingQueue, (6, 6, 3)), (Config.runInForegroundIfFileLargerThan, 256)],
  );

  await FileDownloader().trackTasksInGroup(kDownloadGroupLivePhoto, markDownloadedComplete: false);

  unawaited(FileDownloader().trackTasks());

  // License 注册
  LicenseRegistry.addLicense(() async* {
    for (final license in nonPubLicenses.entries) {
      yield LicenseEntryWithLineBreaks([license.key], license.value);
    }
  });
}

class ImmichApp extends ConsumerStatefulWidget {
  const ImmichApp({super.key});

  @override
  ImmichAppState createState() => ImmichAppState();
}

class ImmichAppState extends ConsumerState<ImmichApp> with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 生命周期监听。把 Flutter lifecycle 转发到 Riverpod
    switch (state) {
      case AppLifecycleState.resumed:
        dPrint(() => "[APP STATE] resumed");
        ref.read(appStateProvider.notifier).handleAppResume();
        break;
      case AppLifecycleState.inactive:
        dPrint(() => "[APP STATE] inactive");
        ref.read(appStateProvider.notifier).handleAppInactivity();
        break;
      case AppLifecycleState.paused:
        dPrint(() => "[APP STATE] paused");
        ref.read(appStateProvider.notifier).handleAppPause();
        break;
      case AppLifecycleState.detached:
        dPrint(() => "[APP STATE] detached");
        ref.read(appStateProvider.notifier).handleAppDetached();
        break;
      case AppLifecycleState.hidden:
        dPrint(() => "[APP STATE] hidden");
        ref.read(appStateProvider.notifier).handleAppHidden();
        break;
    }
  }

  Future<void> initApp() async {
    WidgetsBinding.instance.addObserver(this);

    // Draw the app from edge to edge
    // System UI 初始化
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));

    // Sets the navigation bar color
    SystemUiOverlayStyle overlayStyle = const SystemUiOverlayStyle(systemNavigationBarColor: Colors.transparent);
    // Android SDK 兼容
    if (Platform.isAndroid) {
      // Android 8 不支持透明 navigation bar
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt <= 26) {
        overlayStyle = context.isDarkTheme ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light;
      }
    }
    SystemChrome.setSystemUIOverlayStyle(overlayStyle);
    // 本地通知初始化
    await ref.read(localNotificationService).setup();
  }

  Future<DeepLink> _deepLinkBuilder(PlatformDeepLink deepLink) async {
    final deepLinkHandler = ref.read(deepLinkServiceProvider);
    final currentRouteName = ref.read(currentRouteNameProvider.notifier).state;

    final isColdStart = currentRouteName == null || currentRouteName == SplashScreenRoute.name;

    if (deepLink.uri.scheme == "immich") {
      final proposedRoute = await deepLinkHandler.handleScheme(deepLink, ref, isColdStart);

      return proposedRoute;
    }

    if (deepLink.uri.host == "my.immich.app") {
      final proposedRoute = await deepLinkHandler.handleMyImmichApp(deepLink, ref, isColdStart);

      return proposedRoute;
    }

    return DeepLink.path(deepLink.path);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    Intl.defaultLocale = context.locale.toLanguageTag();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      configureFileDownloaderNotifications();
    });
  }

  @override
  initState() {
    super.initState();
    initApp().then((_) => dPrint(() => "App Init Completed"));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // needs to be delayed so that EasyLocalization is working
      // Background Service 切换
      if (Store.isBetaTimelineEnabled) {
        ref.read(backgroundServiceProvider).disableService();
        ref.read(backgroundWorkerFgServiceProvider).enable();
        if (Platform.isAndroid) {
          ref
              .read(backgroundWorkerFgServiceProvider)
              .saveNotificationMessage(
                IntlKeys.uploading_media.t(),
                IntlKeys.backup_background_service_default_notification.t(),
              );
        }
      } else {
        ref.read(backgroundWorkerFgServiceProvider).disable();
        ref.read(backgroundServiceProvider).resumeServiceIfEnabled();
      }
    });

    ref.read(shareIntentUploadProvider.notifier).init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void reassemble() {
    if (kDebugMode) {
      NetworkRepository.reset();
    }
    super.reassemble();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final immichTheme = ref.watch(immichThemeProvider);

    return ProviderScope(
      overrides: [localeProvider.overrideWithValue(context.locale)],
      child: MaterialApp.router(
        title: 'Immich',
        debugShowCheckedModeBanner: true,
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        themeMode: ref.watch(immichThemeModeProvider),
        darkTheme: getThemeData(colorScheme: immichTheme.dark, locale: context.locale),
        theme: getThemeData(colorScheme: immichTheme.light, locale: context.locale),
        builder: (context, child) => ImmichTranslationProvider(
          translations: ImmichTranslations(
            submit: "submit".t(context: context),
            password: "password".t(context: context),
          ),
          child: ImmichThemeProvider(colorScheme: context.colorScheme, child: child!),
        ),
        routerConfig: router.config(
          deepLinkBuilder: _deepLinkBuilder,
          navigatorObservers: () => [AppNavigationObserver(ref: ref)],
        ),
      ),
    );
  }
}

class MainWidget extends StatelessWidget {
  const MainWidget({super.key});

  @override
  Widget build(BuildContext context) {
    // 国际化 root wrapper
    return EasyLocalization(
      supportedLocales: locales.values.toList(),
      path: translationsPath,
      useFallbackTranslations: true,
      fallbackLocale: locales.values.first,
      assetLoader: const CodegenLoader(),
      child: const ImmichApp(),
    );
  }
}
