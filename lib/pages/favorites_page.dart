import 'package:clearcut_mobile/main.dart';
import 'package:clearcut_mobile/pages/listener_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class FavoritesPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();

    if (appState.favorites.isEmpty) {
      return Center(
        child: Text('No favorites yet.'),
      );
    }

    return ListView.builder(
      itemCount: appState.favorites.length,
      itemBuilder: (context, index) {
        final favorite = appState.favorites[index];
        final talkgroupNames =
            favorite['talkgroups'].map((tg) => tg['name']).join(', ');

        return ListTile(
          leading: Icon(Icons.favorite),
          title: Text(talkgroupNames),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ListenerPage(
                  selectedTalkgroups: favorite['talkgroups'],
                  currentSystem: favorite['systemId'],
                ),
              ),
            );
          },
          trailing: IconButton(
              onPressed: () {
                appState.removeFavorite(
                    favorite['systemId'], favorite['talkgroups']);
              },
              icon: Icon(Icons.delete)),
        );
      },
    );
  }
}
