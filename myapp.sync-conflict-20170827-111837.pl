#!/usr/bin/env perl

use Mojolicious::Lite;
use DDP;


my $clients = {};


helper client_ws_reply => sub {
  my ($c, $json) = @_;

  p $clients;

  say $json->{id};
  my ($client_id, $request_id) = ($1, $2)
    if $json->{id} =~ /(Mojo::Transaction::WebSocket=HASH\(\w+\))_(\d{8,})$/;

  $json->{request_id} = $request_id;
  return $clients->{$client_id}->send({json => $json}) if ($clients->{$client_id});

  say "${client_id}_${request_id} not found";
};


helper process_event => sub {
  my ($c, $json) = @_;

  p $clients;
  $_->send({ json => $json }) for values %$clients;
};


helper ws => sub {
  my ($c, $cb) = @_;

  p $cb;

  state $ws;
  return Mojo::IOLoop->next_tick(sub { $cb->($ws) }) if $ws;

  $c->ua->inactivity_timeout(0)->websocket(
    'ws://i7-arch:6680/mopidy/ws'                         =>
    { 'Sec-WebSocket-Extensions' => 'permessage-deflate' }  =>
    sub {
      my ($ua, $tx) = @_;

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
        } elsif ($json->{jsonrpc} && $json->{id}) {
          # response to a query
          $c->client_ws_reply($json);
        }
      });

      $ws = $tx;
      $cb->($ws);
    }
  );

  return undef;
};


websocket '/ws' => sub {
  my $c = shift;
  $c->inactivity_timeout(1800);

  app->log->debug(sprintf 'Client connected: %s', $c->tx->remote_address);
  my $id = sprintf "%s", $c->tx;
  $clients->{$id} = $c->tx;

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


__DATA__

@@ index.html.ep
% layout 'default';
% title 'jukebox';
<div id="app">
  <table class="table table-bordered table-striped" id="tracklist">
    <tbody>
      <tr v-for="(entry, idx) in tracklist">
        <td style="vertical-align: middle">
          {{idx > 0 ? idx : ''}}
        </td>
        <td style="vertical-align: middle">
          <div class="title">{{entry.track.name}}</div>
          <div>{{artistsString(entry.track.artists)}}</div>
        </td>
        <td style="vertical-align: middle">
          1
          <div></div>
          <div></div>
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
      self.socket = new WebSocket('ws://localhost:3000/ws');

      // Connection opened
      self.socket.addEventListener('open', function (event) {
        self.socket.send(JSON.stringify({
          "method"    : "get_tracklist",
          "request_id": Date.now(),
        }));
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
        if (local_data.result) {
          self.tracklist = local_data.result.slice();
          console.log(self.tracklist[0].track.name);
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
      artistsString: function(artists) {
        var returnString = artists[0].name;
        console.log(artists);
        if (artists.length > 1) {
          for (var i = 1; i < artists.length; i++) {
            returnString += ', ' + artists[i].name;
          }
        }
        return returnString;
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
