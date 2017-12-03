#!/usr/bin/env perl

use 5.026;
use strict;
use warnings;

BEGIN { unshift @INC, './' };

use API::Mopidy;

use DDP;


sub callback {
  #p @_;
  say "callback for $_[0]->{id}";
  # my $message = shift;
  # p $message;
  say 'CALLBACK ^^';
}


my $mopidy = API::Mopidy->new(host => 'localhost');

$mopidy->on(message => sub {
  say "message for you, sir: id $_[1]->{id}";
  #p @_;
});

$mopidy->on(event => sub {
  say 'EVENT:';
  p $_[1];
});

$mopidy->on(error => sub {
  say 'ERROR:';
  p $_[1];
});

$mopidy->connect->then(sub { p @_ })->wait;

say $mopidy->message('tracklist.get_tl_tracks', \&callback);
say $mopidy->message('tracklist.get_tl_tracks', \&callback);
say $mopidy->message('tracklist.get_tl_tracks', \&callback);
say $mopidy->message('oiwht.ohwt', \&callback);
say $mopidy->message(\&callback);

$mopidy->message(
  'library.search', {
    uris    => ['spotify:'],
    query   => {
      track_name => [ 'love in high places' ],
      #track_name           => [ 'love' ],
    },
  } => sub { p shift->{result} }
);

#$mopidy->tracklist_get_tl_tracks;
#say $mopidy->your_mom;
  # ->then(sub { p @_; $_[1]->send('hello') })
  # ->catch(sub { say shift })->wait;


Mojo::IOLoop->start;


