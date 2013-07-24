#!/usr/bin/env perl

if ($ARGV[0] =~ /^[0-9a-f]+(?::[0-9a-f]+){7}$/) {
    print "yes\n";
} else {
    print "no\n";
}

print join(':', map { sprintf("%04x", hex($_)) } split(/:/, $ARGV[0])) . "\n";
