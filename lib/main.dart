import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DigiLoggerApp());
}

class DigiLoggerApp extends StatelessWidget {
  const DigiLoggerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'دیجی‌کالا لاگر',
      debugShowCheckedModeBanner: false,
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
      theme: ThemeData(
        useMaterial3: true,
        primaryColor: const Color(0xFFEF394E),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFEF394E)),
      ),
      home: const DigikalaViewerScreen(),
    );
  }
}

class DigikalaViewerScreen extends StatefulWidget {
  const DigikalaViewerScreen({super.key});

  @override
  State<DigikalaViewerScreen> createState() => _DigikalaViewerScreenState();
}

class _DigikalaViewerScreenState extends State<DigikalaViewerScreen> {
  late final WebViewController _controller;
  File? _logFile;
  int _capturedRequestsCount = 0;
  bool _isLoadingPage = true;

  // اسکریپت رهگیری درخواست‌ها و ریسپانس‌های شبکه
  static const String _interceptorScript = """
    (function() {
      if (window.__digiLoggerInstalled) return;
      window.__digiLoggerInstalled = true;

      function shouldLog(url) {
        if (!url) return false;
        var u = url.toLowerCase();
        
        // حذف تمام فایل‌های استاتیک، عکس، مدیا، فونت، آیکون و اسکریپت‌ها
        if (u.match(/\\.(png|jpg|jpeg|gif|webp|svg|ico|css|woff|woff2|ttf|eot|js|map|mp4|webm)(\\?.*)?\$/)) {
          return false;
        }

        // حذف پلتفرم‌های ترکینگ و تبلیغات
        if (u.includes('google-analytics') || u.includes('googletagmanager') || 
            u.includes('sentry') || u.includes('clarity.ms') || 
            u.includes('hotjar') || u.includes('yandex') || u.includes('metric')) {
          return false;
        }

        // شکار فقط ریکوئست‌های با ارزش (APIهای دیجی‌کالا، لاگین، احراز هویت، سبد خرید، کاتالوگ و کاربر)
        return true;
      }

      function forwardLog(data) {
        try {
          if (window.DigiLogBridge) {
            window.DigiLogBridge.postMessage(JSON.stringify(data));
          }
        } catch (e) {}
      }

      // ۱. رهگیری Fetch API
      var rawFetch = window.fetch;
      window.fetch = async function() {
        var args = Array.from(arguments);
        var input = args[0];
        var init = args[1] || {};
        var url = typeof input === 'string' ? input : (input ? input.url : '');
        var method = (init.method || (input && input.method) || 'GET').toUpperCase();

        if (!shouldLog(url)) {
          return rawFetch.apply(this, args);
        }

        var headers = init.headers || (input && input.headers) || {};
        var body = init.body || null;

        try {
          var response = await rawFetch.apply(this, args);
          var clonedResponse = response.clone();
          var resText = '';
          try {
            resText = await clonedResponse.text();
          } catch(e) {
            resText = '[Unreadable Binary/Stream Body]';
          }

          forwardLog({
            protocol: 'FETCH',
            url: url,
            method: method,
            requestHeaders: headers,
            requestBody: body,
            statusCode: response.status,
            responseBody: resText
          });

          return response;
        } catch (err) {
          forwardLog({
            protocol: 'FETCH_ERROR',
            url: url,
            method: method,
            requestHeaders: headers,
            requestBody: body,
            error: err.toString()
          });
          throw err;
        }
      };

      // ۲. رهگیری XMLHttpRequest (AJAX)
      var rawOpen = XMLHttpRequest.prototype.open;
      var rawSend = XMLHttpRequest.prototype.send;
      var rawSetHeader = XMLHttpRequest.prototype.setRequestHeader;

      XMLHttpRequest.prototype.open = function(method, url) {
        this._reqUrl = url;
        this._reqMethod = method ? method.toUpperCase() : 'GET';
        this._reqHeaders = {};
        return rawOpen.apply(this, arguments);
      };

      XMLHttpRequest.prototype.setRequestHeader = function(header, value) {
        if (this._reqHeaders) {
          this._reqHeaders[header] = value;
        }
        return rawSetHeader.apply(this, arguments);
      };

      XMLHttpRequest.prototype.send = function(body) {
        var self = this;
        var url = self._reqUrl;

        if (shouldLog(url)) {
          self._reqBody = body;
          self.addEventListener('load', function() {
            forwardLog({
              protocol: 'XHR',
              url: url,
              method: self._reqMethod,
              requestHeaders: self._reqHeaders,
              requestBody: self._reqBody,
              statusCode: self.status,
              responseBody: self.responseText
            });
          });
        }
        return rawSend.apply(this, arguments);
      };
    })();
  """;

  @override
  void initState() {
    super.initState();
    _setupLogFile();
    _initWebViewController();
  }

  Future<void> _setupLogFile() async {
    final dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/digikala_requests_log.txt');
    if (!await _logFile!.exists()) {
      await _logFile!.create(recursive: true);
    }
  }

  void _initWebViewController() {
    final WebViewController controller = WebViewController();

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (controller.platform as AndroidWebViewController).setMediaPlaybackRequiresUserGesture(false);
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent("Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
      ..addJavaScriptChannel(
        'DigiLogBridge',
        onMessageReceived: (JavaScriptMessage msg) {
          _writeLogRecord(msg.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) async {
            setState(() => _isLoadingPage = true);
            await controller.runJavaScript(_interceptorScript);
          },
          onPageFinished: (String url) async {
            setState(() => _isLoadingPage = false);
            await controller.runJavaScript(_interceptorScript);
          },
        ),
      )
      ..loadRequest(Uri.parse('https://www.digikala.com/'));

    _controller = controller;
  }

  Future<void> _writeLogRecord(String jsonRaw) async {
    if (_logFile == null) await _setupLogFile();

    try {
      final Map<String, dynamic> item = json.decode(jsonRaw);
      final timestamp = DateTime.now().toLocal().toString();

      final buffer = StringBuffer();
      buffer.writeln("================================================================================");
      buffer.writeln("[$timestamp] [${item['protocol']}] ${item['method']} ${item['url']}");
      buffer.writeln("کد وضعیت (Status Code): ${item['statusCode'] ?? item['error'] ?? 'نامشخص'}");
      buffer.writeln("\n--- هدرهای درخواست (Request Headers) ---");
      buffer.writeln(item['requestHeaders'] != null ? const JsonEncoder.withIndent('  ').convert(item['requestHeaders']) : "ندارد");
      buffer.writeln("\n--- بدنه ارسالی (Request Body) ---");
      buffer.writeln(item['requestBody'] ?? "خالی");
      buffer.writeln("\n--- بدنه پاسخ دریافتی (Response Body) ---");
      buffer.writeln(item['responseBody'] ?? "خالی");
      buffer.writeln("================================================================================\n");

      await _logFile!.writeAsString(buffer.toString(), mode: FileMode.append, flush: true);

      if (mounted) {
        setState(() {
          _capturedRequestsCount++;
        });
      }
    } catch (_) {}
  }

  Future<void> _shareLogFile() async {
    if (_logFile != null && await _logFile!.exists()) {
      final size = await _logFile!.length();
      if (size == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('هنوز درخواستی ذخیره نشده است.')),
        );
        return;
      }
      await Share.shareXFiles([XFile(_logFile!.path)], text: 'لاگ‌های استخراج شده دیجی‌کالا');
    }
  }

  Future<void> _clearLogs() async {
    if (_logFile != null && await _logFile!.exists()) {
      await _logFile!.writeAsString("");
      setState(() {
        _capturedRequestsCount = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('فایل لاگ خالی شد.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 2,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'دیجی‌کالا اسنیفر',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black82),
            ),
            Text(
              'لاگ‌های ذخیره شده: $_capturedRequestsCount',
              style: const TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share, color: Color(0xFFEF394E)),
            tooltip: 'ارسال / ذخیره فایل متنی',
            onPressed: _shareLogFile,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.grey),
            tooltip: 'پاک کردن لاگ‌ها',
            onPressed: _clearLogs,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.black82),
            tooltip: 'بارگذاری مجدد صفحه',
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoadingPage)
            const LinearProgressIndicator(
              color: Color(0xFFEF394E),
              backgroundColor: Colors.transparent,
            ),
        ],
      ),
    );
  }
}
