/*---------------------------------------------------------------------------------------------
*  Copyright (c) nt4f04und. All rights reserved.
*  Licensed under the BSD-style license. See LICENSE in the project root for license information.
*--------------------------------------------------------------------------------------------*/

import 'dart:async';

import 'package:async/async.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sweyer/sweyer.dart';

import 'package:sweyer/api.dart' as API;

class ContentState {
  ContentState();

  /// Current id of playing song
  int _currentSongId;

  /// A general art color change the UI
  Color _currentArtColor;

  /// Cancelable operation for getting the art color
  CancelableOperation _thiefOperation;

  Map<PlaylistType, Playlist> _playlists = {};

  /// What playlist is now playing?
  PlaylistType _currentPlaylistType = PlaylistType.global;

  /// What playlist was before shuffling
  PlaylistType _playlistTypeBeforeShuffle = PlaylistType.global;

  /// Sort feature
  SortFeature _currentSortFeature = SortFeature.date;

  //****************** Getters *****************************************************
  /// Get current playing song (always being searched in globalPlaylist)
  Song get currentSong {
    return _playlists[PlaylistType.global].getSongById(_currentSongId) ??
        _playlists[PlaylistType.global].songs[0];
  }

  /// Get current playing id
  int get currentSongId {
    return _currentSongId;
  }

  Color get currentArtColor => _currentArtColor;

  PlaylistType get currentPlaylistType => _currentPlaylistType;
  Playlist get currentPlaylist => _playlists[_currentPlaylistType];
  Playlist getPlaylist(PlaylistType playlistType) => _playlists[playlistType];

  SortFeature get currentSortFeature => _currentSortFeature;

  //****************** Setters *****************************************************
  /// Changes current song id and emits change event
  /// This allows to change the current id visually, separately from the player
  void changeSong(int songId) {
    _currentSongId = songId;
    emitSongChange(currentSong);
  }

  //****************** Methods *****************************************************
  /// Returns a [currentSong] index in current playlist (by default)
  int get currentSongIndex =>
      _playlists[_currentPlaylistType].getSongIndexById(_currentSongId);

  //****************** Streams *****************************************************
  /// Controller for stream of playlist changes
  StreamController<PlaylistType> _playlistChangeStreamController =
      StreamController<PlaylistType>.broadcast();

  /// Controller for stream of song changes
  StreamController<Song> _songChangeStreamController =
      StreamController<Song>.broadcast();

  /// Controller for stream of song changes
  StreamController<Color> _artColorChangeStreamController =
      StreamController<Color>.broadcast();

  /// A stream of changes on playlist
  Stream<PlaylistType> get onPlaylistListChange =>
      _playlistChangeStreamController.stream;

  /// A stream of changes on song
  Stream<Song> get onSongChange => _songChangeStreamController.stream;

  /// A stream of changes on art color
  Stream<Color> get onArtColorChange => _artColorChangeStreamController.stream;

  /// Emit event to [onPlaylistListChange]
  ///
  /// Should be only called when user can see playlist change, i.e. songs sort.
  /// Shouldn't be called, e.g. on tile click, when playlist changes, but user can't actually see it
  ///
  /// Parameter [playlistType] denotes preferred update scope, this means e.g. that if [PlaylistType.searched] changes, [ListView] dependant on [PlaylistType.global] shouldn't get any updates
  void emitPlaylistChange([PlaylistType playlistType = PlaylistType.global]) {
    _playlistChangeStreamController.add(playlistType);
  }

  /// Emits song change event
  void emitSongChange(Song song) {
    _songChangeStreamController.add(song);
  }

  /// Emits art color change event
  void emitArtColorChange(Color color) {
    _artColorChangeStreamController.add(color);
  }

  void dispose() {
    _playlistChangeStreamController.close();
    _artColorChangeStreamController.close();
    _songChangeStreamController.close();
  }
}

/// A class to
/// 1. Fetch songs
/// 2. Control playlist json
/// 3. Manage playlists
/// 4. Search in playlists
///
/// etc.
abstract class ContentControl {
  static ContentState state = ContentState();

  /// An object to serialize songs
  static SongsSerialization songsSerializer = SongsSerialization();

  /// An object to serialize playlist
  static PlaylistSerialization playlistSerializer = PlaylistSerialization();

  /// Songs fetcher class instance
  static final SongsFetcher songsFetcher =
      SongsFetcher(songsSerializer.saveJson);

  /// A subscription to song changes, needed to get current art color
  static StreamSubscription<Song> _songChangeSubscription;

  /// Represents songs fetch on app start
  static bool initFetching = true;

  /// Whether playlist control is ready to provide player instance sources to play tracks
  static bool get playReady => state._playlists[PlaylistType.global] != null;

  /// The main data app initialization function
  /// Inits all playlists
  /// Also handles no-permissions situations
  static Future<void> init() async {
    if (Permissions.granted) {
      state._playlists[PlaylistType.global] = null; // Reset [playReady]

      initFetching = true;
      await Future.wait([
        songsSerializer.initJson(), // Init songs json
        playlistSerializer.initJson() // Init playlist json
      ]);
      // Get songs from json and create global playlist
      state._playlists[PlaylistType.global] =
          Playlist(await songsSerializer.readJson());
      await _restoreSortFeature();
      await filterSongs();
      sortSongs(silent: true);

      await _restoreLastSong();

      // // Setting up the subscription to get the art color
      // _songChangeSubscription = onSongChange.listen((event) async {
      //   var prevArtColor = _artColor;
      //   if (event.albumArtUri != null) {
      //     // Cancel the operation if it didn't finish by that moment
      //     if (_thiefOperation != null) _thiefOperation.cancel();

      //     _thiefOperation = CancelableOperation.fromFuture(() async {
      //       var prevArtColor = _artColor;
      //       final image =
      //           await getImageFromProvider(FileImage(File(event.albumArtUri)));
      //       List<int> colorRGBList = await getColorFromImage(image, 1);
      //       _artColor = Color.fromRGBO(
      //           colorRGBList[0], colorRGBList[1], colorRGBList[2], 1.0);

      //       if (prevArtColor != _artColor) emitArtColorChange(_artColor);
      //       _thiefOperation = null;
      //     }());
      //   } else {
      //     _artColor = null;
      //     if (prevArtColor != _artColor) emitArtColorChange(_artColor);
      //   }
      // });

      await _restorePlaylist();

      _initialSongsFetch();
    } else {
      // Init empty playlist if no permission granted
      if (!playReady) state._playlists[PlaylistType.global] = Playlist([]);
    }

    // Emit event to track change stream
    state.emitPlaylistChange();
  }

  /// Refetch songs and update playlist
  static Future<void> refetchSongs() async {
    state._playlists[PlaylistType.global] =
        Playlist(await songsFetcher.fetchSongs());
    await filterSongs(silent: true);
    sortSongs(silent: true);
    state.emitPlaylistChange();
  }

  /// Sets searched playlist
  ///
  /// This function doesn't call [emitPlaylistChange()]
  ///
  /// @param [songs] — can be omitted and if so, then playlist is not changed, only switched to it
  static Future<void> setSearchedPlaylist([List<Song> songs]) async {
    if (songs != null) {
      state._playlists[PlaylistType.searched] = Playlist(songs);
      playlistSerializer.saveJson(songs);
    }
    state._currentPlaylistType = PlaylistType.searched;
    Prefs.byKey.playlistTypeInt.setPref(1);
  }

  /// Shuffles from current playlist (by default)
  ///
  /// @param [argPlaylistType] if specified - shuffles from it
  /// @param [songs] if specified - sets them
  static void setShuffledPlaylist(
      [PlaylistType argPlaylistType, List<Song> songs]) {
    argPlaylistType ??= state._currentPlaylistType;

    state._playlistTypeBeforeShuffle = argPlaylistType;
    state._currentPlaylistType = PlaylistType.shuffled;
    Prefs.byKey.playlistTypeInt.setPref(2);

    if (songs == null)
      state._playlists[PlaylistType.shuffled] =
          Playlist.shuffled(state._playlists[argPlaylistType].songs);
    else
      state._playlists[PlaylistType.shuffled] = Playlist(songs);
    playlistSerializer.saveJson(state._playlists[PlaylistType.shuffled].songs);
    state.emitPlaylistChange();
  }

  /// Returns playlist that was before shuffle and clears [shuffledPlaylist]
  ///
  /// @param [argPlaylistType] if specified - returns to it
  static void returnFromShuffledPlaylist([PlaylistType argPlaylistType]) {
    argPlaylistType ??= state._playlistTypeBeforeShuffle;
    if (argPlaylistType == PlaylistType.global)
      resetPlaylists();
    else if (argPlaylistType == PlaylistType.searched) setSearchedPlaylist();
    state._playlists[PlaylistType.shuffled] = Playlist([]);
  }

  /// Switches tp global Resets all playlists except it
  ///
  /// This functions doesn't call [ContentState.emitPlaylistChange]
  static void resetPlaylists() {
    if (state._currentPlaylistType != PlaylistType.global) {
      Prefs.byKey.playlistTypeInt.setPref(0); // Save to prefs
      playlistSerializer.saveJson([]);
      state._currentPlaylistType = PlaylistType.global;
      state._playlists[PlaylistType.searched] = Playlist([]);
      state._playlists[PlaylistType.shuffled] = Playlist([]);
    }
  }

  /// Search in playlist song array by query
  static Iterable<Song> searchSongs(String query) {
    if (query != '') {
      // Lowercase to bring strings to one format
      query = query.toLowerCase();
      return state._playlists[PlaylistType.global].songs.where((el) {
        return el.title.toLowerCase().contains(query) ||
            el.artist.toLowerCase().contains(query) ||
            el.album.toLowerCase().contains(query) ||
            RegExp('\\b\\w')
                // Find abbreviations (big baby tape - bbt)
                //TODO: this is not working as expected for cyrillic
                .allMatches(el.title.toLowerCase())
                .fold("", (a, b) => a += b.group(0))
                .contains(query);
      });
    }
    return null;
  }

  /// Sort songs list by feature
  ///
  /// If no [feature] has passed then will sort by current sort feature
  ///
  /// If [silent] is true, [ContentState.emitPlaylistChange] won't be called
  static void sortSongs({SortFeature feature, bool silent = false}) {
    feature ??= state._currentSortFeature;
    switch (feature) {
      case SortFeature.date:
        state._playlists[PlaylistType.global].songs
            .sort((b, a) => a.dateModified.compareTo(b.dateModified));
        state._currentSortFeature = feature;
        Prefs.byKey.sortFeatureInt.setPref(0);
        break;
      case SortFeature.title:
        state._playlists[PlaylistType.global].songs
            .sort((a, b) => a.title.compareTo(b.title));
        state._currentSortFeature = feature;
        Prefs.byKey.sortFeatureInt.setPref(1);
        break;
      default:
        throw Exception('In sortSongs - invalid sort feature: $feature');
        break;
    }

    // Emit event to track change stream
    if (!silent) state.emitPlaylistChange();
  }

  /// Filter songs by min duration (for now, in future by size will be implemented)
  ///
  /// If [silent] is true, [ContentState.emitPlaylistChange] won't be called
  static Future<void> filterSongs({bool silent = false}) async {
    state._playlists[PlaylistType.global].filter(FilterFeature.duration,
        duration: Duration(
            seconds:
                await Prefs.byKey.settingMinFileDurationInt.getPref() ?? 30));
    // Emit event to track change stream
    if (!silent) state.emitPlaylistChange();
  }

  /// Deletes songs by specified id set
  static Future<void> deleteSongs(Set<int> idSet) async {
    Set<String> dataSet = {};
    idSet.forEach((id) {
      dataSet.add(state._playlists[PlaylistType.global].getSongById(id).data);
    });

    bool deletedSongWasPlaying = false;

    for (var id in idSet) {
      // Switch playing track in silent mode if it is playing now
      print(state._playlists[PlaylistType.global].getSongById(id).title);
      state._playlists[PlaylistType.global].removeSongById(id);
      if (state._currentSongId == id) {
        MusicPlayer.pause();
        deletedSongWasPlaying = true;
        state._currentSongId =
            state._playlists[PlaylistType.global].songs[0].id;
      }
    }
    state.emitPlaylistChange();

    if (deletedSongWasPlaying) {
      state.emitSongChange(state.currentSong);
      MusicPlayer.play(state._currentSongId);
    }

    try {
      await API.SongsHandler.deleteSongs(dataSet);
    } catch (e) {
      ShowFunctions.showToast(msg: "Ошибка при удалении");
      debugPrint("Deleting error: $e");
    }
  }

  /// Gets saved sort feature from [SharedPreferences]
  ///
  /// Default value is `SortFeature.date`
  static Future<void> _restoreSortFeature() async {
    int savedSortFeature = await Prefs.byKey.sortFeatureInt.getPref() ?? 0;
    if (savedSortFeature == 0) {
      sortSongs(feature: SortFeature.date, silent: true);
    } else if (savedSortFeature == 1) {
      sortSongs(feature: SortFeature.title, silent: true);
    } else
      throw Exception(
          "_restoreSortFeature: wrong saved sortFeatureInt: $savedSortFeature");
  }

  /// Restores saved playlist from json if [playlistTypeInt] (saved [_currentPlaylistType]) is not global
  static Future<void> _restorePlaylist() async {
    int savedPlaylistType = await Prefs.byKey.playlistTypeInt.getPref() ?? 0;

    if (savedPlaylistType == 0) {
      state._currentPlaylistType = PlaylistType.global;
    } else if (savedPlaylistType == 1) {
      state._currentPlaylistType = PlaylistType.searched;
    } else if (savedPlaylistType == 2) {
      state._currentPlaylistType = PlaylistType.shuffled;
    } else
      throw Exception(
          "_restorePlaylist: wrong saved playlistTypeInt: $savedPlaylistType");

    if (state._currentPlaylistType != PlaylistType.global) {
      /// Get songs ids from json
      List<int> songIds = await playlistSerializer.readJson();
      List<Song> restoredSongs = [];
      songIds.forEach((id) {
        final Song songEl =
            state._playlists[PlaylistType.global].getSongById(id);
        if (songEl != null) restoredSongs.add(songEl);
      });
      if (state._currentPlaylistType == PlaylistType.searched)
        setSearchedPlaylist(restoredSongs);
      else if (state._currentPlaylistType == PlaylistType.shuffled)
        setShuffledPlaylist(PlaylistType.global, restoredSongs);
    }
  }

  /// Function that fires right after json has fetched and when initial songs fetch has done
  ///
  /// Its main purpose to setup player to work with playlists
  static Future<void> _restoreLastSong() async {
    // songsEmpty condition is here to avoid errors when trying to get first song index
    if (state.currentPlaylist.isNotEmpty) {
      // Get saved data
      SharedPreferences prefs = await Prefs.getSharedInstance();

      int savedSongId = await Prefs.byKey.songIdInt.getPref(prefs) ??
          state.currentPlaylist.songs[0].id;

      // Setup initial playing state index from prefs
      state._currentSongId = savedSongId;
      await API.ServiceHandler.sendSong(state.currentSong);
      // Set url of first track in player instance
      await MusicPlayer.setUri(state._currentSongId);
    }
  }

  /// Function to fetch all songs from user devices
  static Future<void> _initialSongsFetch() async {
    await refetchSongs();

    // Retry do all the same as before fetching songs (set duration, set track url) if it hadn't been performed before (_playingSongIdState == null)
    if (state._currentSongId == null) {
      await _restoreLastSong();
    }
    initFetching = false;
  }
}
