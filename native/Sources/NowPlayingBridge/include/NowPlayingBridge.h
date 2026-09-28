#ifndef NOW_PLAYING_BRIDGE_H
#define NOW_PLAYING_BRIDGE_H

/// MenuSprite's Now Playing adapter. It is never linked into the app: MenuSprite starts
/// `/usr/bin/perl`, whose loader installs this function as a perl subroutine and calls it. The two
/// arguments are perl's (interpreter, CV) and are ignored.
///
/// The function watches MediaRemote until standard input closes, writing one JSON reply per line to
/// standard output and reading one JSON command per line from standard input.
__attribute__((visibility("default")))
void menusprite_now_playing_watch(void *interpreter, void *cv);

#endif
