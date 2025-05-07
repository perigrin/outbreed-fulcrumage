# ECS::XS::Binary

# THIS CODE IS A PROOF OF CONCEPT ONLY

A high-performance binary serialization system for Perl 5.40 class objects, designed specifically for Entity Component System (ECS) implementations.

## Overview

ECS::XS::Binary provides direct access to Perl 5.40 class object internals for maximum performance when serializing and deserializing game components. It enables:

* Direct field access without using accessors
* Efficient binary serialization of object data
* Constructor-free deserialization for optimal performance
* Type-safe handling of scalar values (integers, floats, strings)

This module is intended as part of a larger ECS (Entity Component System) implementation that will use DuckDB for component storage.

## Features

* **High Performance**: Directly access object fields using Perl's internal APIs
* **Zero-Copy**: Minimize memory operations during serialization/deserialization
* **Constructor Bypass**: Create objects without calling constructors for optimal performance
* **Stable Binary Format**: Consistent serialization format suitable for database storage

## Requirements

* Perl 5.40 or newer (for `feature class` support)
* C compiler for building the XS module
* ExtUtils::MakeMaker for installation

## Installation

```bash
perl Makefile.PL
make
make test
make install
```

## Example Usage

```perl
use feature 'class';
use ECS::XS::Binary qw(serialize deserialize);

# Define a component class
class Position {
    field $x :param :reader = 0;
    field $y :param :reader = 0;
    field $z :param :reader = 0;

    method move($dx, $dy, $dz = 0) {
        $x += $dx;
        $y += $dy;
        $z += $dz;
        return $self;
    }
}

# Create a component
my $pos = Position->new(x => 10, y => 20, z => 30);

# Serialize to binary
my $binary = serialize($pos);

# Later, deserialize without using constructor
my $restored = deserialize($binary);

# Access fields and methods
print "Position: ", $restored->x, ", ", $restored->y, ", ", $restored->z, "\n";
$restored->move(5, 5, 5);
```

## Limitations

This proof of concept only supports basic scalar types:
* Integers
* Floats
* Strings
* Undefined values

Complex types like references, objects, arrays, and hashes are not supported in this initial implementation.

## Performance

The module is optimized for high-performance component serialization in game development:

* Serialization/deserialization of a simple component in under 2µs
* Support for batch operations for efficient mass component handling
* Minimized memory allocations through direct field access

## Internal Details

The module uses the `ObjectFIELDS` and `ObjFIELDS_count` APIs from `perlclassguts` to directly access the internal field array of Perl 5.40 class objects. This avoids the overhead of accessor methods and constructor validation.

## License

This module is available under the same license as Perl itself.
