# $Id$

# Data and accessors to manage POE's events.

package POE::Resources::Events;

use vars qw($VERSION);
$VERSION = (qw($Revision$))[1];

# These methods are folded into POE::Kernel;
package POE::Kernel;

use strict;

# A local copy of the queue so we can manipulate it directly.
my $kr_queue;

my %event_count;
#  ( $session => $count,
#    ...,
#  );

my %post_count;
#  ( $session => $count,
#    ...,
#  );

### Begin-run initialization.

sub _data_ev_initialize {
  my ($self, $queue) = @_;
  $kr_queue = $queue;
}

### End-run leak checking.

sub _data_ev_finalize {
  my $finalized_ok = 1;
  while (my ($ses, $cnt) = each(%event_count)) {
    $finalized_ok = 0;
    warn "!!! Leaked event-to count: $ses = $cnt\n";
  }

  while (my ($ses, $cnt) = each(%post_count)) {
    $finalized_ok = 0;
    warn "!!! Leaked event-from count: $ses = $cnt\n";
  }
  return $finalized_ok;
}

### Enqueue an event.

sub _data_ev_enqueue {
  my ( $self,
       $session, $source_session, $event, $type, $etc, $file, $line,
       $time
     ) = @_;

  unless ($self->_data_ses_exists($session)) {
    confess
      "<ev> can't enqueue event ``$event'' for nonexistent session $session\n";
  }

  # This is awkward, but faster than using the fields individually.
  my $event_to_enqueue = [ @_[1..7] ];

  my $old_head_priority = $kr_queue->get_next_priority();
  my $new_id = $kr_queue->enqueue($time, $event_to_enqueue);

  if (TRACE_EVENTS) {
    warn( "<ev> enqueued event $new_id ``$event'' from ",
          $self->_data_alias_loggable($source_session), " to ",
          $self->_data_alias_loggable($session),
          " at $time"
        );
  }

  if ($kr_queue->get_item_count() == 1) {
    $self->loop_resume_time_watcher($time);
  }
  elsif ($time < $old_head_priority) {
    $self->loop_reset_time_watcher($time);
  }

  $self->_data_ses_refcount_inc($session);
  $event_count{$session}++;

  $self->_data_ses_refcount_inc($source_session);
  $post_count{$source_session}++;

  return $new_id;
}

### Remove events sent to or from a specific session.

sub _data_ev_clear_session {
  my ($self, $session) = @_;

  my $my_event = sub {
    ($_[0]->[EV_SESSION] == $session) || ($_[0]->[EV_SOURCE] == $session)
  };

  my $total_event_count =
    ( ($event_count{$session} || 0) +
      ($post_count{$session} || 0)
    );

  foreach ($kr_queue->remove_items($my_event, $total_event_count)) {
    $self->_data_ev_refcount_dec(@{$_->[ITEM_PAYLOAD]}[EV_SOURCE, EV_SESSION]);
  }
}

# -><- Alarm maintenance functions may move out to a separate
# POE::Resource module in the future.  Why?  Because alarms may
# eventually be managed by something other than the event queue.
# Especially if we incorporate a proper Session scheduler.  Be sure to
# move the tests to a corresponding t/res/*.t file.

### Remove a specific alarm by its name.  This is in the events
### section because alarms are currently implemented as events with
### future due times.

sub _data_ev_clear_alarm_by_name {
  my ($self, $session, $alarm_name) = @_;

  my $my_alarm = sub {
    return 0 unless $_[0]->[EV_TYPE] & ET_ALARM;
    return 0 unless $_[0]->[EV_SESSION] == $session;
    return 0 unless $_[0]->[EV_NAME] eq $alarm_name;
    return 1;
  };

  foreach ($kr_queue->remove_items($my_alarm)) {
    $self->_data_ev_refcount_dec(@{$_->[ITEM_PAYLOAD]}[EV_SOURCE, EV_SESSION]);
  }
}

### Remove a specific alarm by its ID.  This is in the events section
### because alarms are currently implemented as events with future due
### times.  -><- It's possible to remove non-alarms; is that wrong?

sub _data_ev_clear_alarm_by_id {
  my ($self, $session, $alarm_id) = @_;

  my $my_alarm = sub {
    $_[0]->[EV_SESSION] == $session;
  };

  my ($time, $id, $event) = $kr_queue->remove_item($alarm_id, $my_alarm);
  return unless defined $time;

  $self->_data_ev_refcount_dec( @$event[EV_SOURCE, EV_SESSION] );
  return ($time, $event);
}

### Remove all the alarms for a session.  Whoot!

sub _data_ev_clear_alarm_by_session {
  my ($self, $session) = @_;

  my $my_alarm = sub {
    return 0 unless $_[0]->[EV_TYPE] & ET_ALARM;
    return 0 unless $_[0]->[EV_SESSION] == $session;
    return 1;
  };

  my @removed;
  foreach ($kr_queue->remove_items($my_alarm)) {
    my ($time, $event) = @$_[ITEM_PRIORITY, ITEM_PAYLOAD];
    $self->_data_ev_refcount_dec( @$event[EV_SOURCE, EV_SESSION] );
    push @removed, [ $event->[EV_NAME], $time, @{$event->[EV_ARGS]} ];
  }

  return @removed;
}

### Decrement a post refcount

sub _data_ev_refcount_dec {
  my ($self, $source_session, $dest_session) = @_;

  confess $dest_session unless exists $event_count{$dest_session};
  confess $source_session unless exists $post_count{$source_session};

  $self->_data_ses_refcount_dec($dest_session);
  unless (--$event_count{$dest_session}) {
    delete $event_count{$dest_session};
  }

  $self->_data_ses_refcount_dec($source_session);
  unless (--$post_count{$source_session}) {
    delete $post_count{$source_session};
  }
}

### Fetch the number of pending events sent to a session.

sub _data_ev_get_count_to {
  my ($self, $session) = @_;
  return $event_count{$session} || 0;
}

### Fetch the number of pending events sent from a session.

sub _data_ev_get_count_from {
  my ($self, $session) = @_;
  return $post_count{$session} || 0;
}

### Dispatch events that are due for "now" or earlier.

sub _data_ev_dispatch_due {
  my $self = shift;

  if (TRACE_EVENTS) {
    foreach ($kr_queue->peek_items(sub { 1 })) {
      warn( "<ev> time($_->[ITEM_PRIORITY]) id($_->[ITEM_ID]) ",
            "event(@{$_->[ITEM_PAYLOAD]})\n"
          );
    }
  }

  my $now = time();
  while (defined(my $next_time = $kr_queue->get_next_priority())) {
    last if $next_time > $now;
    my ($time, $id, $event) = $kr_queue->dequeue_next();

    if (TRACE_EVENTS) {
      warn "<ev> dispatching event $id ($event->[EV_NAME])";
    }

    $self->_data_ev_refcount_dec($event->[EV_SOURCE], $event->[EV_SESSION]);
    $self->_dispatch_event(@$event, $time, $id);
  }
}

1;

__END__

=head1 NAME

POE::Resources::Events - manage events for POE::Kernel

=head1 SYNOPSIS

Used internally by POE::Kernel.  Better documentation will be
forthcoming.

=head1 DESCRIPTION

This module hides the complexity of managing POE's events from even
POE itself.  It is used internally by POE::Kernel and has no public
interface.

=head1 SEE ALSO

See L<POE::Kernel> for documentation on events.

=head1 BUGS

Probably.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
