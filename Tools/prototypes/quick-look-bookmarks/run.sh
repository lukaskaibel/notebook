#!/bin/zsh
# run.sh <kind|none> <out.png>: gives the test build's Quick Look extension only that kind of bookmark to the note's
# picture, previews the note in qlhost, and prints what the extension logged.
S=/private/tmp/claude-501/-Users-lukas-Developement-notes-app--claude-worktrees-quick-look-notebooks-4d596e/2db51a8d-0c90-4166-8feb-03b9f92b35d1/scratchpad
ID=com.lukaskbl.NotebookQLTest.QuickLook
PREFS=$HOME/Library/Containers/$ID/Data/Library/Preferences/$ID
NOTE="$HOME/NotebookQLProto/Travel/Kyoto trip.qlproto"
PICTURE="$HOME/NotebookQLProto/Travel/.assets/torii.png"

pkill -f "dd-proto/Build/Products/Debug/Notebook.app/Contents/PlugIns/NotebookQuickLook.appex" 2>/dev/null
for k in document app plain folder log; do defaults delete "$PREFS" bm.$k 2>/dev/null; done
MAKER=$HOME/Library/Containers/com.lukaskbl.qlproto.bookmarkmaker/Data/Library/Preferences/com.lukaskbl.qlproto.bookmarkmaker
if [[ $1 == maker ]]; then
  # The plain bookmark the sandboxed BookmarkMaker made, as the folder bookmark.
  defaults write "$PREFS" bm.folder -data "$(defaults read "$MAKER" plain)"
elif [[ $1 != none ]]; then
  hex=$("$S/bookmarks/makebookmarks" "$NOTE" "$PICTURE" "$HOME/NotebookQLProto" | awk -v k="$1" '$1 == k { print $2 }')
  defaults write "$PREFS" bm.$1 -data "$hex"
fi
"$S/qlhost/qlhost" "$NOTE" "$2" 6
sleep 1
echo "--- extension log ($1)"
defaults read "$PREFS" bm.log 2>/dev/null || echo "(no log)"
