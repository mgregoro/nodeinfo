package NodeInfo;

BEGIN { use Net::INET6Glue; }

use Mojo::Base 'Mojolicious';
use Cjdns::RoutingTable;
use NodeInfo::Data::NodeList;
use MongoDB;
use MongoDB::OID;

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

# we share this amongst every body!
my $rt = Cjdns::RoutingTable->api_routing_table(0, "localhost:11234:$ENV{CJDNS_ADMIN_PASSWORD}", "localhost:11235:$ENV{CJDNS_ADMIN_PASSWORD}", @rt_files);

# and now this, as well :)
my $nl = NodeInfo::Data::NodeList->new;

# ok we need this map too maybe
my $nrmap = gen_nl_rt_map();

# This method will run once at server start
sub startup {
    my $self = shift;

    $self->secret('MiTG0vcgj28tM3M2kt3jOobpL6cTf0Kt');

    my $rt_hit;
    # let's just use the same routing table for everyone.
    $self->helper('rt' => sub {
        $rt_hit++;
        if (!($rt_hit % 2000) || $nl->_more_in_db) {
            # recache every 2000 rt grabs.
            $rt = Cjdns::RoutingTable->api_routing_table(0, 'localhost:11234', 'localhost:11235');
            $nrmap = gen_nl_rt_map();
        }
        return $rt;
    });

    my $nl_hit;
    $self->helper('nl' => sub {
        $nl_hit++;
        if (!($nl_hit % 2000) || $nl->_more_in_db) {
            # recache every 2000 rt grabs.
            $nl = NodeInfo::Data::NodeList->new;
            $nrmap = gen_nl_rt_map();
        }
        return $nl;
    });

    $self->helper('nrmap' => sub {
        return $nrmap;
    });

    # give me the db "nodes"!
    $self->attr(db => sub {
        MongoDB::Connection->new->get_database('nodeinfo');
    });
    $self->helper('db' => sub { shift->app->db });

    $self->helper('remote_ip' => sub {
        my ($self) = @_;

        my $ip;
        unless ($ip = $self->req->headers->header('X-Real-IP')) {
            $ip = $self->tx->remote_address;
        }

        if ($ip !~ /\./) {
            return join(':', map { sprintf("%04x", hex($_)) } split(/:/, $ip));
        } else {
            return $ip;
        }
    });

    # Routes
    my $r = $self->routes;

    # different actions for entry and coming back!
    $r->route('/')->to('home#default');
    $r->route('/home')->to('home#default');
    $r->route('/:page')->to(controller => 'page', action => 'default');

    # list nodes, show node details
    $r->route('/nodes/live/list')->to(controller => 'node', action => 'live_list', page => 1);
    $r->route('/nodes/live/list/:page')->to('node#live_list');
    $r->route('/nodes/live/details/:node', node => qr/[0-9A-Za-z\:\.-]+/)->to("node#live_details");
    $r->route('/nodes/live/details/:node/nmap')->to('node#nmap');

    # we are not doing it live.
    $r->route('/nodes/list')->to(controller => 'node', action => 'list', page => 1);
    $r->route('/nodes/list/:page')->to('node#list');
    $r->route('/nodes/details/:node', node => qr/[0-9A-Za-z\:\.-]+/)->to("node#details");
    $r->route('/nodes/details/:node/save', node => qr/[0-9A-Za-z\:\.-]+/)->to("node#save_nodeinfo");
    $r->route('/nodes/details/:node/comment', node => qr/[0-9A-Za-z\:\.-]+/)->to("node#comment");
    $r->route('/node/details/:node', node => qr/[0-9A-Za-z\:\.-]+/)->to("node#details");
    $r->route('/node/details/:node/save', node => qr/[0-9A-Za-z\:\.-]+/)->to("node#save_nodeinfo");
    $r->route('/node/details/:node/comment', node => qr/[0-9A-Za-z\:\.-]+/)->to("node#comment");
    
    # for the hypehost cli tool
    $r->route('/_hypehost/get')->to('node#get_myhostname');
    $r->route('/_darkhost/get')->to('node#get_myhostname');
    $r->route('/_hypehost/set')->to('node#set_myhostname');
    $r->route('/_darkhost/set')->to('node#set_myhostname');

    # dump the cjdroute table to json
    $r->route('/_cjdroute/:port')->to('node#cjdrouting_table');

    # for grundy
    $r->route('/_hype/tlds')->to('node#list_ni_tlds');

    # caching :)
    $self->app->hook(after_dispatch => sub {
        my $tx = shift;
    
        # Was the response dynamic?
        return if $tx->res->headers->header('Expires');
    
        # If so, try to prevent caching
        $tx->res->headers->header(
            Expires => Mojo::Date->new(time-365*86400)
        );
        $tx->res->headers->header(
            "Cache-Control" => "max-age=1, no-cache"
        );
    });
    
    $self->app->hook(after_static_dispatch => sub {
        my $tx = shift;
        my $code = $tx->res->code;
        my $type = $tx->res->headers->content_type;
    
        # Was the response static?
        return unless $code && ($code == 304 || $type);
    
        # If so, remove cookies and/or caching instructions
        $tx->res->headers->remove('Cache-Control');
        $tx->res->headers->remove('Set-Cookie');
    
        # Decide on an expiry date
        my $e = Mojo::Date->new(time+600);
        if ($type) {
            if ($type =~ /javascript/) {
                $e = Mojo::Date->new(time+300);
            }
            elsif ($type =~ /^text\/css/ || $type =~ /^image\//) {
                $e = Mojo::Date->new(time+3600);
                $tx->res->headers->header("Cache-Control" => "public");
            }
            # other conditions
        }
        $tx->res->headers->header(Expires => $e);
    });
}

sub gen_nl_rt_map {
    my $nlrtmap = {};
    foreach my $node ($nl->nodes) {
        $nlrtmap->{$node->ip} = {
            ninode => $node,
            routes => [$rt->matching_routes($node->ip)],
        };
    }
    return $nlrtmap;
}

1;
