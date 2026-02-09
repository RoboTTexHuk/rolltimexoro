import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'main.dart';

class XOLuckyHunterHelpLite extends StatefulWidget {
  const XOLuckyHunterHelpLite({super.key});

  @override
  State<XOLuckyHunterHelpLite> createState() => _XOLuckyHunterHelpLiteState();
}

class _XOLuckyHunterHelpLiteState extends State<XOLuckyHunterHelpLite> {
  InAppWebViewController? xoLuckyHunterWebViewController;
  bool xoLuckyHunterLoading = true;

  Future<bool> xoLuckyHunterGoBackInWebViewIfPossible() async {
    if (xoLuckyHunterWebViewController == null) return false;
    try {
      final bool xoLuckyHunterCanBack =
      await xoLuckyHunterWebViewController!.canGoBack();
      if (xoLuckyHunterCanBack) {
        await xoLuckyHunterWebViewController!.goBack();
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        final bool xoLuckyHunterHandled =
        await xoLuckyHunterGoBackInWebViewIfPossible();
        return xoLuckyHunterHandled ? false : false;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          elevation: 0,
        ),
        body: SafeArea(
          child: Stack(
            children: <Widget>[
              InAppWebView(
                initialFile: 'assets/xo.html',
                initialSettings:  InAppWebViewSettings(
                  javaScriptEnabled: true,
                  supportZoom: false,
                  disableHorizontalScroll: false,
                  disableVerticalScroll: false,
                  transparentBackground: true,
                  mediaPlaybackRequiresUserGesture: false,
                  disableDefaultErrorPage: true,
                  allowsInlineMediaPlayback: true,
                  allowsPictureInPictureMediaPlayback: true,
                  useOnDownloadStart: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                ),
                onWebViewCreated:
                    (InAppWebViewController xoLuckyHunterController) {
                  xoLuckyHunterWebViewController = xoLuckyHunterController;
                },
                onLoadStart: (
                    InAppWebViewController xoLuckyHunterController,
                    Uri? xoLuckyHunterUrl,
                    ) =>
                    setState(() => xoLuckyHunterLoading = true),
                onLoadStop: (
                    InAppWebViewController xoLuckyHunterController,
                    Uri? xoLuckyHunterUrl,
                    ) async =>
                    setState(() => xoLuckyHunterLoading = false),
                onLoadError: (
                    InAppWebViewController xoLuckyHunterController,
                    Uri? xoLuckyHunterUrl,
                    int xoLuckyHunterCode,
                    String xoLuckyHunterMessage,
                    ) =>
                    setState(() => xoLuckyHunterLoading = false),
              ),
              if (xoLuckyHunterLoading)
                const Positioned.fill(
                  child: Center(child: XOLoader())
                ),
            ],
          ),
        ),
      ),
    );
  }
}

