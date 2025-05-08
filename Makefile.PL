use strict;
use warnings;
use ExtUtils::MakeMaker;
use Alien::DuckDB;

# Get DuckDB flags
my $cflags = Alien::DuckDB->cflags;
my $libs = Alien::DuckDB->libs;

WriteMakefile(
    NAME          => 'ECS::XS::Binary',
    VERSION_FROM  => 'lib/ECS/XS/Binary.pm',
    AUTHOR        => 'Chris Prather <chris@prather.org>',
    LICENSE       => 'perl',
    
    # Use DuckDB flags
    INC           => $cflags,
    LIBS          => $libs,
    
    CONFIGURE_REQUIRES => {
        'Alien::DuckDB' => '0',
        'ExtUtils::MakeMaker' => '0',
    },
    
    BUILD_REQUIRES => {
        'Alien::DuckDB' => '0',
        'Test2::V0' => '0',
    },
    
    PREREQ_PM => {
        'Test2::V0' => '0',
        'Benchmark' => '0',
        'XSLoader'  => '0',
        'Alien::DuckDB' => '0',
    },
    
    TEST_REQUIRES => {
        'Test2::V0' => '0',
    },
    
    MIN_PERL_VERSION => '5.40.0',
);