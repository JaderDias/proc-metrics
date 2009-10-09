#!perl

use strict;
use warnings;
use Test::More;

use AnyEvent;
use AnyEvent::Monitor::CPU qw( monitor_cpu );

#
# This test will steadly increase the CPU load until the watcher triggers,
# and then steadly decrease it until it triggers again
#

## the load generator
my $iters          = 50_000;
my $incr           = 25_000;
my $load_gen_timer = AnyEvent->timer(
  after    => .5,
  interval => .1,
  cb       => sub {
    note("  ... generating $iters count of load");
    my $i = $iters;
    my $a = 0;
    while ($i--) {
      $a += $i * $incr / $iters;
    }
  },
);

## the load modifier
my $direction      = 1;
my $load_mod_timer = AnyEvent->timer(
  after    => 1,
  interval => .2,
  cb       => sub {
    my $delta = $direction * $incr;
    $iters += $delta;
    $iters = 0 if $iters < 0;
    note("  !!! Delta is $delta, iters now $iters");
  },
);


## Test cases
my @cases = (
  ['default_values' => {high => .95, low => .80}],
  ['keep_it_busy'   => {high => .97, low => .95}],
  ['take_it_slow'   => {high => .30, low => .20}],
  [ 'half-empty' => {
      high         => .55,
      low          => .45,
      high_samples => 4,
      low_samples  => 4,
      interval     => .1,
      cycles       => 3
    }
  ],
);

for my $tc (@cases) {
  my ($name, $params) = @$tc;
  my $cv = AnyEvent->condvar;

  diag(
    "Starting test '$name': high => $params->{high}, low => $params->{low}");

  ## Make sure we stop it at some point
  my $secs = 10 * ($params->{cycles} || 1);
  my $time_limit = AnyEvent->timer(
    after => $secs,
    cb    => sub {
      $cv->send();
    }
  );

  my $mon = start_load_watcher($name, $cv, $params);
  my $stats = $mon->stats;
  ok(!$stats->{usage_count});
  ok(!$stats->{usage_sum});
  ok(!$stats->{usage_avg});

  my ($high, $low, $h_iters, $l_iters) = $cv->recv;
  $mon->stop;

  if (!$high) {
    fail("Aborted test after $secs seconds");
  }
  else {
    ok(
      $high >= $params->{high},
      "Good high value ($h_iters for $high) in '$name' (target $params->{high})"
    );
    ok(
      $low <= $params->{low},
      "Good low value ($l_iters for $low) in '$name' (target $params->{low})"
    );

    $stats = $mon->stats;
    ok($stats->{usage_count});
    ok($stats->{usage_sum});
    ok($stats->{usage_avg});
    my $margin = $params->{high} - $params->{low};
    if ($margin >= .10) {
      ok(
        $stats->{usage_avg} > ($params->{low} - $margin / 2),
        "Average usage ($stats->{usage_avg}) is above lower watermark"
      );
      ok(
        $stats->{usage_avg} < ($params->{high} + $margin / 2),
        "Average usage ($stats->{usage_avg}) is below high watermark"
      );
    }
  }
}

done_testing();

sub start_load_watcher {
  my ($test_name, $cv, $params) = @_;

  ## the load watcher
  my $expected_active = 1;
  my $warm_up_cycles = $params->{cycles} || $ENV{WARM_UP_CYCLES} || 1;
  my ($h_usage, $l_usage, $h_iters, $l_iters);

  return monitor_cpu %$params, cb => sub {
    my ($cpu, $active) = @_;

    is($active, $expected_active,
      "Got CPU Monitor trigger for expected state $expected_active ($test_name)"
    ) unless $warm_up_cycles;

    if ($active == 0) {
      $h_usage = $cpu->usage;
      $h_iters = $iters;
      note("Load over limit at ${h_iters}'s: $h_usage ($test_name)");

      $direction       = -1;
      $expected_active = 1;

      ok($cpu->is_high);
      ok(!$cpu->is_low);
    }
    else {
      $l_usage = $cpu->usage;
      $l_iters = $iters;
      note("Load under limit at ${l_iters}'s: $l_usage ($test_name)");

      $cv->send($h_usage, $l_usage, $h_iters, $l_iters)
        unless $warm_up_cycles;

      $direction       = 1;
      $expected_active = 0;
      if ($warm_up_cycles > 0) {
        $warm_up_cycles--;
        $cpu->reset_stats if $warm_up_cycles == 0;
      }

      ok(!$cpu->is_high);
      ok($cpu->is_low);
    }
    }
}
