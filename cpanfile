requires 'perl' => '5.40.0';

# Core dependencies
requires 'XSLoader';
requires 'Exporter';
requires 'Carp';
requires 'List::Util';

# Build dependencies
requires 'Alien::DuckDB';
requires 'Alien::Base';
requires 'Alien::Build';
requires 'ExtUtils::MakeMaker';
requires 'ExtUtils::CBuilder';

# Test dependencies
on 'test' => sub {
    requires 'Test2::V0';
    requires 'Benchmark';
    requires 'Time::HiRes';
};

# Recommended but not required
recommends 'Module::Pluggable';
recommends 'Path::Tiny';