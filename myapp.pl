#!/usr/bin/env perl

use Mojolicious::Lite;
use DDP;


my $clients = {};


helper client_ws_reply => sub {
  my ($c, $json) = @_;

  #p $clients;

  say $json->{id};
  my ($client_id, $request_id) = ($1, $2)
    if $json->{id} =~ /(Mojo::Transaction::WebSocket=HASH\(\w+\))_(\d{8,})$/;

  $json->{request_id} = $request_id;
  return $clients->{$client_id}->send({json => $json}) if ($clients->{$client_id});

  say "${client_id}_${request_id} not found";
};


helper process_reply => sub {
  my ($c, $json) = @_;

  if (index($json->{id}, 'Mojo') > -1) {
    $c->client_ws_reply($json);
  }
  #elsif (index($json->{id}, 'self_') > -1) {

};

helper process_event => sub {
  my ($c, $json) = @_;

  warn "event: $json->{event}";
  p $json;
  if ($json->{event} eq 'tracklist_changed') {
    $c->get_tracklist;
  }

  #p $clients;
  #$_->send({ json => $json }) for values %$clients;
};


helper ws => sub {
  my ($c, $cb) = @_;

  #p $cb;
  state $ws;
  return Mojo::IOLoop->next_tick(sub { $cb->($ws) }) if $ws;

  $c->ua->inactivity_timeout(0)->websocket(
    'ws://10.0.0.121:6680/mopidy/ws'                        =>
    { 'Sec-WebSocket-Extensions' => 'permessage-deflate' }  =>
    sub {
      my ($ua, $tx) = @_;

      # needed for full base playlist size -- not sure what limit it really needs
      $tx->max_websocket_size(2621440);

      say 'WebSocket handshake failed!' and return unless $tx->is_websocket;
      #say 'Subprotocol negotiation failed!' and return unless $tx->protocol;

      $tx->on(finish => sub {
        my ($tx, $code, $reason) = @_;
        say "WebSocket closed with status $code.";
      });

      $tx->on(json => sub {
        my ($tx, $json) = @_;
        p $json;

        if ($json->{event}) {
          $c->process_event($json);
        }
        elsif ($json->{jsonrpc} && $json->{id}) {
          # response to a query
          $c->client_ws_reply($json);
        }
      });

      say 'mopidy websocket connected';
      $ws = $tx;
      $cb->($ws);
    }
  );

  return undef;
};


# Join artists[] names into a comma-separated string
helper make_artists_string => sub {
  my ($c, $artists) = @_;

  return undef if ref $artists ne ref [];

  return join ', ', map { $_->{name} } @$artists;
};


# Call when tracklist_changed event occurs
helper get_tracklist => sub {
  my $c = shift;

  warn "get_tracklist";

  my $mopidy_json = {
    jsonrpc => '2.0',
    id      => 'self_' . time * 1000, # match JS timestamp format
    method  => 'core.tracklist.get_tl_tracks',
  };

  $c->ua->post(
    'http://10.0.0.121:6680/mopidy/rpc' =>
    json => $mopidy_json                => sub {
      my ($ua, $tx) = @_;

      (my $result = $tx->result->json) or return undef;
      #p $result;

      if ($result->{jsonrpc} && $result->{result}) {
        $c->populate_tracklist($result->{result});
      }
    }
  );

  return {};
  #$c->ws(sub {
  #  shift->send({json => $mopidy_json});
  #});
};



#helper master_tracklist => sub { state $master_tracklist = shift->get_tracklist; };
#helper votes            => sub { state $votes = {}; };

my $master_tracklist = app->ws(sub { app->get_tracklist() });
my $votes = {};

helper populate_tracklist => sub {
  my ($c, $result) = @_;

  say 'populate_tracklist';

  return undef unless $result && ref $result eq ref [];

  my $tracklist_array   = [];
  my $tracklist_hash    = {};

  for (@$result) {
    $votes->{$_->{tlid}} = {} unless defined $votes->{$_->{tlid}};

    my $track = {
      artist_string => $c->make_artists_string($_->{track}{artists}),
      title         => $_->{track}{name},
      album_title   => $_->{track}{album}{name},
      album_date    => $_->{track}{album}{date},
      tlid          => $_->{tlid},
      votes         => $votes->{$_->{tlid}},
    };

    push @$tracklist_array, $track;
    $tracklist_hash->{$_->{tlid}} = $track;
  }

  # Delete old vote references (songs that have been played or deleted)
  for (keys %$tracklist_hash) {
    delete $votes->{$_} unless $tracklist_hash->{$_};
  }

  $master_tracklist->{array} = $tracklist_array;
  $master_tracklist->{hash}  = $tracklist_hash;

  $c->send_tracklist;
};


# Send tracklist when it has changed (or when new client connects)
helper send_tracklist => sub {
  my ($c, $client) = @_;

  say 'send_tracklist master_tracklist';

  my $temp_tracklist = $master_tracklist->{array};

  # dereference the reference to a reference
  warn 'temp_tracklist:';
  #$_->{votes_all} = $_->{votes}->$* for @$temp_tracklist;

  return $client->send({ json => {tracklist => $master_tracklist->{array}} }) if $client;

  $_->send({ json => {tracklist => $master_tracklist->{array}} }) for values %$clients;
};


any '/vote' => sub {
  my $c = shift;

  return $c->render(text => 'Require tlid, username, value optional')
    unless defined $c->param('tlid') && $c->param('username');

  # say join("\n",
  #       'vote: '  => $c->tx->remote_address,
  #       'tlid: '  => $c->param('tlid'),
  #       'value: ' => $c->param('value')
  #     );
  my $ip        = $c->tx->remote_address;
  my $tlid      = $c->param('tlid');
  my $value     = $c->param('value');
  my $username  = $c->param('username');

  #TODO: need vote timestamp to break ties -- newest is last

  # Use Mojo's validator instead
  $value //= 0;
  $value = -1 if $value < -1;
  $value = 1 if $value > 1;
  # $value == 0 is toggle?

  #my $votes_ref = $votes->{$tlid}{votes};#master_tracklist->{hash}{$tlid}{votes};
  #return $c->render(
  #  json => {error => 'unable to retrieve votes (track may not be in TL any more'}
  #) unless defined $votes_ref;

  if (my $vote = $votes->{$tlid}{$ip}) {
    say "$vote->{value} == $value ";
    if ($vote->{value} == $value) {
      $vote->{value} = 0;
    } else {
      $vote->{value} = $value;
    }
    $vote->{time} = time;
  } else {
    $votes->{$tlid}{$ip} = {
      ip    => $ip,
      value => $value,
      name  => 'matt',
      time  => time,
    };
  }

  say 'votes';
  #p $votes;
  $c->send_tracklist;
  return $c->render(text => $value);
};


# Websocket server
websocket '/ws' => sub {
  my $c = shift;

  #$c->ws(sub{});

  $c->inactivity_timeout(1800);

  app->log->debug(sprintf 'Client connected: %s', $c->tx->remote_address);
  my $id = sprintf "%s", $c->tx;
  $clients->{$id} = $c->tx;

  $c->send_tracklist($clients->{id});

  $c->on(json => sub {
    my ($c, $json) = @_;

    say "client $id json:";
    p $json;

    return $clients->{$id}->send({json => {
      success => 0,
      message => 'No method specified',
    }}) unless $json->{method};

    return $clients->{$id}->send({json => {
      success => 0,
      message => 'No request_id specified (Date.now())'
    }}) unless $json->{request_id};

    my $mopidy_json = {
      jsonrpc => '2.0',
      id      => "${id}_$json->{request_id}",
    };

    if ($json->{method} eq 'get_tracklist') {
      $mopidy_json->{method} = 'core.tracklist.get_tl_tracks';
    }

    elsif ($json->{search_type} && $json->{search_text}) {
      $mopidy_json->{method} = 'core.library.search';
      $mopidy_json->{params} = {
        uris    => ['spotify:'],
        query   => {
          $json->{search_type} => [ $json->{search_text} ],
          #track_name           => [ 'love' ],
        },
      };
    }

    else {
      return $clients->{$id}->send({json => {
        success => 0,
        message => 'Unknown error'
      }});
    }

    warn "mopidy_json";
    p $mopidy_json;
    $c->ws(sub {
      shift->send({json => $mopidy_json});
    });
  });

  $c->on(finish => sub {
    app->log->debug('Client disconnected');
    delete $clients->{$id};
  });
};


get '/' => sub {
  my $c = shift;

  $c->render(template => 'index');
};


app->secrets([')#%& Hp h5bhjupup 25 u23phup puIPGSDFU&(#%TY0237590*#&89071)']);
say "\n", '-' x 20, ' ', scalar localtime, "\n";
app->start;


# once per second?
# playback_staus = {
#   state => 'playing',
#   current_position => '120',
#   total_track_length  => '240',
#   track_completion    => .5,
#   tlid?
#   artist - song?
# };
# core.playback.get_current_tl_track
# core.playback.get_time_position
# core.playback.get_state

__DATA__

@@ index.html.ep
% layout 'default';
% title 'jukebox';
<div id="app">
  <div class="progress">
    <span class="progress-bar" role="progressbar" aria-valuenow="60" aria-valuemin="0" aria-valuemax="100" style="width: 60%;">
      Hello
    </span>
  </div>Again
  <table class="table table-striped" id="tracklist">
    <tbody>
      <tr v-for="(track, idx) in tracklist">
        <td style="vertical-align: middle">
          <span v-if="idx == 0" class="fa fa-play" style="font-size:18px"></span>
          <span v-else style="font-size:18px">{{idx}}</span>
        </td>
        <td style="vertical-align: middle">
          <div class="title" style="font-size:16px">{{track.title}}</div>
          <div>{{track.artist_string}}</div>
          <div>({{track.album_title}} - {{track.album_date}})</div>
        </td>
        <td style="vertical-align: middle; text-align: right">
          <span style="font-size:24px; margin-right:10px">{{getTotalVotes(track)}}</span>
        </td>
        <td style="vertical-align: middle">
          <div style="margin-bottom:8px">
            <span class="fa fa-thumbs-up vote" value="1" v-on:click="submitVote(track.tlid, 1)" style="font-size:24px;cursor:pointer" />
          </div>
          <div>
            <span class="fa fa-thumbs-down vote" value="-1" v-on:click="submitVote(track.tlid, -1)" style="font-size:24px;cursor:pointer" />
          </div>
        </td>
      </tr>
    </tbody>
  </table>
</div>

<script type="text/javascript">
  var app = new Vue({
    el: '#app',
    data: {
      socket: null,
      search_results: [],
      tracklist: [],
    },

    mounted: function () {
      var self = this;
      console.log('ready');
      // Create WebSocket connection.
      self.socket = new WebSocket('ws://10.0.0.121:3000/ws');

      // Connection opened
      self.socket.addEventListener('open', function (event) {
        console.log('WS connection established');
        /*
        self.socket.send(JSON.stringify({
          "method"    : "get_tracklist",
          "request_id": Date.now(),
        }));
        */
        /*
        self.socket.send(JSON.stringify({
          "search_type" : "artist",
          "search_text" : "kimbra",
          "request_id"   : Date.now(),
        }));
        */
      });

      // Listen for messages
      self.socket.addEventListener('message', function (event) {
        console.log('Message from server ', event.data);
        var local_data = JSON.parse(event.data);

        console.log(local_data.result);
        if (local_data.tracklist) {
          self.tracklist = local_data.tracklist;
          //self.tracklist && console.log(self.tracklist[0].title);
        } else if (local_data.event) {
          if (local_data.event === 'tracklist_changed') {
            self.socket.send(JSON.stringify({
              "method"    : "get_tracklist",
              "request_id": Date.now(),
            }));
          }
        }
      });
    },

    methods: {
      getTotalVotes: function(track) {
        var total = 0;
        Object.values(track.votes).forEach(function (vote) {
          console.log(vote);
          //console.log(vote.value);
          total += vote.value;
        });
        return total > 0 ? '+' + total : total;
      },
      artistsString: function(artists) {
        var returnString = artists[0].name;
        //console.log(artists);
        if (artists.length > 1) {
          for (var i = 1; i < artists.length; i++) {
            returnString += ', ' + artists[i].name;
          }
        }
        return returnString;
      },
      submitVote: function(tlid, value) {
        var postData = {
          "tlid": tlid,
          "value": value,
          "username": "matt",
        };
        $.post('/vote', postData, function(data) {
          console.log(data);
        });
      }
    }
  });

</script>



@@ layouts/default.html.ep
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title><%= title %></title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="https://ajax.googleapis.com/ajax/libs/jquery/1.12.4/jquery.min.js"></script>
    <script src="https://vuejs.org/js/vue.js"></script>

    <!-- Latest compiled and minified CSS -->
    <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/css/bootstrap.min.css" integrity="sha384-BVYiiSIFeK1dGmJRAkycuHAHRg32OmUcww7on3RYdg4Va+PmSTsz/K68vbdEjh4u" crossorigin="anonymous">

    <!-- Latest compiled and minified JavaScript -->
    <script src="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/js/bootstrap.min.js" integrity="sha384-Tc5IQib027qvyjSMfHjOMaLkfuWVxZxUPnCJA7l2mCWNIpG9mGCD8wGNIcPD7Txa" crossorigin="anonymous"></script>

    <link href="https://maxcdn.bootstrapcdn.com/font-awesome/4.7.0/css/font-awesome.min.css" rel="stylesheet" integrity="sha384-wvfXpqpZZVQGK6TAh5PVlGOfQNHSoD2xbE+QkPxCAFlNEevoEH3Sl0sibVcOQVnN" crossorigin="anonymous">

    <style>
      .title {
        font-weight: bold;
      }
    </style>

  </head>
  <body>
    <%= content %>
  </body>
</html>




@@ other.html.ep
{"jsonrpc": "2.0", "id": 1, "result": [{"__model__": "SearchResult", "artists": [{"__model__": "Artist", "name": "Kimbra", "uri": "spotify:artist:6hk7Yq1DU9QcCCrz9uc0Ti"}, {"__model__": "Artist", "name": "Kimbra Snay", "uri": "spotify:artist:6hFYKCmm4Yn5j5SNOx4GNJ"}, {"__model__": "Artist", "name": "Kimbra Westervelt", "uri": "spotify:artist:0rl3mbAZxRV1NnIU4zEroL"}]}]
