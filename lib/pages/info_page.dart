import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

class InfoPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var github = Uri.parse("https://github.com/aidan-lemay/ClearCut_Mobile");
    var mysite = Uri.parse("https://aidanlemay.com");
    final Uri emailUri = Uri(
      scheme: 'mailto',
      path:
          'clearcutfeedback@aidanlemay.com', // Replace with your email address
      query: Uri.encodeQueryComponent(
          'subject=Clearcut Mobile Feedback Request'), // Optional subject and body
    );

    return Column(
      mainAxisAlignment: MainAxisAlignment.center, // Center content vertically
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
            onPressed: () async {
              if (await canLaunchUrl(github)) {
                await launchUrl(github);
              } else {
                await Clipboard.setData(ClipboardData(text: github.toString()));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        "Couldn't open link, copied to clipboard instead!"),
                  ),
                );
              }
            },
            child: Text('Check Out This Project on GitHub!'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: ElevatedButton(
            onPressed: () async {
              if (await canLaunchUrl(mysite)) {
                await launchUrl(mysite);
              } else {
                await Clipboard.setData(ClipboardData(text: mysite.toString()));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        "Couldn't open link, copied to clipboard instead!"),
                  ),
                );
              }
            },
            child: Text('Check Out My Website!'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: ElevatedButton(
            onPressed: () async {
              if (await canLaunchUrl(emailUri)) {
                await launchUrl(emailUri);
              } else {
                await Clipboard.setData(
                    ClipboardData(text: emailUri.toString()));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      "Couldn't open email app, copied address to clipboard instead!",
                    ),
                  ),
                );
              }
            },
            child: Text('Have Feedback? Email Me!'),
          ),
        ),
      ],
    );
  }
}
