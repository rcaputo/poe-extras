# $Id$

# This is a `perl -d` debugger module that simply traces execution.
# It's optional, and it may not even work.

package Trace; # satisfies 'use'

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

package DB;
use vars qw($sub @args);

use POSIX;

sub CALL_COUNT  () { 0 }
sub SUB_NAME    () { 1 }
sub SOURCE_CODE () { 2 }

my %statistics;
my $signal_set;

BEGIN {
  unlink "$0.coverage";
  open STATS, ">$0.coverage" or die "can't write $0.coverage: $!";
  $signal_set = POSIX::SigSet->new();
  $signal_set->fillset();
};

# &DB is called for every breakpoint that's encountered.  We use it to
# track which code is instrumented during a given program run.

sub DB {
    # Try to block signal delivery while this is recording information.
    # -><- Was causing trouble in the signals tests.  Commented out.
    #sigprocmask( SIG_BLOCK, $signal_set );

    my ($package, $file, $line) = caller;

    # Skip lines that aren't in the POE namespace.  Skip lines in files
    # ending with ] (they're evals).
    return if
      ( substr($package, 0, 3) ne 'POE' or
        index($file, 'POE') < $[ or substr($file, -1) eq ']'
      );

    # Gather a statistic for this line.
    $statistics{$file}->{$line} = [ 0, '(uninitialized)', '(uninitialized)' ]
      unless exists $statistics{$file}->{$line};
    $statistics{$file}->{$line}->[CALL_COUNT]++;

    # Unblock signals now that we're done.
    # -><- Was causing trouble in the signals tests.  Commented out.
    #sigprocmask( SIG_UNBLOCK, $signal_set );
}

# &sub is a proxy function that's used to trace function calls.  It's
# not used for anything, and things either run better or worse without
# it depending on some kinda voodoo I have no control over or idea how
# works.  Today it seems to work better commented out.

# sub sub { no strict 'refs'; &$sub }

# After all's said and done, say what's done.

END {

  # Gather breakable lines for every file visited.  This is done at
  # the end since doing it at the beginning means some lines aren't
  # visible.

  foreach my $file (keys %statistics) {
    my $sub_name = '(unknown)';
    for (my $line=1; $line<@{$::{"_<$file"}}; $line++) {
      my $source = $::{"_<$file"}->[$line];

      $source = "(undefined)" unless defined $source;

      if ($source =~ /^sub\s+(\S+)/) {
        $sub_name = $1;
      }

      $statistics{$file}->{$line} = [ 0, '(uninitialized)', '(uninitialized)' ]
        unless exists $statistics{$file}->{$line};

      # Here there be magic.
      { local $^W = 0;
        if ($::{"_<$file"}->[$line]+0) {
          my $source = $::{"_<$file"}->[$line];
          chomp $source;
          $statistics{$file}->{$line}->[SUB_NAME]    = $sub_name;
          $statistics{$file}->{$line}->[SOURCE_CODE] = $source;
        }
      }

      if ($source =~ /^\}/) {
        $sub_name = '(unknown)';
      }
    }
  }

  foreach my $file (sort keys %statistics) {
    foreach my $line (sort { $a <=> $b } keys %{$statistics{$file}}) {
      print( STATS "$file\t$line\t",
             $statistics{$file}->{$line}->[CALL_COUNT], "\t",
             $statistics{$file}->{$line}->[SUB_NAME], "\t",
             $statistics{$file}->{$line}->[SOURCE_CODE], "\n"
           );
    }
  }
  close STATS;
};

1;
