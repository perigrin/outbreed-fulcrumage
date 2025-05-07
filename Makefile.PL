use ExtUtils::MakeMaker;
use Config;
use File::Spec;

# Detect DuckDB
my ($duckdb_lib, $duckdb_inc) = find_duckdb();

WriteMakefile(
    NAME              => 'ECS::XS::Binary',
    VERSION_FROM      => 'lib/ECS/XS/Binary.pm',
    PREREQ_PM         => {
        'Test2::V0'   => 0,
        'Benchmark'   => 0,
        'XSLoader'    => 0,
    },
    ABSTRACT_FROM     => 'lib/ECS/XS/Binary.pm',
    AUTHOR            => 'Your Name <your.email@example.com>',
    LICENSE           => 'perl',
    LIBS              => ["-L$duckdb_lib -lduckdb"], # DuckDB library 
    DEFINE            => '-DHAVE_DUCKDB', # Define that we have DuckDB
    INC               => "-I. -I$duckdb_inc", # Include directories
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

# Function to find DuckDB library and headers
sub find_duckdb {
    my $lib_path = '';
    my $inc_path = '';
    
    # Common locations to check
    my @lib_paths = (
        '/usr/local/lib',
        '/usr/lib',
        '/opt/homebrew/lib',
        '/opt/local/lib',
        '/usr/local/opt/duckdb/lib',
        '/opt/homebrew/Cellar/duckdb/*/lib',
    );
    
    my @inc_paths = (
        '/usr/local/include',
        '/usr/include',
        '/opt/homebrew/include',
        '/opt/local/include',
        '/usr/local/opt/duckdb/include',
        '/opt/homebrew/Cellar/duckdb/*/include',
    );
    
    # Try to find library
    for my $path (@lib_paths) {
        # Check for glob patterns
        if ($path =~ /\*/) {
            my @expanded = glob($path);
            for my $exp_path (@expanded) {
                if (-e File::Spec->catfile($exp_path, "libduckdb.$Config{so}") ||
                    -e File::Spec->catfile($exp_path, "libduckdb.a")) {
                    $lib_path = $exp_path;
                    last;
                }
            }
        } else {
            if (-e File::Spec->catfile($path, "libduckdb.$Config{so}") ||
                -e File::Spec->catfile($path, "libduckdb.a")) {
                $lib_path = $path;
                last;
            }
        }
    }
    
    # Try to find header
    for my $path (@inc_paths) {
        # Check for glob patterns
        if ($path =~ /\*/) {
            my @expanded = glob($path);
            for my $exp_path (@expanded) {
                if (-e File::Spec->catfile($exp_path, "duckdb.h")) {
                    $inc_path = $exp_path;
                    last;
                }
            }
        } else {
            if (-e File::Spec->catfile($path, "duckdb.h")) {
                $inc_path = $path;
                last;
            }
        }
    }
    
    # Fallback to homebrew if found
    if (!$lib_path || !$inc_path) {
        if (-e '/opt/homebrew/include/duckdb.h') {
            $inc_path = '/opt/homebrew/include';
            $lib_path = '/opt/homebrew/lib';
        }
    }
    
    unless ($lib_path && $inc_path) {
        warn "WARNING: DuckDB library and/or headers not found. ";
        warn "DuckDB support will be disabled.\n";
        # Default empty paths so compilation can continue without DuckDB
        $lib_path = '';
        $inc_path = '';
    }
    
    return ($lib_path, $inc_path);
}
