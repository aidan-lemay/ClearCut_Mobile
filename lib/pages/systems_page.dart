import 'package:clearcut_mobile/main.dart';
import 'package:clearcut_mobile/pages/advancedsearch_page.dart';
import 'package:clearcut_mobile/pages/favorites_page.dart';
import 'package:clearcut_mobile/pages/info_page.dart';
import 'package:clearcut_mobile/pages/talkgroups_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class MySystemsPage extends StatefulWidget {
  @override
  State<MySystemsPage> createState() => _MySystemsPageState();
}

class _MySystemsPageState extends State<MySystemsPage> {
  var selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    Widget page;
    switch (selectedIndex) {
      case 0:
        page = SystemsPage();
      case 1:
        page = FavoritesPage();
      case 2:
        page = InfoPage();
      case 3:
        page = AdvancedSearch();
      default:
        throw UnimplementedError('No widget for $selectedIndex');
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Systems'),
        leading: Builder(
          builder: (context) => IconButton(
            icon: Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
              ),
              child: Text(
                'Clearcut Mobile',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontSize: 24,
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.storage_rounded),
              title: Text('Systems'),
              onTap: () {
                setState(() {
                  selectedIndex = 0;
                });
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.favorite),
              title: Text('Favorites'),
              onTap: () {
                setState(() {
                  selectedIndex = 1;
                });
                Navigator.pop(context);
              },
            ),
            // ListTile(
            //   leading: Icon(Icons.code),
            //   title: Text('Advanced Search'),
            //   onTap: () {
            //     setState(() {
            //       selectedIndex = 3;
            //     });
            //     Navigator.pop(context);
            //   },
            // ),
            ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Info'),
              onTap: () {
                setState(() {
                  selectedIndex = 2;
                });
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
      body: page,
    );
  }
}

class SystemsPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (appState.apiData != null)
            ...appState.apiData!.map((x) {
              return Padding(
                padding: const EdgeInsets.all(10.0),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: Colors.white, width: 1),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  contentPadding: EdgeInsets.all(3),
                  horizontalTitleGap: 10,
                  title: Text(x['name']),
                  onTap: () {
                    appState.setCurrent(x);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => TalkgroupsPage(),
                      ),
                    );
                  },
                ),
              );
            }).toList(),
          if (appState.apiData == null) CircularProgressIndicator(),
        ],
      ),
    );
  }
}
