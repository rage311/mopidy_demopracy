Client calls:
  - search
  - get playlist
  - vote

  my $votes = {
    904 => {
      '10.0.0.31' => {
        name  => 'matt',
        ip    => '10.0.0.31',
        value => 1,
      },
      '10.0.0.32' => {
        name  => 'bryan',
        ip    => '10.0.0.32',
        value => -1,
      },
    }
  };

  # Cache tracklist, only update on startup and events?
  my $tracklist_example = [
    {
      artist_string => 'Kimbra, Bilal', # calculated
      title         => 'Everlovin Ya',
      album_title   => 'The Golden Echo',
      tlid          => 904,
      votes         => [
        {
          name  => 'matt',
          ip    => '10.0.0.31',
          value => 1,
        },
        {
          name  => 'bryan',
          ip    => '10.0.0.32',
          value => -1,
        },
      ],
    },
  ];


Tracklist:
{
  "id": "Mojo::Transaction::WebSocket=HASH(0x55aad892ae80)_1503787634554",
  "jsonrpc": "2.0",
  "request_id": "1503787634554",
  "result": [
    {
      "__model__": "TlTrack",
      "tlid": 1,
      "track": {
        "__model__": "Track",
        "album": {
          "__model__": "Album",
          "artists": [
            {
              "__model__": "Artist",
              "name": "Animals As Leaders",
              "uri": "spotify:artist:65C6Unk7nhg2aCnVuAPMo8"
            }
          ],
          "date": "2014",
          "name": "The Joy of Motion",
          "uri": "spotify:album:3BfAgyF1AdYKaOO7EBoDw4"
        },
        "artists": [
          {
            "__model__": "Artist",
            "name": "Animals As Leaders",
            "uri": "spotify:artist:65C6Unk7nhg2aCnVuAPMo8"
          }
        ],
        "bitrate": 320,
        "date": "2014",
        "disc_no": 0,
        "length": 324000,
        "name": "Kascade",
        "track_no": 1,
        "uri": "spotify:track:7hY2Kc7Hvu0BudOoQwu8Ez"
      }
    }
  ]
}



\ {
    event   "tracklist_changed"
}
WebSocket message
\ {
    event       "playback_state_changed",
    new_state   "playing",
    old_state   "stopped"
}
WebSocket message
\ {
    event      "track_playback_started",
    tl_track   {
        __model__   "TlTrack",
        tlid        14,
        track       {
            album       {
                artists     [
                    [0] {
                        __model__   "Artist",
                        name        "Corinne Bailey Rae",
                        uri         "spotify:artist:29WzbAQtDnBJF09es0uddn"
                    }
                ],
                date        2006,
                __model__   "Album",
                name        "Corinne Bailey Rae",
                uri         "spotify:album:4ShaH3pEqEonoqH3L8ceR5"
            },
            artists     [
                [0] {
                    __model__   "Artist",
                    name        "Corinne Bailey Rae",
                    uri         "spotify:artist:29WzbAQtDnBJF09es0uddn"
                }
            ],
            bitrate     320,
            date        2006,
            disc_no     0,
            length      240000,
            __model__   "Track",
            name        "Like a Star",
            track_no    1,
            uri         "spotify:track:7aFQa52bLiHwb3BXPbmKdZ"
        }
    }
}
WebSocket message
\ {
    event       "playback_state_changed",
    new_state   "stopped",
    old_state   "playing"
}
WebSocket message
\ {
    event           "track_playback_ended",
    time_position   4455,
    tl_track        {
        __model__   "TlTrack",
        tlid        14,
        track       {
            album       {
                artists     [
                    [0] {
                        __model__   "Artist",
                        name        "Corinne Bailey Rae",
                        uri         "spotify:artist:29WzbAQtDnBJF09es0uddn"
                    }
                ],
                date        2006,
                __model__   "Album",
                name        "Corinne Bailey Rae",
                uri         "spotify:album:4ShaH3pEqEonoqH3L8ceR5"
            },
            artists     [
                [0] {
                    __model__   "Artist",
                    name        "Corinne Bailey Rae",
                    uri         "spotify:artist:29WzbAQtDnBJF09es0uddn"
                }
            ],
            bitrate     320,
            date        2006,
            disc_no     0,
            length      240000,
            __model__   "Track",
            name        "Like a Star",
            track_no    1,
            uri         "spotify:track:7aFQa52bLiHwb3BXPbmKdZ"
        }
    }
}


