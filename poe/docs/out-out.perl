#!perl -w
# $Id$

use strict;

sub ST_HEADING    () { 'heading list'; }
sub ST_PLAIN      () { 'plain text';   }
sub ST_BQUOTE     () { 'bquote text';  }
sub ST_BOF        () { 'begin';        }
sub ST_PARAGRAPH  () { 'paragraph';    }
sub ST_ENUMLIST   () { 'enum list';    }
sub ST_BULLETLIST () { 'bullet list';  }
sub ST_EOF        () { 'cease';        }

my @head = 
( [ '*', '+0' ],
  [ 'I', '+1' ], [ 'A', '+1' ], [ '1', '+1' ], [ 'a', '+0' ], [ 'i', '+0' ],
  [ 'a', '+0' ], [ 'i', '+0' ], [ 'a', '+0' ], [ 'i', '+0' ], [ 'a', '+0' ],
);

my %handler =
(
                                        # code
 'C' => sub { "<code><font size=-1>" . $_[0] . "</font></code>"; },
                                        # comment
 '#' => sub { ""; },
);

my $state = ST_BOF;
my $last_index = 0;
my $plain_buffer = '';

sub filter_text {
  my $text = shift;

  $text =~ s/\&/\&\#38;/g;
  $text =~ s/\</\&\#60;/g;
  $text =~ s/\>/\&\#62;/g;

  while ($text =~ /^(.*?)(\S)�(.*?)�(.*)$/) {
    my ($left, $tag, $mid, $right) = ($1, $2, $3, $4);
    if (exists $handler{$tag}) {
      $mid = &{$handler{$tag}}($mid);
    }
    else {
      $mid = " [unknown tag $tag] " . $mid;
    }
    $text = $left . $mid . $right;
  }

  $text;
}

sub flush_text {
  my $flush_state = shift;

  if ($plain_buffer ne '') {
    if ($flush_state ne ST_BQUOTE) {
      $plain_buffer =~ s/\s+/ /g;
      $plain_buffer =~ s/^\s+//s;
    }

    $plain_buffer =~ s/\s+$//s;

    print &filter_text($plain_buffer), "\n";
    $plain_buffer = '';
  }
}
  
sub format_html {
  my $new_state = shift;
  my $text = shift;
                                        # state transition
  if ($new_state ne $state) {

    &flush_text($state);

    if ($state eq ST_BQUOTE) {
      print "</pre></font></p>\n";
    }
    elsif ($state eq ST_PLAIN) {
      print "</p>\n";
    }
    elsif ($state eq ST_PARAGRAPH) {
      # nothing
    }
    elsif ( ($state eq ST_ENUMLIST) ||
            ($state eq ST_BULLETLIST)
    ) {
      print "</ol>\n";
    }

    if (($state =~ /list/) && ($new_state =~ /list/)) {
      print "<br>\n";
    }

    if ($new_state eq ST_PARAGRAPH) {
      # nothing
    }
    elsif ($new_state eq ST_PLAIN) {
      print "<p>\n";
    }
    elsif ($new_state eq ST_BQUOTE) {
      print "<p><font size=-1><pre>\n";
    }
    elsif ($new_state eq ST_ENUMLIST) {
      print "<ol type=1>\n<li>";
    }
    elsif ($new_state eq ST_BULLETLIST) {
      print "<ul type=disc>\n<li>";
    }
  }
                                        # maintain the current state
  else {
    if ( ($state eq ST_ENUMLIST) ||
         ($state eq ST_BULLETLIST)
    ) {
      &flush_text($state);
      print "<li>";
    }
  }
                                        # things regardless of transition
  if ($new_state eq ST_HEADING) {
    my ($index) = @_;
    my $rec = $head[$index];

    if ($index - $last_index > 1) {
      die "outline level changes by more than +1 at input line $.\n";
    }

    if ($index < $last_index) {
      my $pop_index = $last_index;
      do {
        print "</ol>\n";
        $pop_index--;
      } until ($index == $pop_index);
    }

    if ($index == 0) {
      if ($last_index == 0) {
        print("<html>\n<head>\n<title>",
              &filter_text($text),
              "</title>\n</head>\n<body>\n"
             );
      }
      else {
        print "<hr>\n";
      }
      print "<h1>", &filter_text($text), "</h1>\n";
    }
    else {
      if ($index > $last_index) {
        print "<ol type=$rec->[0]>\n";
      }
      print "<font size='$rec->[1]'><li>", &filter_text($text), "</font>\n";
    }

    $last_index = $index;
  }
  elsif ($new_state eq ST_EOF) {
    while ($last_index--) {
      print "</ol>\n";
    }
    print "</p>\n";
    print "<hr>\n<font size='-1'>Generated by out2html.</font>\n";
    print "</body>\n</html>";
  }
  elsif ($new_state ne ST_PARAGRAPH) {
    $plain_buffer .= $text . "\n";
  }

  $state = $new_state;
}


while (<>) {
  1 while (chomp());

  if (s/^(\*+)//) {
    &format_html(ST_HEADING, $_, length($1)-1);
  }
  elsif ($_ eq '') {
    &format_html(ST_PARAGRAPH, $_);
  }
  elsif (/^\s/) {
    &format_html(ST_BQUOTE, $_);
  }
  elsif (s/^\#\)\s+//) {
    &format_html(ST_ENUMLIST, $_);
  }
  elsif (s/^\o\)\s+//) {
    &format_html(ST_BULLETLIST, $_);
  }
  else {
    &format_html(ST_PLAIN, $_);
  }
}

&format_html(ST_EOF);