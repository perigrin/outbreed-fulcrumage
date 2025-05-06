use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'ECS::XS::Binary',
    VERSION_FROM      => 'lib/ECS/XS/Binary.pm',
    PREREQ_PM         => {
        'Test2::V0'   => 0,
        'Benchmark'   => 0,
        'XSLoader'    => 0,
        'DBI'         => 0,
        'DBD::duckdb' => 0,
    },
    ABSTRACT_FROM     => 'lib/ECS/XS/Binary.pm',
    AUTHOR            => 'Your Name <your.email@example.com>',
    LICENSE           => 'perl',
    LIBS              => [''], # Add any required libraries here
    DEFINE            => '', # Add any -D flags here
    INC               => '-I.', # Add -I and -L flags here
    OBJECT            => '$(O_FILES)', # Object files
    OPTIMIZE          => '-O3', # Optimize for performance
    XS                => { 'Binary.xs' => 'Binary.c' }, # Input XS => output C
    C                 => ['Binary.c'], # C files to compile
    # Tell MakeMaker the destination for Binary.so/.bundle
    PMLIBDIRS         => ['lib'],
    INSTALLARCHLIB    => './lib',
    INSTALLSITEARCH   => './lib',
    DIR               => [],
);
