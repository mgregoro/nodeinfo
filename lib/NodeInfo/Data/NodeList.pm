package NodeInfo::Data::NodeList;

use NodeInfo::Data::Node;
use IO::Socket;
use MongoDB;
use MongoDB::OID;

sub new {
    my ($class, $hr) = @_;
    if (ref($pings)) {
        $pings = 0;
        unshift(@hrs, $pings);
    }

    my $db = MongoDB::Connection->new->get_database('nodeinfo');

    my @nodes;
    foreach my $node ($db->get_collection('nodes')->find->all) {
        $node->{common_name} ||= (split(/:/, $node->{ip}))[7];
        push(@nodes, NodeInfo::Data::Node->new($node));
    }

    # yeaaaaa
    $hr->{count} = scalar(@nodes);
    $hr->{nodes} = \@nodes;
    $hr->{db} = $db;
    return bless $hr, $class;
}

# these methods just print counts.. for stats n' stuff
sub hypehost_nodes {
    my ($self) = @_;
    return $self->db->nodes->find({ hostname => { '$ne' => undef}})->count;
}

sub nodes_that_ping {
    my ($self) = @_;
    return $self->db->get_collection('nodes')->find({ ping => { '$ne' => 'N/A'}})->count;
}

sub nodes_in_db {
    my ($self) = @_;
    return $self->db->get_collection('nodes')->find->count;
}

# works the same as nodes_paged but returns recently updated ones instead!
sub recently_updated_nodes {
    my ($self, $page_number, $num_per_page, $httponly) = @_;
    # retrieve all nodes
    my @nodes = sort {$b->{db}->{update_time} <=> $a->{db}->{update_time}} ($httponly ? $self->only_http_nodes : $self->nodes);

    if ($num_per_page >= scalar(@nodes)) {
        $num_per_page = $#nodes;
    }

    if ($page_number > 1) {
        # the page we're on.
        return @nodes[(($page_number - 1) * $num_per_page)..($page_number * $num_per_page) - 1];
    } else {
        # the first page
        return @nodes[0..$num_per_page - 1];
    }
}

# used to see if we have to recache.
sub _more_in_db {
    my ($self) = @_;
    if ($self->nodes_in_db > scalar(@{$self->{nodes}})) {
        return 1;
    }
    return 0;
}

sub nodes_paged {
    my ($self, $page_number, $num_per_page, $httponly) = @_;

    # retrieve all nodes
    my @nodes = sort {$a->ping(1) <=> $b->ping(1)} ($httponly ? $self->only_http_nodes : $self->nodes);

    if ($num_per_page >= scalar(@nodes)) {
        $num_per_page = $#nodes;
    }

    if ($page_number > 1) {
        # the page we're on.
        return @nodes[(($page_number - 1) * $num_per_page)..($page_number * $num_per_page) - 1];
    } else {
        # the first page
        return @nodes[0..$num_per_page - 1];
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

sub node {
    my ($self, $node) = @_;

    foreach my $attr (qw/hostname common_name ip/) {
        my $hr = $self->{db}->get_collection('nodes')->find_one({ $attr => $node });
        if (ref($hr) eq "HASH") {
            return NodeInfo::Data::Node->new($hr);
            last;
        }
    }

    return undef;
}

sub only_http_nodes {
    my ($self) = @_;
    my $hr = {};
    foreach my $node ($self->nodes) {
        if ($node->runs_service('http')) {
            $hr->{$node->ip} = $node;
        } 
    }
    return (values %$hr);
}

sub nodes {
    my ($self) = @_;
    return @{$self->{nodes}};
}

sub count {
    my ($self) = @_;
    return $self->{count};
}

sub db {
    my ($self) = @_;
    return $self->{db};
}

sub nodes_as_hashrefs {
    my ($self, $everything) = @_;
    my @nodes = $self->nodes;
    my @hrnodes;
    foreach my $node (@nodes) {
        push(@hrnodes, {
            ip => $node->ip,
            link => $node->link,
            name => $node->name,
            location => $node->db->{location},
            ping => $node->db->{ping},
        });
    }
    return (@hrnodes);
}

1;
