#!/usr/bin/perl
use v5.40;
use experimental 'class';
use Test2::V0;
use Time::HiRes qw(time);
use File::Temp qw(tempfile);

# Load the module we're testing
use lib 'lib';
use ECS::XS::Binary qw(
    create_world
    serialize
    deserialize
);

# Component classes are defined in World.pm
# Define test-specific component classes
class Health {
    field $current :param :reader = 100;
    field $max :param :reader = 100;

    method set_current($value) { $current = $value; return $self; }

    method is_alive() { return $current > 0 }

    method damage($amount) {
        $current -= $amount;
        $current = 0 if $current < 0;
        return $self;
    }
}

class Renderable {
    field $model_id :param :reader;
    field $texture_id :param :reader;
    field $scale :param :reader = 1.0;
    
    method set_scale($value) { $scale = $value; return $self; }
}

# Helper to create a test database
sub create_test_world {
    # Use temporary file database for testing
    my ($fh, $filename) = tempfile(SUFFIX => '.duckdb', UNLINK => 1);
    close($fh);
    unlink($filename); # Remove the temp file so DuckDB can create it
    return create_world($filename, 'test_world');
}

# Test world creation
subtest 'World Creation' => sub {
    my $world = create_test_world();
    ok(ref($world) eq 'ECS::XS::Binary::World', 'World object created');
    isa_ok($world, 'ECS::XS::Binary::World');
};

# Test component registration
subtest 'Component Registration' => sub {
    my $world = create_test_world();

    ok($world->register_component('Position'), 'Register Position component');
    ok($world->register_component('Velocity'), 'Register Velocity component');
    ok($world->register_component('Health'), 'Register Health component');
    ok($world->register_component('Renderable'), 'Register Renderable component');

    ok($world->is_component_registered('Position'), 'Position is registered');
    ok($world->is_component_registered('Velocity'), 'Velocity is registered');
    ok($world->is_component_registered('Health'), 'Health is registered');
    ok($world->is_component_registered('Renderable'), 'Renderable is registered');
    ok($world->is_component_registered('NonExistent'), 'NonExistent can be registered');
};

# Test entity creation and management
subtest 'Entity Management' => sub {
    my $world = create_test_world();
    $world->register_component('Position');

    my $entity_id = $world->create_entity();
    ok($entity_id, 'Entity created');
    ok($world->entity_exists($entity_id), 'Entity exists');

    my $tagged_entity = $world->create_entity(['player', 'character']);
    ok($tagged_entity, 'Tagged entity created');
    ok($world->has_tag($tagged_entity, 'player'), 'Entity has player tag');
    ok($world->has_tag($tagged_entity, 'character'), 'Entity has character tag');

    ok($world->add_tag($entity_id, 'enemy'), 'Added enemy tag');
    ok($world->has_tag($entity_id, 'enemy'), 'Entity has enemy tag');

    ok($world->remove_tag($entity_id, 'enemy'), 'Removed enemy tag');
    ok(!$world->has_tag($entity_id, 'enemy'), 'Entity no longer has enemy tag');

    ok($world->destroy_entity($entity_id), 'Entity destroyed');
    ok(!$world->entity_exists($entity_id), 'Entity no longer exists');
};

# Test component operations
subtest 'Component Operations' => sub {
    my $world = create_test_world();
    $world->register_component('Position');
    $world->register_component('Velocity');

    my $entity_id = $world->create_entity();

    my $position = Position->new(x => 10, y => 20, z => 30);
    ok($world->add_component($entity_id, 'Position', $position), 'Added Position component');

    ok($world->has_component($entity_id, 'Position'), 'Entity has Position component');
    ok(!$world->has_component($entity_id, 'Velocity'), 'Entity does not have Velocity component');

    my $retrieved = $world->get_component($entity_id, 'Position');
    ok(ref($retrieved) eq 'Position', 'Retrieved correct component type');
    is($retrieved->x, 10, 'Position.x is correct');
    is($retrieved->y, 20, 'Position.y is correct');
    is($retrieved->z, 30, 'Position.z is correct');

    $retrieved->move(5, 5, 5);
    # Note: Since we're storing in DuckDB, we need to update the component
    $world->add_component($entity_id, 'Position', $retrieved);
    my $updated = $world->get_component($entity_id, 'Position');
    is($updated->x, 15, 'Position.x updated correctly');
    is($updated->y, 25, 'Position.y updated correctly');
    is($updated->z, 35, 'Position.z updated correctly');

    ok($world->remove_component($entity_id, 'Position'), 'Removed Position component');
    ok(!$world->has_component($entity_id, 'Position'), 'Entity no longer has Position component');
};

done_testing;