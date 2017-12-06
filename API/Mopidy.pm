package API::Mopidy;

use 5.026;
use Mojo::Base 'Mojo::EventEmitter', -signatures;

# use feature qw( signatures );
# no warnings qw( experimental::signatures );

use Mojo::UserAgent;
use Mojo::URL;
use Mojo::Promise;
use Mojo::Util 'monkey_patch';
use Mojo::JSON qw(to_json from_json);
use Carp 'croak';
use DDP;

# use constant MOPIDY_IP          => '10.0.0.121';
# use constant MOPIDY_PORT        => '6680';
# use constant BASE_PLAYLIST_URI  =>
#   'spotify:user:rage_311:playlist:5u9o0va3hiIhmlkw70voES';

has ua => sub { state $ua = Mojo::UserAgent->new->inactivity_timeout(0) };
has ws => sub { state $ws = Mojo::Transaction->new };
has [qw( host port )];

has queue => sub { state $cb = {} };

has url => sub {
  Mojo::URL->new
    ->scheme('ws')
    ->host($_[0]->host)
    ->port($_[0]->port)
    ->path('/mopidy/ws');
};

has options => sub {
  {
    consume => 0,
  }
};

#sub queue { state $cb = {} };

sub new ($class, %options) {
  p %options;

  croak 'Requires host' unless $options{host};# && $options->{port};

  my $self = $class->SUPER::new;

  $self->host($options{host});
  $self->port($options{port} // 6680);

  #$self->url($options);
  p $self->url;

  #croak "Unable to connect to mopidy: $!" unless $self->ws($self->_ws_connect);

  p $self;
  return $self;
}


sub _message_id { state $id = -1; ++$id };



sub connect ($self) {
  my $p = Mojo::Promise->new;

  $self->ua->websocket($self->url => sub ($ua, $tx) {
    return $p->reject('WebSocket handshake failed') unless $tx->is_websocket;

    # needed for full base playlist size -- not sure what limit it really needs
    $tx->max_websocket_size(2621440);

    $tx->on(finish => sub {
      my ($tx, $code, $reason) = @_;
      say "WebSocket closed with status $code.";
      $self->emit(disconnected => $code);
    });

    $tx->on(json => sub {
      my ($tx, $json) = @_;

      # event
      if ($json->{event}) {
        #$self->emit($json->{event} => $json);
        $self->emit(event => $json);
      }

      # response to message
      # successful message response
      elsif ($json->{jsonrpc} && defined $json->{id}) {
        #$self->patch_yoself($json) if $json->{id} eq 'core.describe';
        $self->emit(error => $json) if $json->{error};
        $self->emit(message => $json);

        (delete $self->queue->{$json->{id}})->{cb}->($json)
          if defined $self->queue->{$json->{id}};

          #p $self->queue;
      }
    });


    $self->ws($tx);
    $self->emit(connected => $tx);
    #$self->message(method => 'core.describe', id => 'core.describe');
    $p->resolve($self, $tx);
  });

  return $p;
}


#TODO: call core.describe to get known methods for mopidy endpoint

# send message to mopidy
sub send { #($self, $method = '', $params = {}, $cb = sub {}) {
  my $self = shift;
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;

  say 'SEND:';
  p @_;

  my ($method, $params) = @_;

  return $self->emit(error => { message => 'No method specified' })
    unless $method;

  $method =~ s/^core\.//;

  my $message_id = $self->_message_id;

  my $mopidy_json = {
    id      => $message_id,
    jsonrpc => '2.0',
    method  => 'core.' . $method,
    params  => $params // {},
  };

  unless ($self->ws->is_websocket && $self->ws->established) {
    say 'CONNECTING...';
    $self->connect->then(sub { p @_ })->wait;
  }
  #p $self->ws;

  return $self->emit(error => { message => 'Not a websocket' })
    unless $self->ws->is_websocket;

  $self->ws->send({ json => $mopidy_json });

  $self->queue->{$message_id} = { cb => $cb, time => time } if $cb;

  $self->clean_queue;

  return $message_id;
}


sub clean_queue ($self, $older_than = 60) {
  # remove old entries in queue
  delete $self->queue->{$_} for
    grep {
      time - $self->queue->{$_}{time} > $older_than
    } keys $self->queue->%*;

    #p $self->queue;

  return 1;
};












# sub _patch_yoself ($self, $json) {
#   for my $mopidy_method (keys $json->{result}->%*) {
#     (my $sub_name = substr($mopidy_method, length 'core.')) =~ s/\./_/g;
#     say $sub_name;

#     monkey_patch 'API::Mopidy',
#       $sub_name => sub {
#         my $self = shift;
#         my %params = @_;
#         $self->message(method => $mopidy_method, %params);
#       };
#   }

#   p $self;
# }



1;

