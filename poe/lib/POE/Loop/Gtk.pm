# $Id$

# Gtk-Perl event loop bridge for POE::Kernel.

# Empty package to appease perl.
package POE::Kernel::Gtk;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

# Everything plugs into POE::Kernel.
package POE::Kernel;

use strict;

# Delcare which event loop bridge is being used, but first ensure that
# no other bridge has been loaded.

BEGIN {
  die( "POE can't use Gtk and " . &POE_LOOP . "\n" )
    if defined &POE_LOOP;
};

# Declare the loop we're using.
sub POE_LOOP () { LOOP_GTK }

my $_watcher_timer;
my @fileno_watcher;

my ($kr_sessions, $kr_events);

#------------------------------------------------------------------------------
# Loop construction and destruction.

sub loop_initialize {
  my $kernel = shift;
  $kr_sessions = $kernel->_get_kr_sessions_ref();
  $kr_events   = $kernel->_get_kr_events_ref();

  Gtk->init;
}

sub loop_finalize {
  for (0..$#fileno_watcher) {
    warn "Watcher for fileno $_ is allocated during loop finalize"
      if defined $fileno_watcher[$_];
  }
}

#------------------------------------------------------------------------------
# Signal handlers/callbacks.

sub _loop_signal_handler_generic {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing generic SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
  $SIG{$_[0]} = \&_loop_signal_handler_generic;
}

sub _loop_signal_handler_pipe {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing PIPE-like SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
    $SIG{$_[0]} = \&_loop_signal_handler_pipe;
}

# Special handler.  Stop watching for children; instead, start a loop
# that polls for them.
sub _loop_signal_handler_child {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing CHLD-like SIG$_[0] event...\n";
  $SIG{$_[0]} = 'DEFAULT';
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL,
      [ ],
      time(), __FILE__, __LINE__
    );
}

#------------------------------------------------------------------------------
# Signal handler maintenance functions.

sub loop_watch_signal {
  my $signal = shift;

  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {

    # For SIGCHLD triggered polling loop.
    # $SIG{$signal} = \&_loop_signal_handler_child;

    # Begin constant polling loop.  Only start it on CHLD or on CLD if
    # CHLD doesn't exist.
    $SIG{$signal} = 'DEFAULT';
    $poe_kernel->_enqueue_event
      ( $poe_kernel, $poe_kernel,
        EN_SCPOLL, ET_SCPOLL,
        [ ],
        time() + 1, __FILE__, __LINE__
      ) if $signal eq 'CHLD' or not exists $SIG{CHLD};

    return;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    $SIG{$signal} = \&_loop_signal_handler_pipe;
    return;
  }

  # Artur Bergman (sky) noticed that xterm resizing can generate a LOT
  # of WINCH signals.  That rapidly crashes perl, which, with the help
  # of most libc's, can't handle signals well at all.  We ignore
  # WINCH, therefore.
  return if $signal eq 'WINCH';

  # Everything else.
  $SIG{$signal} = \&_loop_signal_handler_generic;
}

sub loop_resume_watching_child_signals {
  # For SIGCHLD triggered polling loop.
  # $SIG{CHLD} = \&_loop_signal_handler_child if exists $SIG{CHLD};
  # $SIG{CLD}  = \&_loop_signal_handler_child if exists $SIG{CLD};

  # For constant polling loop.
  $SIG{CHLD} = 'DEFAULT' if exists $SIG{CHLD};
  $SIG{CLD}  = 'DEFAULT' if exists $SIG{CLD};
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL,
      [ ],
      time() + 1, __FILE__, __LINE__
    ) if keys(%$kr_sessions) > 1;
}

sub loop_ignore_signal {
  my $signal = shift;
  $SIG{$signal} = "DEFAULT";
}

# This function sets us up a signal when whichever window is passed to
# it closes.
sub signal_ui_destroy {
  my ($self, $window) = @_;

  # Don't bother posting the signal if there are no sessions left.  I
  # think this is a bit of a kludge: the situation where a window
  # lasts longer than POE::Kernel should never occur.
  $window->signal_connect
    ( delete_event =>
      sub {
        if (keys %{$self->[KR_SESSIONS]}) {
          $self->_dispatch_event
            ( $self, $self,
              EN_SIGNAL, ET_SIGNAL, [ 'UIDESTROY' ],
              time(), __FILE__, __LINE__, undef
            );
        }
        return undef;
      }
    );
}

#------------------------------------------------------------------------------
# Maintain time watchers.

sub loop_resume_time_watcher {
  my $next_time = (shift() - time) * 1000;
  $next_time = 0 if $next_time < 0;
  $_watcher_timer = Gtk->timeout_add($next_time, \&_loop_event_callback);
}

sub loop_reset_time_watcher {
  my $next_time = shift;
  # Should always be defined, right?
  Gtk->timeout_remove($_watcher_timer);
  undef $_watcher_timer;
  loop_resume_time_watcher($next_time);
}

sub _loop_resume_timer {
  Gtk->idle_remove($_watcher_timer);
  loop_resume_time_watcher($poe_kernel->[KR_EVENTS]->[0]->[ST_TIME]);
}

sub loop_pause_time_watcher {
  # does nothing
}

#------------------------------------------------------------------------------
# Maintain filehandle watchers.

sub loop_watch_filehandle {
  my ($kr_fno_vec, $handle, $vector) = @_;
  my $fileno = fileno($handle);

  # Overwriting a pre-existing watcher?
  if (defined $fileno_watcher[$fileno]) {
    Gtk::Gdk->input_remove($fileno_watcher[$fileno]);
    undef $fileno_watcher[$fileno];
  }

  # Register the new watcher.
  $fileno_watcher[$fileno] =
    Gtk::Gdk->input_add( $fileno,
                         ( ($vector == VEC_RD)
                           ? ( 'read',
                               \&_loop_select_read_callback
                             )
                           : ( ($vector == VEC_WR)
                               ? ( 'write',
                                   \&_loop_select_write_callback
                                 )
                               : ( 'exception',
                                   \&_loop_select_expedite_callback
                                 )
                             )
                         ),
                         $fileno
                       );

  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_RUNNING;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;
}

sub loop_ignore_filehandle {
  my ($kr_fno_vec, $handle, $vector) = @_;
  my $fileno = fileno($handle);

  # Don't bother removing a select if none was registered.
  if (defined $fileno_watcher[$fileno]) {
    Gtk::Gdk->input_remove($fileno_watcher[$fileno]);
    undef $fileno_watcher[$fileno];
  }
  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_STOPPED;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_STOPPED;
}

sub loop_pause_filehandle_watcher {
  my ($kr_fno_vec, $handle, $vector) = @_;
  my $fileno = fileno($handle);

  Gtk::Gdk->input_remove($fileno_watcher[$fileno]);
  undef $fileno_watcher[$fileno];
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_PAUSED;
}

sub loop_resume_filehandle_watcher {
  my ($kr_fno_vec, $handle, $vector) = @_;
  my $fileno = fileno($handle);

  # Quietly ignore requests to resume unpaused handles.
  return 1 if defined $fileno_watcher[$fileno];

  $fileno_watcher[$fileno] =
    Gtk::Gdk->input_add( $fileno,
                         ( ($vector == VEC_RD)
                           ? ( 'read',
                               \&_loop_select_read_callback
                             )
                           : ( ($vector == VEC_WR)
                               ? ( 'write',
                                   \&_loop_select_write_callback
                                 )
                               : ( 'exception',
                                   \&_loop_select_expedite_callback
                                 )
                             )
                         ),
                         $fileno
                       );
  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_RUNNING;
}

### Callbacks.

# Event callback to dispatch pending events.
sub _loop_event_callback {
  my $self = $poe_kernel;

  dispatch_due_events();
  test_for_idle_poe_kernel();

  Gtk->timeout_remove($_watcher_timer);
  undef $_watcher_timer;

  # Register the next timeout if there are events left.
  if (@$kr_events) {
    $_watcher_timer = Gtk->idle_add(\&_loop_resume_timer);
  }

  # Return false to stop.
  return 0;
}

# Filehandle callback to dispatch selects.
sub _loop_select_read_callback {
  my $self = $poe_kernel;
  my ($handle, $fileno, $hash) = @_;

  enqueue_ready_selects($fileno, VEC_RD);
  test_for_idle_poe_kernel();

  # Return false to stop... probably not with this one.
  return 0;
}

sub _loop_select_write_callback {
  my $self = $poe_kernel;
  my ($handle, $fileno, $hash) = @_;

  enqueue_ready_selects($fileno, VEC_WR);
  test_for_idle_poe_kernel();

  # Return false to stop... probably not with this one.
  return 0;
}

sub _loop_select_expedite_callback {
  my $self = $poe_kernel;
  my ($handle, $fileno, $hash) = @_;

  enqueue_ready_selects($fileno, VEC_EX);
  test_for_idle_poe_kernel();

  # Return false to stop... probably not with this one.
  return 0;
}

#------------------------------------------------------------------------------
# The event loop itself.

sub loop_do_timeslice {
  die "doing timeslices currently not supported in the Gtk loop";
}

sub loop_run {
  Gtk->main;
}

sub loop_halt {
  Gtk->main_quit();
}

1;
