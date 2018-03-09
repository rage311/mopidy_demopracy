#!/usr/bin/env perl

use 5.026;

use lib '.';

use Mojo::JSON::MaybeXS;
use Jukebox::Model;
use Mojo::Base -strict, -signatures;
use Mojolicious::Lite;
use Mojo::JSON qw(true false);
use List::Util qw(reduce);
use DDP;


helper clients => sub { state $clients = {} };

helper jb      => sub ($c) {
  state $jb;
  return $jb if $jb;

  $jb = Jukebox::Model->new;
  $jb->on(tracklist_changed => sub {
    say 'TRACKLIST CHANGED';
    $c->app->send_tracklist;
  });
  $jb->on(search_result     => sub ($self, $result) {
    p @_;
    say 'SEARCH RESULT';
    $c->process_reply($result);
  });

  return $jb;
};

helper process_reply => sub ($c, $result) {
  say 'process_reply';
  p $result;
  if (index($result->{request_id}, 'Mojo') > -1) {
    $c->client_ws_reply($result);
  }
  #elsif (index($json->{id}, 'self_') > -1) {
};


helper client_ws_reply => sub ($c, $result) {
  #p $clients;

  say $result->{request_id};
  warn 'invalid request_id' and return unless
    $result->{request_id} =~ /(Mojo::Transaction::WebSocket=HASH\(\w+\))_(\d{8,})$/;
  my ($client_id, $client_request) = ($1, $2);

  my $return->{request_id} = $client_request;
  $return->{search_result} = $result->{data}{result};

  return $c->app->clients->{$client_id}->send({json => $return})
    if ($c->app->clients->{$client_id});

  say "${client_id}_${client_request} not found";
};

any '/add' => sub ($c) {
  return $c->render(
    text => 'Require uri, user',
    code => 400,
  ) unless defined $c->param('uri') && $c->param('user');

  $c->render(
    text => $c->app->jb->add_track(
      uri  => $c->param('uri'),
      user => $c->param('user'),
      ip   => $c->tx->remote_address,
    )
  );
};


any '/vote' => sub ($c) {
  return $c->render(
    text => 'Require tlid, username, value optional',
    code => 400,
  ) unless defined $c->param('tlid') && $c->param('user');

  # say join("\n",
  #       'vote: '  => $c->tx->remote_address,
  #       'tlid: '  => $c->param('tlid'),
  #       'value: ' => $c->param('value')
  #     );

  $c->render(
    text => $c->app->jb->vote(
      ip    => $c->tx->remote_address,
      tlid  => $c->param('tlid'),
      value => $c->param('value'),
      user  => $c->param('user'),
      users => scalar keys $c->app->clients->%*,
    )
  );
};


# Send tracklist when it has changed (or when new client connects)
helper send_tracklist => sub ($c, $client = undef) {
  say 'send_tracklist';

  say 'Clients:';
  p $c->app->clients;

  p $c->app->jb->tracklist->{array};
  $_->send({ json => {tracklist => $c->app->jb->tracklist->{array}} })
    for ($client // values $c->app->clients->%*);
};



# Websocket server
websocket '/ws' => sub ($c) {
  $c->inactivity_timeout(300);

  $c->app->log->debug(sprintf 'Client connected: %s', $c->tx->remote_address);
  my $id = sprintf "%s", $c->tx;
  $c->app->clients->{$id} = $c->tx;

  $c->send_tracklist($c->app->clients->{id});

  # json message from ws clients
  $c->on(json => sub {
    my ($c, $json) = @_;

    say "client $id json:";
    p $json;

    return $c->send({ json => { heartbeat => scalar time * 1000 } })
      if $json->{heartbeat};

    # input validation
    return $c->app->clients->{$id}->send({json => {
      success => 0,
      message => 'No method specified',
    }}) unless $json->{method};

    return $c->app->clients->{$id}->send({json => {
      success => 0,
      message => 'No request_id specified (Date.now())'
    }}) unless $json->{request_id};

    # some universal values
    my $mopidy_json = {
      jsonrpc => '2.0',
      id      => "${id}_$json->{request_id}",
    };

    # not needed anymore?
    if ($json->{method} eq 'get_tracklist') {
      $mopidy_json->{method} = 'tracklist.get_tl_tracks';
    }

    elsif ($json->{search_type} && $json->{search_text}) {
      return $c->jb->search(
        id   => "${id}_$json->{request_id}",
        type => $json->{search_type},
        text => $json->{search_text}
      );
      #$mopidy_json->{method} = 'library.search';
      #$mopidy_json->{params} = {
      #  uris    => ['spotify:'],
      #  query   => {
      #    $json->{search_type} => [ $json->{search_text} ],
      #    #track_name           => [ 'love' ],
      #  },
      #};
    }
    else {
      return $c->app->clients->{$id}->send({json => {
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
    delete $c->app->clients->{$id};
  });
};

any '/playback/:command' => sub ($c) {
  my $command = $c->stash('command') or return $c->render(text => 0);

  $c->app->jb->manual_stop($command eq 'stop');
  # TODO: make playback controls directly part of jb
  $c->jb->mopidy->send('playback.' . $command);
  $c->render(text => 1);
};

get '/admin' => sub ($c) {
  $c->session(admin => 1);
  $c->render(template => 'index');
};

get '/' => sub ($c) { $c->render(template => 'index') };


#app->jukebox_init;
#app->get_tracklist;
app->jb;
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
