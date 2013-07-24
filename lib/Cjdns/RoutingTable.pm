package Cjdns::RoutingTable;

use CJDNS;
use Bencode qw/bencode bdecode/;
use Mojo::UserAgent;
use Cjdns::Route;
use Mojo::UserAgent;
use MongoDB;
use MongoDB::OID;

# we gotta use both now that the admin server isn't sending "\n"
use IO::Socket;

my $ua = Mojo::UserAgent->new;

our ($names_doc, $names_calls, %pings);

sub api_routing_table {
    my ($class, $pings, @api_hosts) = @_;
    my @decoded;
    foreach my $apih (@api_hosts) {

        my $encoded;
        if ($apih && ($apih !~ /^[0-9\.\:]+$/) && -e $apih) {
            warn "[routing_table] loading from file source $apih\n";
            open(FILE, '<', $apih);
            {
                local $/;
                $encoded = <FILE>;
            }
            close(FILE);
            chomp($encoded);
            push(@decoded, bdecode($encoded));
        } elsif ($apih =~ /^http/) {
            warn "[routing_table] loading from http source $apih\n";
            $encoded = $ua->get($apih)->res->body;
            chomp($encoded);
            push(@decoded, bdecode($encoded));
        } else {
            my ($host, $port, $pass) = split(/:/, $apih);
            warn "[routing_table] loading from cjdroute source $host:$port\n";
            my ($host, $port, $pass) = split(/:/, $apih);

            unless ($host && $port && $pass) {
                warn "Cjdns::RoutingTable - error required host:port:password, skipping\n";
                next;
            }
            my $cjdns = CJDNS->new($host, $port, $pass);
            
            my $decoded = {};
            my $page = 1;
            while (1) {
                $routes = $cjdns->NodeStore_dumpTable(page => $page);
            
                foreach my $route (@{$routes->{routingTable}}) {
                    push(@{$decoded->{routingTable}}, $route);
                }
            
                last unless $routes->{more};
                $page++;
            }
            push(@decoded, $decoded);
        } 
    }

    return new($class, $pings, @decoded);
}

sub new {
    my ($class, $pings, @hrs) = @_;
    if (ref($pings)) {
        $pings = 0;
        unshift(@hrs, $pings);
    }

    my $db = MongoDB::Connection->new->get_database('nodeinfo');

    my $name_map = get_names();
    my (@routes);
    foreach my $hr (@hrs) {
        foreach my $route (@{$hr->{routingTable}}) {
            my $ptime;
            if ($pings) {
                if (exists($pings{$route->{ip}})) {
                    $ptime = $pings{$route->{ip}};
                } else {
                    my $ping = `ping6 -W 1 -c 1 $route->{ip} | grep time=`;
                    ($ptime) = $ping =~ /time=([\d\.]+)/;
                    $pings{$route->{ip}} = $ptime;
                }
            }

            $route->{db} = {};
            my $cur = $db->get_collection('nodes')->find({ ip => $route->{ip} });
            unless ($cur->count == 0) {
                $route->{db} = $cur->next;
            }
            my $name = $name_map->{$route->{ip}} ? $name_map->{$route->{ip}} : (split(/:/, $route->{ip}))[7];
            push(@routes, Cjdns::Route->new($route->{ip}, $name, $route->{path}, $route->{link}, $route->{db}, $ptime));
        }
    }

    return bless { routes => \@routes }, $class;

}

sub find_parent {
    my ($self, $route) = @_;
    my $parents = [];
    foreach my $other ($self->routes) {
        my $starts_with = $other->route;
        $parents->[length($other->route)] = $other if $route->route =~ /^$starts_with/ and $route != $other;
    }
    @$parents = reverse(@$parents);
    if (scalar(@$parents)) {
        return $parents->[0];
    }
    return undef;
}

sub nodes_paged {
    my ($self, $page_number, $num_per_page, $httponly) = @_;

    # retrieve all nodes
    my @nodes = sort {$b->link <=> $a->link} ($httponly ? $self->only_http_nodes : $self->nodes);

    # pad with one :)
    unshift(@nodes, undef);

    if ($page_number > 1) {
        # the page we're on.
        return @nodes[(($page_number - 1) * $num_per_page) + 1..($page_number * $num_per_page)];
    } else {
        # the first page
        return @nodes[1..$num_per_page];
    }
}

sub nodes_pages {
    my ($self, $num_per_page, $httponly) = @_;
    my @nodes = ($httponly ? $self->only_http_nodes : $self->nodes);

    my $pages = int(scalar(@nodes) / $num_per_page);
    if (scalar(@nodes) % $num_per_page) {
        $pages++;
    }

    return $pages - 1;
}

sub matching_routes {
    my ($self, $node) = @_;
    my (@routes);
    foreach my $route ($self->routes) {
        if ($route->ip eq $node) {
            push(@routes, $route);
        }
    }
    return @routes;
}

sub node {
    my ($self, $node) = @_;
    my $highest_link;
    foreach my $route ($self->routes) {
        if ($route->ip eq $node) {
            if ($highest_link && $route->link > $highest_link->link) {
                $highest_link = $route;
            } elsif (!$highest_link) {
                $highest_link = $route;
            }
        }
    }
    return $highest_link || undef;
}

sub only_http_nodes {
    my ($self) = @_;
    my $hr = {};
    foreach my $route ($self->routes) {
        if (!exists($hr->{$route->ip}) && (scalar(grep { $_->{service} =~ /http/ } @{$route->db->{services}}))) {
            $hr->{$route->ip} = $route;
        } 
    }
    return (values %$hr);
}

sub nodes {
    my ($self) = @_;
    my $hr = {};
    foreach my $route ($self->routes) {
        $hr->{$route->ip} = $route;
    }
    return (values %$hr);
}

sub nodes_as_hashrefs {
    my ($self) = @_;
    my @nodes = $self->nodes;
    my @hrnodes;
    foreach my $node (@nodes) {
        push(@hrnodes, {
            ip => $node->ip,
            link => $node->link,
            name => $node->name,
            ping => $node->db->{ping},
        });
    }
    return (@hrnodes);
}

sub routes {
    my ($self) = @_;
    if (scalar @{$self->{routes}}) {
        return @{$self->{routes}};
    }
    return ();
}

# cache to be nice to ircerr
sub get_names { 
    $names_calls++;
    my $document;
    if ($names_doc && $names_calls < 100) {
        $document = $names_doc;
    } else {
        my $ua = Mojo::UserAgent->new();
        $document = $ua->get('http://ircerr.bt-chat.com/cjdns/ipv6-cjdnet.data.txt')->res->body;
        $names_doc = $document;
    }


    my $hr = {};
    foreach my $line (split(/[\r\n]+/, $document)) {
        # skip comments!
        next if $line =~ /^#/;

        my ($addr, $name) = split(/\s+/, $line, 2);

        # clean up names.
        $name =~ s/\(\w+\)//g;
        $name =~ s/\s+/ /g;

        if ($name) {
            $hr->{$addr} = $name;
        } else {
            my @c = split(/:/, $addr);
            $hr->{$addr} = $c[$#c];
        }
    }
    return $hr;
}

1;
