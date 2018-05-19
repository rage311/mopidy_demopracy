package API::Mopidy;

use 5.024;

use Mojo::JSON::MaybeXS;
use Mojo::Base 'Mojo::EventEmitter', -signatures;
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::Promise;
use Carp qw(carp croak);
use DDP;

has 'ua'   => sub { state $ua = Mojo::UserAgent->new->inactivity_timeout(0) };
has 'ws';
has 'host' => sub { croak 'host is required' };
has 'port';

has queue => sub { state $cb = {} };

has url => sub {
  Mojo::URL->new
    ->scheme('ws')
    ->host($_[0]->host)
    ->port($_[0]->port // 6680)
    ->path('/mopidy/ws');
};

has options => sub {
  {
    consume => 0,
  }
};


sub _message_id { state $id = -1; ++$id };


sub connect ($self) {
  my $p = Mojo::Promise->new;

  $self->ua->websocket($self->url => sub ($ua, $tx) {
    return $p->reject('WebSocket handshake failed') unless $tx->is_websocket;

    # needed for full base playlist size -- not sure what limit it really needs
    $tx->max_websocket_size(2621440);

    $tx->on(finish => sub ($tx, $code, $reason) {
      say "WebSocket closed with status $code.";
      $self->emit(disconnected => $code);
    });

    $tx->on(json => sub { $self->_ws_json(@_) });

    $self->ws($tx);
    $self->emit(connected => $tx);
    #$self->message(method => 'core.describe', id => 'core.describe');
    $p->resolve($self, $tx);
  });

  return $p;
}


sub _ws_json ($self, $tx, $json) {
  say 'API::Mopidy _ws_json: emit event' and
    return $self->emit(event => $json) if $json->{event};
  #$self->emit($json->{event} => $json);

  $self->emit(message => $json);

  # response to message
  if ($json->{jsonrpc} && defined $json->{id}) {
    if (my $q_item = delete $self->queue->{$json->{id}}) {
      $self->emit(error => $json) if $json->{error};

      # code callback
      return $q_item->{cb}->($json) if ref $q_item->{cb} eq 'CODE';

      # promise callback
      return $q_item->{cb}->reject($json) if $json->{error};

      return $q_item->{cb}->resolve($json);
    } else {
      carp 'message id not found in queue';
      return;
    }
  }

  #$self->patch_yoself($json) if $json->{id} eq 'core.describe';

  say 'unknown _ws_json message:';
  p $json;
}


#TODO: call core.describe to get known methods for mopidy endpoint

# send message to mopidy
# method, params, callback
sub send { #($self, $method = '', $params = {}, $cb = sub {}) {
  my $self = shift;
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;

  # say 'SEND:';
  # p @_;

  # say 'CB:';
  # p $cb;

  my ($method, $params) = @_;

  #return $self->emit(error => { message => 'No method specified' })
  croak 'No method specifed' unless $method;

  $method =~ s/^core\.//;

  unless ($self->ws->is_websocket && $self->ws->established) {
    say 'CONNECTING...';
    $self->connect->then(sub { p @_ })->wait;
  }
  #p $self->ws;

  return $self->emit(error => { message => 'Unable to connect to mopidy ws' })
    unless $self->ws->is_websocket && $self->ws->established;

  my $message_id = $self->_message_id;

  my $mopidy_json = {
    id      => $message_id,
    jsonrpc => '2.0',
    method  => 'core.' . $method,
    params  => $params // {},
  };

  $self->ws->send({ json => $mopidy_json });

  my $p = Mojo::Promise->new;

  $self->queue->{$message_id} = {
    cb   => $cb // $p, #sub { $p->resolve(shift) },
    time => time,
  };

  $self->clean_queue;

  return $cb ? $message_id : $p;
}


sub clean_queue ($self, $older_than = 60) {
  # remove old entries in queue
  delete $self->queue->{$_} for
    grep {
      time - $self->queue->{$_}{time} > $older_than
    } keys $self->queue->%*;
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

