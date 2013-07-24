package NodeInfo::Home;

use Mojo::Base 'Mojolicious::Controller';

# This action will render a template
sub default {
    my ($self) = @_;

    my $template = $self->stash('page') || "default";

    $self->render(nl => $self->nl, template => "home/$template");
}

1;
