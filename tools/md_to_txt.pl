#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use open qw(:std :encoding(UTF-8));

my $path = shift @ARGV or die "usage: md_to_txt.pl FILE\n";
open my $in, '<:encoding(UTF-8)', $path or die "$path: $!\n";
my @source = <$in>;
close $in or die "$path: $!\n";

my @out;
my $in_fence = 0;

sub blank {
    push @out, '' if @out && $out[-1] ne '';
}

sub inline_text {
    my ($text) = @_;
    $text =~ s/\[([^\]]+)\]\(([^)]+)\)/$1 ($2)/g;
    $text =~ s/\*\*([^*]+)\*\*/$1/g;
    $text =~ s/__([^_]+)__/$1/g;
    $text =~ s/`([^`]+)`/$1/g;
    $text =~ s/\*+//g;
    $text =~ s/__+//g;
    $text =~ s/[“”]/"/g;
    $text =~ s/[‘’]/'/g;
    $text =~ s/[—–]/-/g;
    $text =~ s/…/.../g;
    $text =~ s/×/x/g;
    return $text;
}

sub table_cells {
    my ($line) = @_;
    chomp $line;
    $line =~ s/^\s*\|//;
    $line =~ s/\|\s*$//;
    my @cells = split /\|/, $line, -1;
    for (@cells) {
        s/^\s+|\s+$//g;
        $_ = inline_text($_);
    }
    return @cells;
}

sub is_separator {
    my (@cells) = @_;
    return @cells && !grep { $_ !~ /^:?-{3,}:?$/ } @cells;
}

sub wrapped {
    my ($text, $width, $first_prefix, $next_prefix) = @_;
    my @lines;
    while (length($text) > $width - length($first_prefix)) {
        my $cut = rindex(substr($text, 0, $width - length($first_prefix) + 1), ' ');
        $cut = $width - length($first_prefix) if $cut < 1;
        push @lines, $first_prefix . substr($text, 0, $cut, '');
        $text =~ s/^\s+//;
        $first_prefix = $next_prefix;
    }
    push @lines, $first_prefix . $text;
    return @lines;
}

sub emit_text_line {
    my ($line) = @_;
    my ($first_prefix, $next_prefix, $text) = ('', '', $line);
    if ($line =~ /^(\s*(?:[-*+]\s+|\d+[.)]\s+))/) {
        $first_prefix = $1;
        $next_prefix = ' ' x length($first_prefix);
        $text = substr($line, length($first_prefix));
    } elsif ($line =~ /^(\s+)/) {
        $first_prefix = $1;
        $next_prefix = $first_prefix;
        $text = substr($line, length($first_prefix));
    }
    push @out, wrapped($text, 80, $first_prefix, $next_prefix);
}

sub emit_table {
    my ($rows) = @_;
    my @parsed = map { [table_cells($_)] } @$rows;
    @parsed = grep { !is_separator(@$_) } @parsed;
    return unless @parsed;

    my @header = @{shift @parsed};
    if (@header == 2 && !grep { @$_ != 2 } @parsed) {
        # Keep two-column tables aligned in the 80-column DSS text mode.
        # Descriptions that do not fit continue directly under column two.
        my $left_width = length($header[0]);
        for my $row (@parsed) {
            $left_width = length($row->[0]) if length($row->[0]) > $left_width;
        }
        $left_width = 31 if $left_width > 31;
        my $right_width = 80 - 2 - $left_width - 2;

        push @out, sprintf('  %-*s  %s', $left_width, $header[0], $header[1]);
        push @out, '  ' . ('-' x $left_width) . '  ' . ('-' x $right_width);
        for my $row (@parsed) {
            my @left = wrapped($row->[0], $left_width, '', '');
            my @right = wrapped($row->[1], $right_width, '', '');
            my $line_count = @left > @right ? scalar @left : scalar @right;
            for my $i (0 .. $line_count - 1) {
                my $left = $left[$i] // '';
                my $right = $right[$i] // '';
                push @out, sprintf('  %-*s  %s', $left_width, $left, $right);
            }
        }
        blank();
        return;
    }

    push @out, inline_text(join(' / ', @header));
    push @out, '-' x length($out[-1]);
    for my $row (@parsed) {
        my $text = join(' - ', @$row);
        push @out, wrapped($text, 80, '  ', '    ');
    }
    blank();
}

for (my $i = 0; $i < @source; $i++) {
    my $line = $source[$i];
    $line =~ s/\r?\n\z//;

    if ($line =~ /^\s*```/) {
        $in_fence = !$in_fence;
        blank() unless $in_fence;
        next;
    }

    if ($in_fence) {
        push @out, $line;
        next;
    }

    if ($line =~ /^\s*\|/) {
        my @table = ($line);
        while ($i + 1 < @source && $source[$i + 1] =~ /^\s*\|/) {
            push @table, $source[++$i];
        }
        emit_table(\@table);
        next;
    }

    if ($line =~ /^\s*(#{1,6})\s+(.+?)\s*$/) {
        my ($marks, $title) = ($1, inline_text($2));
        blank();
        push @out, $title;
        my $rule = length($title) > 78 ? 78 : length($title);
        my $underline = ($marks eq '#' ? '=' : '-') x $rule;
        push @out, $underline;
        blank();
        next;
    }

    if ($line =~ /^\s*$/) {
        blank();
        next;
    }

    emit_text_line(inline_text($line));
}

pop @out while @out && $out[-1] eq '';
print join("\n", @out), "\n";
