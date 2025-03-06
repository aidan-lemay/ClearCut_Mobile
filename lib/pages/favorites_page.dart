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
              onPressed: () async {
                bool? confirmDelete = await showDialog(
                  context: context,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      title: Text("Confirm Deletion"),
                      content: Text(
                          "Are you sure you want to remove this favorite?"),
                      actions: [
                        TextButton(
                          onPressed: () {
                            Navigator.of(context).pop(false); // Cancel deletion
                          },
                          child: Text("Cancel"),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.of(context).pop(true); // Confirm deletion
                          },
                          child: Text("Delete"),
                        ),
                      ],
                    );
                  },
                );

                if (confirmDelete == true) {
                  appState.removeFavorite(
                      favorite['systemId'], favorite['talkgroups']);
                }
              },
              icon: Icon(Icons.delete)),
        );
      },
    );
  }
}
