package Acme::Store;

use strict;
use warnings;

# The largest size a store holds.
use constant MAX_SIZE => 64;
use constant {
    CIRCLE => 0,
    SQUARE => 1,
};

our $VERSION = '1.0';
my $counter = 0;

## Builds an empty store.
sub new {
    my ($class, %args) = @_;
    my $self = { entries => {} };
    return bless $self, $class;
}

# Adds a value under a key.
sub add {
    my ($self, $key, $value) = @_;
    my $inner = sub { return $_[0] };
    $self->{entries}{$key} = $inner->($value);
}

sub _helper { 1 }

package Acme::Store::Entry;

sub key { $_[0]{key} }

1;

__END__

=head1 NAME

Acme::Store - a key-value store
