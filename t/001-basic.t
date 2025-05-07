#!/usr/bin/perl
use v5.40;
use experimental 'class';
use Test2::V0;
use ECS::XS::Binary qw(serialize deserialize is_class_object field_count);

# Define a test class
class Position {
    field $x :param :reader = 0;
    field $y :param :reader = 0;
    field $z :param :reader = 0;

    method move( $dx, $dy, $dz = 0 ) {
        $x += $dx;
        $y += $dy;
        $z += $dz;
        return $self;
    }

    method to_string() {
        return "Position(x=$x, y=$y, z=$z)";
    }
}

# Define a class with different field types
class TestScalars {
    field $int_val :param :reader    = 0;         # Integer
    field $float_val :param :reader  = 0.0;       # Float
    field $string_val :param :reader = "";        # String
    field $undef_val :param :reader //= undef;    # Undefined

    method set_int($val)    { $int_val    = $val; return $self; }
    method set_float($val)  { $float_val  = $val; return $self; }
    method set_string($val) { $string_val = $val; return $self; }
}

subtest 'Object identification' => sub {
    my $pos = Position->new( x => 10, y => 20, z => 30 );

    ok( is_class_object($pos), 'Position identified as a class object' );
    is( field_count($pos), 3, 'Position has 3 fields' );

    # Not a class object
    my $hashref = { x => 10, y => 20, z => 30 };
    ok( !is_class_object($hashref), 'HashRef is not a class object' );

    # Dies on non-object
    like(
        dies { field_count($hashref) },
        qr/Not a feature class object/,
        'field_count dies on non-class object'
    );
};

subtest 'Basic serialization and deserialization' => sub {
    my $pos = Position->new( x => 10, y => 20, z => 30 );

    # Serialize
    my $binary = serialize($pos);
    ok( $binary,             'Serialization produced binary data' );
    ok( length($binary) > 0, 'Binary data has positive length' );

    # Deserialize
    my $restored = deserialize($binary);
    ok( is_class_object($restored), 'Deserialized object is a class object' );
    is( field_count($restored), 3,
        'Deserialized object has correct field count' );

    # Check values
    is( $restored->x, 10, 'Deserialized x value is correct' );
    is( $restored->y, 20, 'Deserialized y value is correct' );
    is( $restored->z, 30, 'Deserialized z value is correct' );

    # Method calls work
    $restored->move( 5, 5, 5 );
    is( $restored->x, 15, 'Method calls work on deserialized object (x)' );
    is( $restored->y, 25, 'Method calls work on deserialized object (y)' );
    is( $restored->z, 35, 'Method calls work on deserialized object (z)' );

    # Original is untouched
    is( $pos->x, 10, 'Original object is untouched (x)' );
    is( $pos->y, 20, 'Original object is untouched (y)' );
    is( $pos->z, 30, 'Original object is untouched (z)' );
};

subtest 'Serialization with different scalar types' => sub {
    my $test = TestScalars->new(
        int_val    => 42,
        float_val  => 3.14159,
        string_val => 'Hello, World!',
        undef_val  =>
          undef    # technically we can't pass undef, but I set a default above
    );

    # Serialize and deserialize
    my $binary = serialize($test);
    ok( $binary, 'Serialization produced binary data' );

    my $restored = deserialize($binary);
    ok( is_class_object($restored), 'Deserialized object is a class object' );
    is( field_count($restored), 4,
        'Deserialized object has correct field count' );

    # Check values
    is( $restored->int_val,   42,      'Integer value restored correctly' );
    is( $restored->float_val, 3.14159, 'Float value restored correctly' );
    is(
        $restored->string_val,
        'Hello, World!',
        'String value restored correctly'
    );
    is( $restored->undef_val, undef, 'Undefined value restored correctly' );

    # Modify values
    $restored->set_int(100);
    $restored->set_float(2.71828);
    $restored->set_string('Modified string');

    # Check modified values
    is( $restored->int_val,   100,     'Modified integer value is correct' );
    is( $restored->float_val, 2.71828, 'Modified float value is correct' );
    is(
        $restored->string_val,
        'Modified string',
        'Modified string value is correct'
    );

    # Original is untouched
    is( $test->int_val,   42,      'Original integer value is untouched' );
    is( $test->float_val, 3.14159, 'Original float value is untouched' );
    is(
        $test->string_val,
        'Hello, World!',
        'Original string value is untouched'
    );
};

subtest 'Error handling' => sub {

    # Invalid binary data
    like(
        dies { deserialize("invalid") },
        qr/Invalid binary data/,
        'Deserialize dies on invalid data'
    );

    # Not a class object
    my $hashref = { x => 10, y => 20, z => 30 };
    like(
        dies { serialize($hashref) },
        qr/Not a feature class object/,
        'Serialize dies on non-class object'
    );
};

subtest 'Performance check' => sub {
    my $iterations = 100;    # Keep low for normal testing

    # Create test objects
    my @positions;
    for ( 1 .. $iterations ) {
        push @positions, Position->new( x => $_, y => $_ * 2, z => $_ * 3 );
    }

    # Serialize
    my @binaries;
    ok(
        lives {
            for my $pos (@positions) {
                push @binaries, serialize($pos);
            }
        },
        "Serialized $iterations objects without errors"
    );

    # Deserialize
    ok(
        lives {
            for my $bin (@binaries) {
                state $i = 1;
                my $obj = deserialize($bin);

                # Validate one field to ensure proper deserialization
                is( $obj->x, $i++, 'Deserialized object has correct x value' );
            }
        },
        "Deserialized $iterations objects without errors"
    );
};

# Add more tests as needed

done_testing;
