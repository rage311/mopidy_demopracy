#!/usr/bin/env perl

use Mojolicious::Lite;
use Mojo::JSON qw(true false);
use DDP;


my $clients = {};

use constant MOPIDY_IP          => '10.0.0.121';
use constant MOPIDY_PORT        => '6680';
use constant BASE_PLAYLIST_URI =>
  'spotify:user:rage_311:playlist:5u9o0va3hiIhmlkw70voES';

# For shuffling instead of random?
my $base_tracks_played = {};

my $base_playlist;


helper do_jukebox_things => sub {
  my $c = shift;

  # Set consume mode (core.tracklist.consume = 1)
  $c->send_mopidy_message('core.tracklist.set_consume', [ true ]);

  # Find base playlist
  $c->send_mopidy_message(
    'core.library.lookup',
    [ BASE_PLAYLIST_URI ],
    sub {
      my ($ua, $tx) = @_;
      #p $tx->result->json;
      $base_playlist = $tx->result->json if $tx->result;
    },
  );

  srand;
  # Add random track to tracklist (if tracklist length < 1)
  #
  # core.playback.play

  # Find base playlist
  $c->send_mopidy_message(
    'core.playback.play',
    [],
    sub {
      my ($ua, $tx) = @_;
      p $tx->result->json;
    },
  );

  # Listen for track_playback_ended event to check if another random track
  # needs to be added
  #
};


my $mopidy_url = Mojo::URL->new
  ->scheme('http')
  ->host(MOPIDY_IP)
  ->port(MOPIDY_PORT)
  ->path('/mopidy/rpc');

helper send_mopidy_message => sub {
  my ($c, $method, $params, $cb, $id) = @_;

  return undef unless $method;
  return undef if defined $params && ref $params ne ref [];

  my $mopidy_json = {
    jsonrpc => '2.0',
    id      => $id // time * 1000,
    method  => $method,
    params  => $params,
  };

  my $res = $c->ua->post(
    $mopidy_url => json => $mopidy_json => sub { $cb->(@_) if $cb });
  #);

  #$cb->($res->tx);

  #say 'hi';
  #p $res->json if $res;

  #$c->ws(sub { shift->send({ json => $mopidy_json }) });
};


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

      say 'WebSocket handshake failed!' and return unless $tx->is_websocket;
      $tx->max_websocket_size(2621440);
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

my $whatever = app->do_jukebox_things;
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

  my $vote = {};
  # Check if the IP has a vote for this tlid already
  if ($vote = $votes->{$tlid}{$ip}) {
    $vote->{value} = $vote->{value} == $value ? 0 : $value;
    $vote->{time} = time;
  } else {
    $vote = $votes->{$tlid}{$ip} = {
      ip    => $ip,
      value => $value,
      name  => 'matt',
      time  => time,
    };
  }

  p $vote;
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

post '/play' => sub {
  my $c = shift;
  $c->send_mopidy_message('core.playback.play', [], sub {});
  $c->render(text => 1);
};

post '/pause' => sub {
  my $c = shift;
  $c->send_mopidy_message('core.playback.pause', [], sub {});
  $c->render(text => 1);
};

post '/stop' => sub {
  my $c = shift;
  $c->send_mopidy_message('core.playback.stop', [], sub {});
  $c->render(text => 1);
};

post '/next' => sub {
  my $c = shift;
  $c->send_mopidy_message('core.playback.next', [], sub {});
  $c->render(text => 1);
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
