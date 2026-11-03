import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

const feedbackEmail = 'clearcutfeedback@aidanlemay.com';

final Uri feedbackEmailUri = Uri(
  scheme: 'mailto',
  path: feedbackEmail,
  query: 'subject=Clearcut%20Mobile%20Feedback%20Request',
);

class InfoPage extends StatelessWidget {
  /// Opens [url], falling back to copying [fallbackText] to the clipboard.
  ///
  /// This tries the launch directly rather than checking canLaunchUrl first,
  /// which needs a matching manifest entry to work on Android 11 and later.
  Future<void> _open(
    BuildContext context,
    Uri url, {
    required String fallbackText,
    required String fallbackMessage,
  }) async {
    var opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    } on PlatformException catch (error) {
      print('Error opening $url: $error');
    }
    if (opened) return;

    await Clipboard.setData(ClipboardData(text: fallbackText));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(fallbackMessage)),
    );
  }

  @override
  Widget build(BuildContext context) {
    var github = Uri.parse("https://github.com/aidan-lemay/ClearCut_Mobile");
    var mysite = Uri.parse("https://aidanlemay.com");
    const linkFallback = "Couldn't open link, copied to clipboard instead!";

    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Welcome to Clearcut Mobile!",
              style: TextStyle(fontSize: 32),
              textAlign: TextAlign.center,
            ),
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: Text(
                "Created by Aidan LeMay",
                style: TextStyle(fontSize: 16),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: ElevatedButton(
                onPressed: () => _open(
                  context,
                  github,
                  fallbackText: github.toString(),
                  fallbackMessage: linkFallback,
                ),
                child: Text('Check Out This Project on GitHub!'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: ElevatedButton(
                onPressed: () => _open(
                  context,
                  mysite,
                  fallbackText: mysite.toString(),
                  fallbackMessage: linkFallback,
                ),
                child: Text('Check Out My Website!'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: ElevatedButton(
                onPressed: () => _open(
                  context,
                  feedbackEmailUri,
                  fallbackText: feedbackEmail,
                  fallbackMessage:
                      "Couldn't open email app, copied address to clipboard instead!",
                ),
                child: Text('Have Feedback? Email Me!'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
