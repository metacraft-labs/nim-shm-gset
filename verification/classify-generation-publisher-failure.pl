#!/usr/bin/env perl
# Classify the pinned GenMC diagnostic, not arbitrary text elsewhere in a trace.
# Oracle locations come from named markers on unchanged driver assertions.
# Readiness locations come from the two exact production statements that write
# and read the prepared generation; production source needs no test annotation.
use strict;
use warnings;
use File::Basename qw(basename);

@ARGV == 5 or die "usage: $0 CONTROL STATUS LOG DRIVER MUTATED_UNIT\n";
my ($control, $status, $log_path, $driver, $unit) = @ARGV;
my %oracles = (
    relaxed => 'published_payload_visible',
    nonmonotonic => 'newer_mark_preserved',
    omitted => 'exactly_one_publication',
    rebound => 'exclusive_storage_claim',
    'armed-close' => 'closed_storage_unavailable',
    'stale-success' => 'forced_reset_reports_stale',
);
exists $oracles{$control} || $control eq 'unordered-readiness'
    or die "unknown control: $control\n";

sub reject {
    print "REJECT $control: $_[0]\n";
    exit 1;
}

sub source_line {
    my ($path, $anchor) = @_;
    open my $fh, '<', $path or die "$path: $!\n";
    my @matches;
    while (my $line = <$fh>) { push @matches, $. if $line =~ $anchor; }
    @matches == 1 or die "source anchor absent or ambiguous in $path: $anchor\n";
    return $matches[0];
}

open my $log, '<', $log_path or die "$log_path: $!\n";
my @lines = <$log>;
# GenMC 0.17 returns 42 for a checked violation. Reject signals and compiler
# errors even if their output happens to contain an old diagnostic fragment.
reject("expected GenMC violation status 42, got $status") unless $status eq '42';
my @errors = grep { /^Error:/ } @lines;
reject('expected exactly one GenMC Error diagnostic') unless @errors == 1;

sub event {
    my ($id) = @_;
    my @matches = grep { /^\s*\Q$id\E: / } @lines;
    reject("error event $id absent or ambiguous") unless @matches == 1;
    chomp $matches[0];
    return $matches[0];
}

if (exists $oracles{$control}) {
    reject('wrong error kind; expected Safety violation')
        unless $errors[0] eq "Error: Safety violation!\n";
    my @reports = grep { /^Event \(\d+, \d+\) in graph:/ } @lines;
    reject('expected one assertion error event') unless @reports == 1;
    $reports[0] =~ /^Event (\(\d+, \d+\)) in graph:/;
    my $actual = event($1);
    my $name = $oracles{$control};
    my $line = source_line($driver, qr/\/\* ORACLE: \Q$name\E(?:[; ]|\*)/);
    my $file = basename($driver);
    reject("expected oracle $name at $file:$line; reported $actual")
        unless $actual =~ /: ERROR \Q$file\E:\Q$line\E$/;
    print "ACCEPT $control: oracle $name at $file:$line, status 42\n";
} else {
    reject('wrong error kind; expected Non-atomic race')
        unless $errors[0] eq "Error: Non-atomic race!\n";
    my @reports = grep { /^Event \(\d+, \d+\) conflicts with event \(\d+, \d+\) in graph:/ } @lines;
    reject('expected one conflicting event pair') unless @reports == 1;
    $reports[0] =~ /^Event (\(\d+, \d+\)) conflicts with event (\(\d+, \d+\)) in graph:/;
    my ($first_id, $second_id) = ($1, $2);
    my ($first, $second) = (event($first_id), event($second_id));
    # Identify the ACTUAL reported conflicting read/write, their common POD
    # field and both source sites. Prepared accesses elsewhere are irrelevant.
    my $write = source_line($unit, qr/^\s*s->captured = captured;\s*$/);
    my $read = source_line($unit, qr/^\s*const uint64_t g = s->captured;\s*$/);
    my $file = basename($unit);
    my $write_event = qr/: Wna \(first\.captured, [^)]*\) \Q$file\E:\Q$write\E$/;
    my $read_event = qr/: Rna \(first\.captured, [^)]*\)(?: \[[^]]*\])? \Q$file\E:\Q$read\E$/;
    reject("expected conflicting prepared first.captured write/read at $file:$write/$read; reported $first ; $second")
        unless ($first =~ $write_event && $second =~ $read_event)
            || ($second =~ $write_event && $first =~ $read_event);
    print "ACCEPT $control: conflicting prepared first.captured write/read at $file:$write/$read, status 42\n";
}
