#!/usr/bin/env perl

use File::Basename 'dirname';
use File::Spec;

use lib join '/', File::Spec->splitdir(dirname(__FILE__)), 'lib';
use lib join '/', File::Spec->splitdir(dirname(__FILE__)), '..', 'lib';

use MongoDB;
use MongoDB::OID;
use Cjdns::RoutingTable;

unless ($ARGV[0]) {
    die "Usage: poll_one.pl <ipv6>\n";
}

# get the nodeinfo database, query timeout is 45 minutes.
my $db = MongoDB::Connection->new(query_timeout => 60000 * 45)->nodeinfo;

# get our cjdns routing table
my $rt = Cjdns::RoutingTable->api_routing_table(0, 'localhost:11234', 'localhost:11235');

my $one;
foreach my $route ($rt->routes) {
    if ($route->ip eq $ARGV[0]) {
        my $cur = $db->nodes->find({ ip => $route->ip });

        if ($cur->count == 0) {
            my $id = $db->nodes->insert(
                {
                    ip => $route->ip,
                    common_name => $route->name,
                    link_quality => $route->link,
                }
            );
            $cur = $db->nodes->find({ _id => $id });
        } 

        $route->{db} = $cur->next;
        $one = $route;
        last;
    } else {
        #print $route->ip . " does not match " . $ARGV[0] . "\n";
    }
}

die "[error] couldn't find node: $ARGV[0]\n" unless $one;

print "One is: " . $one->ip . "\n";

exit();

# every route in the routing table now has its awesome MongoDB document in it!

foreach my $node ($rt->nodes) {
    # get our ping on.
    my $ip = $node->ip;
    my $ping = `ping6 -W 1 -c 1 $ip | grep time=`;
    my ($ptime) = $ping =~ /time=([\d\.]+ \w+)/;

    # if it doesn't ping, keep track.
    $ptime = "N/A" unless $ptime;
    $node->db->{ping} = $ptime;

    # now we nmap (only every 24 hours)
    if ($node->db->{last_check_time} + (3600 * 24) < time) {
        print "[info] running nmap on " . $node->ip . "\n";
        open(NMAP, '-|', "nmap -6 " . $node->ip);
        while (my $line = <NMAP>) {
            if ($line =~ /^(\d+)\/(\w+)\s+open\s+(\w+)[\r\n]+$/) {
                push(@{$node->db->{services}}, { port => $1, proto => $2, service => $3 });
            }
        }
        close(NMAP);
    }

    # clean up services.
    my $shr = {};
    foreach my $service (@{$node->db->{services}}) {
        $shr->{$service->{port}} = $service;
    }

    @{$node->db->{services}} = (values %$shr);

    # now we see all the nodes this is connected to.
    delete($node->db->{peers});
    foreach my $route ($rt->routes) {
        if ($route->ip eq $node->ip) {
            my $parent = $rt->find_parent($route);
            if ($parent) {
                my $already_linked = 0;
                foreach my $peer (@{$node->db->{peers}}) {
                    $already_linked = 1 if $peer eq $parent->ip;
                }
                unless ($already_linked) {
                    push(@{$node->db->{peers}}, $parent->ip);
                }
            }
        }
    }

    # last touched timestamp
    $node->db->{last_check_time} = time;

    save_db($node);
}

# this will save the db.
sub save_db {
    my ($route) = @_;
    return undef unless $route and ref($route->db);
    $db->nodes->save($route->db);
}

