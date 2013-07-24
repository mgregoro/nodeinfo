#!/usr/bin/env perl

use File::Basename 'dirname';
use File::Spec;

use lib join '/', File::Spec->splitdir(dirname(__FILE__)), 'lib';
use lib join '/', File::Spec->splitdir(dirname(__FILE__)), '..', 'lib';

use CJDNS;
use MongoDB;
use MongoDB::OID;
use NodeInfo::Data::NodeList;
use Cjdns::RoutingTable;

# get the routing table dir
my $rt_dir = "/var/rtdump/";

my @rt_files;
if (-d $rt_dir) {
    opendir(RTDIR, $rt_dir) or warn "can't open $rt_dir: $!\n";
    while (my $file = readdir(RTDIR)) {
        next if $file eq "..";
        next if $file eq ".";
        push(@rt_files, "$rt_dir$file");
    }
    close(RTDIR);
}

# get the nodeinfo database, query timeout is 45 minutes.
my $db = MongoDB::Connection->new(query_timeout => 60000 * 45)->get_database('nodeinfo');

# get our cjdns routing table
my $rt = Cjdns::RoutingTable->api_routing_table(0, "localhost:11234:$ENV{CJDNS_ADMIN_PASSWORD}", "localhost:11235:$ENV{CJDNS_ADMIN_PASSWORD}", @rt_files, @ARGV);
my $nl = NodeInfo::Data::NodeList->new;
my $cjdns = CJDNS->new('localhost', '11234', $ENV{CJDNS_ADMIN_PASSWORD});

foreach my $route ($rt->routes) {
    my $cur = $db->get_collection('nodes')->find({ ip => $route->ip });

    if ($cur->count == 0) {
        my $id = $db->get_collection('nodes')->insert(
            {
                ip => $route->ip,
                common_name => $route->name,
                link_quality => $route->link,
                create_time => time,
            }
        );
        $cur = $db->get_collection('nodes')->find({ _id => $id });
    } 

    $route->{db} = $cur->next;
}

#my %existing_nodes = map { lc($_->ip) => $_ } $nl->nodes;
# let's only try and get at nodes we see in the routing table.  no.  bullocks.
my %existing_nodes = map { lc($_->ip) => $_ } ($rt->nodes, $nl->nodes);

#foreach my $ip (keys %rt_nodes) {
#    next if exists $existing_nodes{$ip};
#    print "[info] discovered new node $ip, adding to NodeInfo\n";
#    $existing_nodes{$ip} = $rt_nodes{$ip};
#}

# every route in the routing table now has its awesome MongoDB document in it!
foreach my $ip (keys %existing_nodes) {
    my $node = $existing_nodes{$ip};
    $| = 1;
    my $ip = $node->ip;

    # we have to zero pad it for cjdadmin pinging!
    $ip = join(':', map { sprintf("%04x", hex($_)) } split(/:/, $ip));

    # get our ping on.
    my $print_name = $node->db->{hostname} || $node->db->{common_name};
    if ($print_name) {
        print "[info] pinging $print_name... ";
    } else {
        print "[info] pinging $ip... ";
    }
    my $ping = `/bin/ping6 -i .5 -c 2 -w 2 $ip | /bin/grep time=`;
    my ($ptime) = $ping =~ /time=([\d\.]+ \w+)/;

    # if it doesn't ping, keep track.
    $ptime = "N/A" unless $ptime;

    if ($node->db->{ping} ne $ptime) {
        $node->db->{ping_change_time} = time;
    }

    $node->db->{ping} = $ptime;

    print "$ptime\n";

    # now we ping at the cjdroute level
    if ($print_name) {
        print "[info] cjdroute admin pinging $print_name... ";
    } else {
        print "[info] cjdroute admin pinging $ip... ";
    }

    my ($cjdping, $cjdns_version);
    eval {
        my $resp = $cjdns->RouterModule_pingNode(timeout => 1000, path => $ip);
        $cjdping = $resp->{ms};
        $cjdns_version = $resp->{version};
    };

    if ($@) {
        $cjdping = "N/A";
    } else {
        $node->db->{cjdns_version} = $cjdns_version;
        if ($cjdping && $cjdping != 4294967295) {
            $cjdping = "$cjdping ms";
        } else {
            $cjdping = "N/A";
        }

        if ($node->db->{cjdping} ne $cjdping) {
            $node->db->{cjdping_change_time} = time;
        }
    }

    $node->db->{cjdping} = $cjdping;

    print "$cjdping\n";

    if ($cjdns_version) {
        print "[info] cjdns_version for node $print_name... $cjdns_version\n";
    }

    # now we nmap (only every 24 hours)
    if ($node->db->{last_check_time} + (3600 * 24) < time) {
        if ($print_name) {
            print "[info] running nmap on $print_name\n";
        } else {
            print "[info] running nmap on " . $node->ip . "\n";
        }
        open(NMAP, '-|', "/usr/bin/nmap -6 " . $node->ip);
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

    if (scalar(@{$node->db->{services}}) != scalar(values %$shr)) {
        $node->db->{services_change_time} = time;
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
    $db->get_collection('nodes')->save($route->db);
}

