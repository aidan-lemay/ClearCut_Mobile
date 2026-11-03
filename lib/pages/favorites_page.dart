import 'package:clearcut_mobile/main.dart';
import 'package:clearcut_mobile/pages/listener_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// The app bar's favorites shortcut, shown on every page.
class FavoritesToggleButton extends StatelessWidget {
  final bool isShowingFavorites;
  final VoidCallback onPressed;

  FavoritesToggleButton({
    required this.isShowingFavorites,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(isShowingFavorites ? Icons.favorite : Icons.favorite_border),
      tooltip: 'Favorites',
      onPressed: onPressed,
    );
  }
}

class FavoritesPage extends StatelessWidget {
  /// Whether opening a favorite replaces the current page instead of going on
  /// top of it.
  final bool replacePageOnOpen;

  FavoritesPage({this.replacePageOnOpen = false});

  void _open(BuildContext context, Map<String, dynamic> favorite) {
    final route = MaterialPageRoute(
      builder: (context) => ListenerPage(
        selectedTalkgroups: favorite['talkgroups'],
        currentSystem: favorite['systemId'],
      ),
    );
    if (replacePageOnOpen) {
      Navigator.pushReplacement(context, route);
    } else {
      Navigator.push(context, route);
    }
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();

    if (appState.favorites.isEmpty) {
      return Center(
        child: Text('No favorites yet.'),
      );
    }

    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: appState.favorites.length,
      // ignore: deprecated_member_use
      onReorder: appState.moveFavorite, // Works on older Flutter versions too
      itemBuilder: (context, index) {
        final favorite = appState.favorites[index];
        final talkgroupNames =
            favorite['talkgroups'].map((tg) => tg['name']).join(', ');
        final talkgroupIds = favorite['talkgroups'].map((tg) => tg['id']);

        return ListTile(
          key: ValueKey('${favorite['systemId']}:${talkgroupIds.join(',')}'),
          leading: ReorderableDragStartListener(
            index: index,
            child: Icon(Icons.drag_handle),
          ),
          title: Text(talkgroupNames),
          onTap: () => _open(context, favorite),
          trailing: IconButton(
              tooltip: 'Remove favorite',
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
