package ECS::XS::Binary;

use strict;
use warnings;
use XSLoader;
use Exporter 'import';

our $VERSION = '0.01';
our @EXPORT_OK = qw(
    serialize
    deserialize
    is_class_object
    field_count
);

XSLoader::load('ECS::XS::Binary', $VERSION);

1;

__END__

=head1 NAME

ECS::XS::Binary - Fast binary serialization for Perl 5.40 class objects

=head1 SYNOPSIS

    use feature 'class';
    use ECS::XS::Binary qw(serialize deserialize);
    
    class Position {
        field $x :param :reader = 0;
        field $y :param :reader = 0;
        field $z :param :reader = 0;
    }
    
    my $pos = Position->new(x => 10, y => 20, z => 30);
    
    # Serialize to binary
    my $binary = serialize($pos);
    
    # Restore without using constructor
    my $restored = deserialize($binary);
    
    print "x: ", $restored->x, "\n";
    print "y: ", $restored->y, "\n";
    print "z: ", $restored->z, "\n";

=head1 DESCRIPTION

This module provides fast binary serialization and deserialization for 
Perl 5.40 class objects. It directly accesses the internal fields of 
class objects using the ObjectFIELDS API from perlclassguts.

Deserialization creates objects directly without calling constructors,
which greatly improves performance for large numbers of objects.

=head1 FUNCTIONS

=head2 serialize($object)

Serializes a Perl 5.40 class object to binary data.

=head2 deserialize($binary)

Deserializes binary data back to a Perl 5.40 class object without
calling the constructor.

=head2 is_class_object($object)

Returns true if the given object is a Perl 5.40 class object (SVt_PVOBJ).

=head2 field_count($object)

Returns the number of fields in the given Perl 5.40 class object.

=head1 AUTHOR

Your Name

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut