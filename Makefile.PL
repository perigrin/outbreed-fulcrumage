use ExtUtils::MakeMaker;
use Alien::Base::Wrapper qw( WriteMakefile );

WriteMakefile(
    NAME         => 'ECS::XS::Binary',
    VERSION_FROM => 'lib/ECS/XS/Binary.pm',
    ABSTRACT_FROM => 'lib/ECS/XS/Binary.pm',
    AUTHOR        => 'Chris Prather <chris@prather.org>',
    LICENSE       => 'perl',
    
    PREREQ_PM    => {
        'Test2::V0'     => 0,
        'Benchmark'     => 0,
        'XSLoader'      => 0,
    },
    
    alien_requires => {
        'Alien::DuckDB' => 0,
    },
);