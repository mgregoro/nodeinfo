#!/usr/bin/env perl

use File::Basename 'dirname';
use File::Spec;
use JSON;

use lib join '/', File::Spec->splitdir(dirname(__FILE__)), 'lib';
use lib join '/', File::Spec->splitdir(dirname(__FILE__)), '..', 'lib';

use MongoDB;
use MongoDB::OID;

# get the nodeinfo database, query timeout is 45 minutes.
my $db = MongoDB::Connection->new(query_timeout => 60000 * 45)->nodeinfo;

my @records = $db->nodes->find->all;

my $json = JSON->new->allow_nonref->allow_blessed;

print $json->encode(\@records);































































































