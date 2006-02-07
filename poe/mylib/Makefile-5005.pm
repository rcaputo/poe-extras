#!/usr/bin/perl
# $Id$

use strict;

use ExtUtils::MakeMaker;

use lib qw(./mylib);
use PoeBuildInfo qw(
  CLEAN_FILES
  CORE_REQUIREMENTS
  DIST_ABSTRACT
  DIST_AUTHOR
  RECOMMENDED_TIME_HIRES
);

### Touch files that will be generated at "make dist" time.
### ExtUtils::MakeMaker and Module::Build will complain about them if
### they aren't present now.

open(TOUCH, ">>CHANGES") and close TOUCH;
open(TOUCH, ">>META.yml") and close TOUCH;

### Some advisory dependancy testing.

sub check_for_modules {
  my ($dep_type, @modules) = @_;

  my @failures;
  while (@modules) {
    my $module  = shift @modules;
    my $target  = shift @modules;

    my $version = eval "use $module; return \$$module\::VERSION";

    if ($@) {
      push(
        @failures,
        "***   $module $target could not be loaded.\n"
      );
    }
    elsif ($version < $target) {
      push(
        @failures,
        "***   $module $target is $dep_type, " .
        "but version $version is installed.\n"
      );
    }
  }

  if (@failures) {
    warn(
      "*** Some $dep_type features may not be available:\n",
      @failures,
    );
  }
}

check_for_modules("required", CORE_REQUIREMENTS);
check_for_modules(
  "optional",
  "Compress::Zlib"  => 1.33,
  "Curses"          => 1.08,
  "Event"           => 1.00,
  "Gtk"             => 0.7009,
  "IO::Poll"        => 0.01,
  "IO::Pty"         => 1.02,
  "LWP"             => 5.79,
  "Socket6"         => 0.14,
  "Storable"        => 2.12,
  "Term::Cap"       => 1.09,
  "Term::ReadKey"   => 2.21,
  RECOMMENDED_TIME_HIRES,
  "Tk"              => 800.027,
  "URI"             => 1.30,
  (
    ($^O eq "MSWin32")
    ? (
      "Win32::Console" => 0.031,
      "Win32API::File" => 0.05,
    )
    : ()
  ),
);

### Generate dynamic test files.

system($^X, "mylib/gen-tests.perl") and die "couldn't generate tests: $!";

### Generate Makefile.PL.

# sub MY::postamble {
#   return ExtUtils::AutoInstall::postamble() .
#     <<EOF;
# reportupload: poe_report.xml
# \cI$^X mylib/reportupload.pl
# 
# uploadreport: poe_report.xml
# \cI$^X mylib/reportupload.pl
# 
# testreport: poe_report.xml
# 
# poe_report.xml: Makefile
# \cI$^X mylib/testreport.pl
sub MY::postamble {
  return <<EOF;

ppmdist: pm_to_blib
\cI\$(TAR) --exclude '*/man[13]*' -cvf \\
\cI\cI\$(DISTVNAME)-win32ppd.tar blib
\cI\$(COMPRESS) \$(DISTVNAME)-win32ppd.tar

ppddist: ppmdist

coverage: Makefile
\cI$^X mylib/coverage.perl

cover: coverage
EOF
}

WriteMakefile(
  NAME           => 'POE',

  (
    ($^O eq 'MacOS')
    ? ()
    : ( AUTHOR   => DIST_AUTHOR,
        ABSTRACT => DIST_ABSTRACT,
      )
  ),

  VERSION_FROM   => 'lib/POE.pm',
  dist           => {
    COMPRESS => 'gzip -9f',
    SUFFIX   => 'gz',
    PREOP    => (
      './mylib/cvs-log.perl | ' .
      '/usr/bin/tee ./$(DISTNAME)-$(VERSION)/CHANGES > ./CHANGES; ' .
      "$^X mylib/gen-meta.perl; " .
      '/bin/cp -f ./META.yml ./$(DISTNAME)-$(VERSION)/META.yml'
    ),
  },

  clean => {
    FILES => CLEAN_FILES,
  },

  # More for META.yml than anything.
  PL_FILES       => { },
  NO_META        => 1,
  PREREQ_PM      => { CORE_REQUIREMENTS },
);

1;
