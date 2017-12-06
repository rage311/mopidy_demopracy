#!/usr/bin/env perl

# use 5.026;
# use strict;
# use warnings;

use Mojolicious::Lite;
use lib '.';

use API::Mopidy;
use DDP;

use constant MOPIDY_HOST        => '10.0.0.121';
#use constant MOPIDY_PORT        => '6680';
use constant BASE_PLAYLIST_URI  =>
  'spotify:user:rage_311:playlist:5u9o0va3hiIhmlkw70voES';

my $mopidy = API::Mopidy->new(host => 'localhost');
helper mopidy => sub {
  $mopidy
  #state $mopidy = 
};

helper mopidy_init => sub {
  shift->mopidy
  ->on(error => sub { p $_[1]; })
  #->on(event => \&process_event)
    ->on(message => sub { say 'Mopidy message:'; p $_[0] })
    ->connect
    ->then(sub { return $_[0] })
    ->catch(sub { die 'Mopidy connection error' })
    ->wait;
};


helper jukebox_init => sub {
  my $c = shift;

  # Set consume mode (core.tracklist.consume = 1)
  $c->mopidy->send('tracklist.set_consume', [ \1 ]);

  $c->mopidy->send('library.lookup', [ BASE_PLAYLIST_URI ] => sub {
    p @_;
    die 'No base playlist found' if $_[0]->{error};
    #    $base_playlist = shift->{result};
    $c->maybe_add_new_track;
  });
};


helper maybe_add_new_track => sub {
  my $c = shift;

  warn 'get_length';
  # Add random track to tracklist (if tracklist length < 1)
  # Get tracklist length
  my $result = $c->mopidy->send('tracklist.get_length' => sub { p @_ });

  # my $length = $result->json->{result} if $result;
  # say "length: $length";
  # if ($length < 1) {
  #   warn 'tracklist.add';
  #   $result = $c->send_mopidy_message(
  #     'tracklist.add',
  #     { uri => $base_playlist->[int(rand $#$base_playlist)]{uri} },
  #   );
  #   p $result->json;
  # }

  # my $playback_state = $c->send_mopidy_message(
  #   'core.playback.get_state',
  #   [],
  # )->json->{result};
  # p $playback_state;

  # unless ($playback_state eq 'playing') {
  #   # Start playing
  #   $result = $c->send_mopidy_message(
  #     'core.playback.play',
  #     [],
  #   );
  # }

  # Listen for track_playback_ended event to check if another random track
  # needs to be added
  #
};

get '/' => sub {
  my $c = shift;
  $c->mopidy_init;
  $c->render_later;
  $c->mopidy->send('library.lookup', [ BASE_PLAYLIST_URI ] => sub {
      p @_;
      return $c->render(text => 'ok');
    });
};

app->secrets(['pIH #P #UP %gp h3*()P 890-y-9g -123gt5 -g u9jgg']);
#app->mopidy_init;
app->start;


