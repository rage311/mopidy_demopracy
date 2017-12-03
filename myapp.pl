#!/usr/bin/env perl

use 5.026;
use strict;
use warnings;

use lib '.';

use API::Mopidy;
use Mojo::Base -strict;
use Mojolicious::Lite;
use Mojo::JSON qw(true false);
use List::Util qw(reduce);
use DDP;


my $clients = {};

use constant MOPIDY_HOST        => '10.0.0.121';
use constant MOPIDY_PORT        => '6680';
use constant BASE_PLAYLIST_URI  =>
  'spotify:user:rage_311:playlist:5u9o0va3hiIhmlkw70voES';

helper mopidy => sub {
  my $c = shift;

  state $mopidy;
  return $mopidy if ref $mopidy eq 'API::Mopidy';

  $mopidy = API::Mopidy->new(host => MOPIDY_HOST);
  $mopidy->on(error => sub { p $_[1]; });
  $mopidy->on(event => \&{$c->process_event});
  $mopidy->on(message => sub { say 'Mopidy message:'; p $_[0] });

  $mopidy->connect
    ->then(sub { return $_[0] })
    ->catch(sub { die 'Mopidy connection error' })
    ->wait;

  return $mopidy;
};

# For shuffling instead of random?
my $base_tracks_played = {};

my $base_playlist;

my $reordering_tracklist = 0;

helper jukebox_init => sub {
  my $c = shift;
  srand;

  # Set consume mode (core.tracklist.consume = 1)
  $c->mopidy->send('tracklist.set_consume', [ true ]);

  $c->mopidy->send('library.lookup', [ BASE_PLAYLIST_URI ] => sub {
    die 'No base playlist found' if $_[0]->{error};
    $base_playlist = shift->{result};
    $c->maybe_add_new_track;
  });
};

helper play_if_stopped => sub {
  my $c = shift;

  $c->mopidy->send('playback.get_state' => sub {
    my $playback_state = shift->{result};
    p $playback_state;

    return if $playback_state eq 'playing';
    # Start playing
    $c->mopidy->send('playback.play');
  });
};

helper maybe_add_new_track => sub {
  my $c = shift;

  warn 'get_length';
  # Add random track to tracklist (if tracklist length < 1)
  # Get tracklist length
  $c->mopidy->send('tracklist.get_length' => sub {
    my $length = shift->{result} // 0;
    return unless $length < 1;

    warn 'tracklist.add';
    $c->mopidy->send(
      'tracklist.add',
      { uri => $base_playlist->[int(rand $#$base_playlist)]{uri} },
      \&{$c->play_if_stopped},
    );
  });

  # Listen for track_playback_ended event to check if another random track
  # needs to be added
  #
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
  #p $json;
  if ($json->{event} eq 'tracklist_changed') {# && $reordering_tracklist == 0) {
    #$c->get_tracklist;
  } elsif ($json->{event} eq 'track_playback_ended') {
    $c->maybe_add_new_track;
  }

  #p $clients;
  #$_->send({ json => $json }) for values %$clients;
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

my $whatever = app->jukebox_init;
Mojo::IOLoop->start;

my $master_tracklist = app->ws(sub { app->get_tracklist() });
my $votes = {};

helper populate_tracklist => sub {
  my ($c, $result) = @_;

  say 'populate_tracklist';

  return unless $result && ref $result eq ref [];

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

  my $ordered_tracklist = $c->order_tracklist_by_votes;
  $c->reorder_mopidy_tracklist($ordered_tracklist);
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
      # TODO: make this user-entered
      name  => 'matt',
      time  => time,
    };
  }

  p $vote;
  #p $votes;
  my $ordered_tracklist = $c->order_tracklist_by_votes;

  #$master_tracklist->{hash}{$tlid};

  my ($current_idx, $move_to_idx);
  for (my $i = 0; $i < $master_tracklist->{array}->@*; $i++) {
    if ($master_tracklist->{array}[$i]{tlid}) {
      $current_idx = $i;
      last;
    }
  }

  for (my $i = 0; $i < $ordered_tracklist->@*; $i++) {
    if ($ordered_tracklist->[$i]{tlid}) {
      $move_to_idx = $i;
      last;
    }
  }

  unless ($current_idx == $move_to_idx) {
    my $result = $c->send_mopidy_message(
      'core.tracklist.move',
      {
        start       => $current_idx,
        end         => $current_idx,
        to_position => $move_to_idx,
      }
    );
    p $result->json;
  }

  #$c->reorder_mopidy_tracklist($ordered_tracklist);

  # TODO: only move track that was voted on -- need old position, new position
  #$c->send_tracklist;
  return $c->render(text => $value);
};


helper order_tracklist_by_votes => sub {
  my $c = shift;
  #p $master_tracklist;

  my $ordered_tracklist = [
    # Return track itself
    map { $_->[0] }

    # Sort by vote total, then by oldest timestamp
    sort  { $b->[1] <=> $a->[1] || $a->[2] <=> $b->[2] }

    # Creates array ref of obj, vote_total, oldest_timestamp arrays
    map   {
      my @votes = values $_->{votes}->%*;

      my $vote_sum = reduce {
        $a + $b->{value}
      } 0, @votes;

      my $oldest_time = reduce {
        $a < $b->{time} ? $a : $b->{time}
      } 9999999999, @votes;
      #say $oldest_time;

      [ $_, $vote_sum, $oldest_time ]
    } @{$master_tracklist->{array}}[1..$#{$master_tracklist->{array}}]
  ];

  unshift @$ordered_tracklist, $master_tracklist->{array}[0];

  warn 'ordered_tracklist';
  #p $ordered_tracklist;
  #$master_tracklist->{array} = $ordered_tracklist;
  return $ordered_tracklist;
};


helper reorder_mopidy_tracklist => sub {
  my ($c, $ordered_tracklist) = @_;
  #my $track (@{$ordered_tracklist}[1..$#{master_tracklist->{array}}) {

  my %tlid_order = map {
    #p $_;
    ($ordered_tracklist->[$_]{tlid} => $_)
  } 1..$#{$ordered_tracklist};

  say 'TLID_ORDER';
  p %tlid_order;

  $reordering_tracklist = 1;

  for (my $i = 1; $i < $master_tracklist->{array}->@*; $i++) {
    my $to_position = $tlid_order{$master_tracklist->{array}[$i]{tlid}};

    my $thing = {
        start       => $i,
        end         => $i,
        to_position => $to_position,
      };

    p $thing;

    if ($i != $to_position) {
      my $result = $c->send_mopidy_message(
        'core.tracklist.move',
        {
          start       => $i,
          end         => $i,
          to_position => $to_position,
        }
      );
      p $result->json;
    }
  }
  $reordering_tracklist = 0;
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
