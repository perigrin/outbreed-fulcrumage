#!/usr/bin/perl
use v5.40;
use experimental qw(class);
use Test2::V0;
use ECS::XS::Binary qw(serialize deserialize);
use Benchmark qw(timethese cmpthese);

class Position {
    field $x :param :reader = 0;
    field $y :param :reader = 0;
    field $z :param :reader = 0;
}

# Create a pre-serialized object for testing
my $template_obj = Position->new(x => 42, y => 84, z => 126);
my $template_bin = serialize($template_obj);

subtest 'Constructor vs Deserialization Performance' => sub {
    my $result = timethese(-5, { # Run for 2 seconds
        'Constructor' => sub {
            my $p = Position->new(x => 42, y => 84, z => 126);
            # Use $p to prevent optimization
            die unless defined $p;
        },
        'Deserialize' => sub {
            my $p = deserialize($template_bin);
            # Use $p to prevent optimization
            die unless defined $p;
        },
    });

    note("Performance comparison:");
    cmpthese($result);
    # We don't know exact numbers, but deserialization should be faster
    # so this is mostly informational
    ok($result->{Deserialize}->iters > $result->{Constructor}->iters, 'Deserialization is faster');
};

done_testing;
