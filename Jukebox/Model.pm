package Jukebox::Model;

use 5.024;

use Mojo::JSON::MaybeXS;
use Mojo::Base 'Mojo::EventEmitter', -signatures;
use API::Mopidy;
use Mojo::JSON qw(true false);
use Carp qw(croak);
use DDP;
use List::Util qw(reduce first);


use constant MOPIDY_HOST        => 'i7-arch';#'10.0.0.126';
use constant MOPIDY_PORT        => '6680';
use constant BASE_PLAYLIST_URI  =>
#'spotify:user:rage_311:playlist:6KC25FPNEbVdOSZYswg0lq';
  'spotify:user:rage_311:playlist:5u9o0va3hiIhmlkw70voES';

#my $reordering_tracklist = 0;
has manual_stop => 0;

has [qw( played tracklist votes base_playlist added )] => sub { {} };

has mopidy => sub ($self) {
  # state $mopidy;
  # return $mopidy if ref $mopidy eq 'API::Mopidy';

  my $mopidy = API::Mopidy->new(host => MOPIDY_HOST);
  p $mopidy;
  $mopidy->on(error   => sub { p $_[1]; });
  $mopidy->on(event   => sub { $self->process_event(pop) } );
  $mopidy->on(message => sub { say 'Mopidy message:'; p @_ });

  $mopidy->connect
    ->then (sub { say 'CONNECTED!' and return $_[0] })
    ->catch(sub { die 'Mopidy connection error'     })
    ->wait;

  return $mopidy;
};


sub new ($class) {
  my $self = $class->SUPER::new;

  p $self;

  # Set consume mode (core.tracklist.consume = 1)
  $self->mopidy->send('tracklist.set_consume', [ true ]);

  $self->mopidy->send('library.lookup', [ BASE_PLAYLIST_URI ] => sub {
    die 'No base playlist found' if $_[0]->{error};
    $self->base_playlist(shift->{result});
    p $self->base_playlist;
    $self->maybe_add_new_track;
  });

  $self->play_if_stopped;
  $self->get_tracklist;

  return $self;
}


sub process_event ($self, $event) {
  say 'process_event:';

  say 'EVENT:';
  p $event;

  warn "event: $event->{event}";
  if ($event->{event} eq 'tracklist_changed') {# && $reordering_tracklist == 0) {
    $self->maybe_add_new_track;
    $self->get_tracklist;
    #$self->emit(tracklist_changed => []);
  }
  elsif ($event->{event} eq 'track_playback_ended')# ||
      # ($event->{event} eq 'playback_state_changed' &&
      #  $event->{new_state} eq 'stopped' &&
      #  $event->{old_state} eq 'playing'))
  {
    #app->maybe_add_new_track;
  }

  #p $clients;
  #$_->send({ json => $json }) for values %$clients;
}


sub play_if_stopped ($self) {
  $self->mopidy->send('playback.get_state' => sub {
    my $playback_state = shift->{result};
    p $playback_state;

    return if $playback_state ne 'stopped';
    # Start playing
    $self->mopidy->send('playback.play') unless $self->manual_stop;
  });
}


sub maybe_add_new_track ($self) {
  warn 'get_length';

  # Add random track to tracklist (if tracklist length < 1)
  # Get tracklist length
  $self->mopidy->send('tracklist.get_length')->then(sub {
      say 'GOT length:';
      p @_;
      my $length = shift->{result} // 0;
      say "length: $length";
      return $length unless $length < 1;

      warn 'tracklist.add';
      $self->mopidy->send(
        'tracklist.add',
        { uri =>
            $self->base_playlist->[int(rand $#{$self->base_playlist})]{uri} },
        sub { $self->play_if_stopped },
      );
    })->catch(sub { say 'error getting length' });

  # Listen for track_playback_ended event to check if another random track
  # needs to be added
  #
}


sub add_track ($self, %params) {
  warn 'add_new_track';
  warn 'Requires uri, user, and ip' and return unless
    $params{uri} && $params{user} && $params{ip};

  warn 'tracklist.add';

  return $self->mopidy->send('tracklist.add', { uri => $params{uri} });
    # ->then(sub {
    #   say 'ADDING A TRACK PROMISE RESOLUTION';
    #   $self->get_tracklist()
    #   $self->vote_by_uri(
    #     uri  => $params{uri},
    #     user => $params{user},
    #     ip   => $params{ip},
    #   );
  # });
}


sub get_tlid_from_uri ($self, $uri) {
  return (first { $_->{uri} eq $uri } reverse $self->tracklist->{array}->@*)->{tlid};
}


sub vote_by_uri ($self, %params) {
  my ($uri, $user, $ip) = @params{qw(uri user ip)};

  warn "Unable to get tlid from uri: $uri" and return unless
    my $tlid = $self->get_tlid_from_uri($uri);

  say "vote_by_uri got tlid: $tlid";

  my $vote = $self->votes->{$tlid}{$ip} = {
    ip    => $ip,
    value => 1,
    # TODO: make this user-entered
    user  => 'matt',
    time  => time,
  };

  my $ordered_tracklist = $self->order_tracklist_by_votes;

  say (my $from_index = $self->tracklist_index($tlid));
  say "New index: ", $self->tracklist_index($tlid, $ordered_tracklist);
  return $self->move_track(
    $self->tracklist_index($tlid),
    $self->tracklist_index($tlid, $ordered_tracklist)
  );
}


# Join artists[] names into a comma-separated string
sub make_artists_string ($self, $artists) {
  croak '$artists is not array ref' unless ref $artists eq ref [];

  return join ', ', map { $_->{name} } @$artists;
}


sub search ($self, %params) {#$type, $text) {
  warn "search";

  return unless $params{type} && $params{text} && $params{id};

  # type can be one of:
  # uri, track_name, album, artist, albumartist, composer, performer, track_no, genre, date, comment or any.
  my $search = {
    uris  => ['spotify:'],
    query => {
      $params{type} => [ $params{text} ],
    },
  };

  $self->mopidy->send('library.search', $search => sub ($result) {
    #return unless my $result = shift->{result};
    $self->emit(search_result => { request_id => $params{id}, data => $result });
  });
}


# Call when tracklist_changed event occurs
sub get_tracklist ($self) {
  warn "get_tracklist";

  $self->mopidy->send('tracklist.get_tl_tracks' => sub {
    return unless (my $result = shift->{result});
    #p $result;

    $self->populate_tracklist($result);
  });

  return {};
}


sub populate_tracklist ($self, $result) {
  say 'populate_tracklist';

  croak '$result is not array ref' unless ref $result eq ref [];

  my $tracklist_array = [];
  my $tracklist_hash  = {};

  for (@$result) {
    $self->votes->{$_->{tlid}} = $self->votes->{$_->{tlid}} // {};

    my $track = {
      artist_string => $self->make_artists_string($_->{track}{artists}),
      title         => $_->{track}{name},
      album_title   => $_->{track}{album}{name},
      album_date    => $_->{track}{album}{date},
      tlid          => $_->{tlid},
      length        => $_->{track}{length},
      uri           => $_->{track}{uri},
      votes         => $self->votes->{$_->{tlid}},
    };

    push @$tracklist_array, $track;
    $tracklist_hash->{$_->{tlid}} = $track;
  }

  # Delete old vote references (songs that have been played or deleted)
  for (keys %$tracklist_hash) {
    delete $self->votes->{$_} unless $tracklist_hash->{$_};
  }

  $self->tracklist->{array} = $tracklist_array;
  $self->tracklist->{hash}  = $tracklist_hash;

  #my $ordered_tracklist = $c->order_tracklist_by_votes;
  #$c->reorder_mopidy_tracklist($ordered_tracklist);
  $self->emit(tracklist_changed => $tracklist_array);
}


sub order_tracklist_by_votes ($self) {#, $tlid = undef) {
  my $ordered_tracklist = [
    # Return track itself
    map  { $_->[0] }

    # Sort by vote total, then by oldest timestamp
    sort { $b->[1] <=> $a->[1] || $a->[2] <=> $b->[2] }

    # Creates array ref of obj, vote_total, oldest_timestamp arrays
    map  {
      my @votes = values $_->{votes}->%*;

      my $vote_sum = reduce {
        $a + $b->{value}
      } 0, @votes;

      my $oldest_time = reduce {
        $a < $b->{time} ? $a : $b->{time}
      } 9999999999, @votes;
      #say $oldest_time;

      [ $_, $vote_sum, $oldest_time ]
    } @{$self->tracklist->{array}}[1..$#{$self->tracklist->{array}}]
  ];

  unshift @$ordered_tracklist, $self->tracklist->{array}[0];

  warn 'ordered_tracklist';
  p $ordered_tracklist;
  #$master_tracklist->{array} = $ordered_tracklist;
  return $ordered_tracklist;
}


sub vote ($self, %params) {
  my ($ip, $tlid, $value, $user) = @params{qw(ip tlid value user users)};

  # Use Mojo's validator instead
  $value //=  0;
  $value   = -1 if $value < -1;
  $value   =  1 if $value > 1;
  # $value == 0 is toggle?

  #my $votes_ref = $votes->{$tlid}{votes};#master_tracklist->{hash}{$tlid}{votes};
  #return $c->render(
  #  json => {error => 'unable to retrieve votes (track may not be in TL any more'}
  #) unless defined $votes_ref;

  my $vote = {};

  # Check if the IP has a vote for this tlid already
  # and the new vote value is the same as the prev
  if (defined $self->votes->{$tlid}{$ip} &&
      $self->votes->{$tlid}{$ip}{value} == $value
  ) {
    delete $self->votes->{$tlid}{$ip};
  }
  else {
    $vote = $self->votes->{$tlid}{$ip} = {
      ip    => $ip,
      value => $value,
      # TODO: make this user-entered
      user  => 'matt',
      time  => time,
    };
    p $vote;
    # $vote->{value} = $vote->{value} == $value ? 0 : $value;
    # $vote->{time} = time;
  }

  #p $votes;

  my $ordered_tracklist = $self->order_tracklist_by_votes;
  #p $ordered_tracklist;
  say (my $from_index = $self->tracklist_index($tlid));
  say "New index: ", $self->tracklist_index($tlid, $ordered_tracklist);
  return $self->move_track(
    $self->tracklist_index($tlid),
    $self->tracklist_index($tlid, $ordered_tracklist)
  );
  #return 1;
  #$self->order_tracklist($tlid);
}


sub tracklist_index ($self, $tlid, $tracklist = undef) {
  my $tl = $tracklist // $self->tracklist->{array};
  # for my $i (0 .. $#{$self->tracklist->{array}}) {
  for my $i (0 .. $#{$tl}) {
    #return $i if $self->tracklist->{array}[$i]{tlid} == $tlid;
    return $i if $tl->[$i]{tlid} == $tlid;
  }
}


sub move_track ($self, $from_idx, $to_idx) {
  my $result = $self->mopidy->send(
    'tracklist.move',
    {
      start       => $from_idx,
      end         => $from_idx,
      to_position => $to_idx,
    }
  );
  #p $result->json;

  1;
}


#sub order_tracklist ($self, $tlid) {
  #my $ordered_tracklist = $self->order_tracklist_by_votes;

  ##$master_tracklist->{hash}{$tlid};

  #my ($current_idx, $move_to_idx);
  #for (my $i = 0; $i < $self->tracklist->{array}->@*; $i++) {
  #  if ($self->tracklist->{array}[$i]{tlid}) {
  #    $current_idx = $i;
  #    last;
  #  }
  #}

  #for (my $i = 0; $i < @$ordered_tracklist; $i++) {
  #  if ($ordered_tracklist->[$i]{tlid}) {
  #    $move_to_idx = $i;
  #    last;
  #  }
  #}

#   unless ($current_idx == $move_to_idx) {
#     my $result = $self->mopidy->send(
#       'tracklist.move',
#       {
#         start       => $current_idx,
#         end         => $current_idx,
#         to_position => $move_to_idx,
#       }
#     );
#     p $result->json;
#   }

  #$c->reorder_mopidy_tracklist($ordered_tracklist);

  # TODO: only move track that was voted on -- need old position, new position
  #$c->send_tracklist;
  #return 1;
  #$c->render(text => $value);
# }

sub reorder_mopidy_tracklist ($self, $ordered_tracklist) {
  #my $track (@{$ordered_tracklist}[1..$#{master_tracklist->{array}}) {

  my %tlid_order = map {
    #p $_;
    ($ordered_tracklist->[$_]{tlid} => $_)
  } 1..$#{$ordered_tracklist};

  say 'TLID_ORDER';
  p %tlid_order;

  for (my $i = 1; $i < $self->tracklist->{array}->@*; $i++) {
    my $to_position = $tlid_order{$self->tracklist->{array}[$i]{tlid}};

    my $thing = {
        start       => $i,
        end         => $i,
        to_position => $to_position,
      };

    p $thing;

    if ($i != $to_position) {
      my $result = $self->mopidy->send(
        'tracklist.move',
        {
          start       => $i,
          end         => $i,
          to_position => $to_position,
        }
      );
      p $result->json;
    }
  }
};



1;

