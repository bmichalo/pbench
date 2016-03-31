#!/usr/bin/perl
# -*- mode: perl; indent-tabs-mode: t; perl-indent-level: 8 -*-

# Author: Andrew Theurer

package BenchPostprocess;

use strict;
use warnings;
use File::Basename;
use Cwd 'abs_path';
use Exporter qw(import);
use List::Util qw(max);
use Data::Dumper;

our @EXPORT_OK = qw(get_length get_uid get_mean remove_timestamp get_timestamps write_influxdb_line_protocol get_cpubusy_series calc_ratio_series calc_sum_series div_series);

my $script = "BenchPostprocess";

sub get_length {
	my $text = shift;
	return scalar split("", $text)
}

sub get_uid {
	my $uid = shift;
	my $uid_sources_ref = shift;
	my $mapped_uid = "";
	while ( $uid && $uid =~ s/^([^%]*)%([^%]+)%// ) {
		my $before_uid_marker = $1;
		my $uid_marker = $2;
		if ( $$uid_sources_ref{$uid_marker} ) {
			$mapped_uid = $mapped_uid . $before_uid_marker . $$uid_sources_ref{$uid_marker};
		} else {
			$mapped_uid = $mapped_uid . $before_uid_marker . "%" . $uid_marker . "%";
		}
	}
	# for any text left over after all markers have been found
	if ($uid) {
		$mapped_uid = $mapped_uid . $uid;
	}
	return $mapped_uid;
}

# in a array of { 'date' => x, 'value' => y } hashes, return the average of all y's
sub get_mean {
	my $array_ref = shift;
	my $total = 0;
	my $i;
	for ($i=0; $i < scalar @{ $array_ref }; $i++) {
		$total += $$array_ref[$i]{'value'};
	}
	if ( $i > 0 ) {
		return $total / $i;
	}
}

# in a array of { 'date' => x, 'value' => y } hashes, find the hash which $timestamp matchs x and then return y
sub get_value {
	my $array_ref = shift;
	my $timestamp = shift;
	my $timestamp_value_ref;
	foreach $timestamp_value_ref (@{ $array_ref }) {
		if ( $$timestamp_value_ref{'date'} == $timestamp ) {
			return $$timestamp_value_ref{'value'};
		}
	}
}

# in a array of { 'date' => x, 'value' => y } hashes, either find the hash which $timestamp matchs x and update y, or
# if there is no hash which $timestamp matches x, add a new hash
sub put_value {
	my $array_ref = shift;
	my $timestamp = shift;
	my $value = shift;
	my $timestamp_value_ref;
	foreach $timestamp_value_ref (@{ $array_ref }) {
		if ( $$timestamp_value_ref{'date'} == $timestamp ) {
			$$timestamp_value_ref{'value'} = $value;
			return;
		}
	}
	my %timestamp_value = ('date' => $timestamp, 'value' => $value);
	push(@{ $array_ref }, \%timestamp_value);
}

# in a array of { 'date' => x, 'value' => y } hashes, find the hash which $timestamp matchs x and then remove that hash from the array
sub remove_timestamp {
	my $array_ref = shift;
	my $timestamp = shift;
	my $i;
	for ($i=0; $i < scalar @{ $array_ref }; $i++) {
		if ( $$array_ref[$i]{'date'} == $timestamp ) {
			splice(@$array_ref, $i, 1);
		}
	}
}

# in a array of { 'date' => x, 'value' => y } hashes, return an array of only timestamps
sub get_timestamps {
	my @timestamps;
	my $array_ref = shift;
	my $timestamp_value_ref;
	foreach $timestamp_value_ref (@{ $array_ref }) {
		push(@timestamps, $$timestamp_value_ref{'date'});
	}
	return @timestamps = sort @timestamps;
}

sub write_influxdb_line_protocol {
	my $params = shift;
	# the name of the measurement, like resource_cpu_busy or benchmark_throughput_Gb_sec
	my $measurement = $params;
	# the directory to write this file
	$params = shift;
	my $dir = $params;
	$params = shift;
	# These hash, which will be populated with cpubusy data, needs to be used by reference in order to preserve the changes made
	my $data_ref = $params;
	my $file_name = $dir . "/" . $measurement . ".txt";
	if (open(INFLUXDB, ">>$file_name")) {
		my $timestamp;
		foreach $timestamp (keys $$data_ref{'timeseries'} ) {
			my $this_key;
			my $id_string = $measurement;
			foreach $this_key (keys %{ $data_ref}) {
				if ( $this_key ne "timeseries" && $this_key ne "uid" && $this_key ne "value" && $this_key ne "description" && $$data_ref{$this_key}) {
					my $value = $$data_ref{$this_key};
					$value =~ s/\s/\\ /g;
					$id_string = $id_string . "," . $this_key . "=" . $value;
				}
			}
		my $timestamp_ns = $timestamp * 1000000;
		my $value = $$data_ref{'timeseries'}{$timestamp};
		printf INFLUXDB "%s value=%f %d\n", $id_string, $value, $timestamp_ns;
		}
		close(INFLUXDB);
	}
}
sub get_cpubusy_series {
	# This will get a hash (series) with keys = timestamps and values = CPU busy
	# CPU Busy is in CPU units: 1.0 = amoutn of cpu used is equal to 1 logical CPU
	# 1.0 does not necessarily mean exactly 1 of the cpus was used at 100%.
	# This value is a sum of all cpus used, which may be several cpus used, each a fraction of their maximum
	
	my $first_timestamp;
	my $last_timestamp;
	my $params = shift;
	# This is the directory which contains the tool data: see ./sar/csv/cpu_all_cpu_busy.csv
	my $tool_dir = $params;
	$params = shift;
	# These hash, which will be populated with cpubusy data, needs to be used by reference in order to preserve the changes made
	my $cpu_busy_ref = $params;
	$params = shift;
	if ($params) {
		# We don't want data before this timestamp
		$first_timestamp = $params;
		$params = shift;
		if ($params) {
			# We don't want data after this timestamp
			$last_timestamp = $params;
		}
	}
	my $file = "$tool_dir/sar/csv/cpu_all_cpu_busy.csv";
	if (open(SAR_ALLCPU_CSV, "$file")) {
		my $timestamp_ms = 0;
		my @values;
		my $cpu_busy;
		my $cnt = 0;
		while (my $line = <SAR_ALLCPU_CSV>) {
			chomp $line;
			## The csv file has this format:
			# timestamp_ms,cpu_00,cpu_01,cpu_02,cpu_03
			# 1429213202000,10.92,6.9,5,6.66
			# 1429213205000,88.29,0.33,0.67,0
			if ( $line =~ /^timestamp/ ) {
				next;
			}
			@values = split(/,/,$line);
			$timestamp_ms = shift(@values);
			if ((!$last_timestamp || $timestamp_ms <= $last_timestamp ) && ( !$first_timestamp || $timestamp_ms >= $first_timestamp )) {
				my $value;
				$cpu_busy = 0;
				foreach $value (@values) {
					$cpu_busy += $value;
				}
				push(@$cpu_busy_ref, { 'date' => int $timestamp_ms, 'value' => $cpu_busy/100});
				$cnt++;
			}
		}
		close(SAR_ALLCPU_CSV);
		#print "count: $cnt\n";
		#print Dumper $cpu_busy_ref;
		if ($cnt > 0) {
			return 0;
		} else {
			printf "$script: no sar timestamps in $file fall within given range: $first_timestamp - $last_timestamp\n";
			return 1;
		}
	} else {
		printf "$script: could not find file $file\n";
		return 1;
	}
}

sub calc_ratio_series {
	# This generates a new hash (using the hash referfence, $ratio) from two existing hashes
	# (hash references $numerator and $denominator).  This is essentially:
	# %ratio_hash = %numerator_hash / %denominator_hash
	# Each hash is a time series, with a value for each timestamp key
	# The timestamp keys do not need to match exactly.  Values are interrepted linearly
	

	# These hashes need to be used by reference in order to preserve the changes made
	my $params = shift;
	my $numerator = $params;
	$params = shift;
	my $denominator = $params;
	$params = shift;
	my $ratio = $params;

	# This would be fairly trivial if the two hashes we are dealing with had the same keys (timestamps), but there
	# is no guarantee of that.  What we do is key off the timestamps of the second hash and interpolate a value from the first hash.
	my $count = 0;
	my $prev_numerator_timestamp_ms = 0;
	my @numerator_timestamps = (sort {$a<=>$b} keys %{$numerator});
	my @denominator_timestamps = (sort {$a<=>$b} keys %{$denominator});
	while ($denominator_timestamps[0] < $numerator_timestamps[0]) {
		shift(@denominator_timestamps) || last;
	}
	# remove any "trailing" timestamps: timestamps from denominator that come after the last timestamp in numerator
	while ($denominator_timestamps[-1] >= $numerator_timestamps[-1]) {
		my $unneeded_denominator_timestamp = pop(@denominator_timestamps);
		## delete $$denominator{$unneeded_denominator_timestamp} || last;
		remove_timestamp(\@{ $denominator }, $unneeded_denominator_timestamp);
	}
	my $numerator_timestamp_ms = shift(@numerator_timestamps);
	my $denominator_timestamp_ms;
	for $denominator_timestamp_ms (@denominator_timestamps) {
		# don't attempt to calculate a ratio if we have divide by zero
		if ($$denominator{$denominator_timestamp_ms} == 0) {
			next;
		}
		# find a pair of consecutive numerator timestamps which are before & after the denominator timestamp
		# these timestamps are ordered, so once the first numerator timestamp is found that is >= denominator timestamp,
		# the previous numerator timestamp should be < denominator timestamp.
		# print "looking for suitable pair of timestamps\n";
		while ($numerator_timestamp_ms <= $denominator_timestamp_ms) {
			$prev_numerator_timestamp_ms = $numerator_timestamp_ms;
			$numerator_timestamp_ms = shift(@numerator_timestamps) || last;
		}
		my $numerator_value_base = $$numerator{$prev_numerator_timestamp_ms};
		my $denominator_prev_numerator_timestamp_diff_ms = ($denominator_timestamp_ms - $prev_numerator_timestamp_ms);
		my $value_adj = 0;
		if ($denominator_prev_numerator_timestamp_diff_ms != 0) {
			my $numerator_prev_numerator_timestamp_diff_ms = ($numerator_timestamp_ms - $prev_numerator_timestamp_ms);
			my $value_diff = $$numerator{$numerator_timestamp_ms} - $numerator_value_base;
			$value_adj = $value_diff * $denominator_prev_numerator_timestamp_diff_ms/$numerator_prev_numerator_timestamp_diff_ms;
		}
		my $numerator_value_interp = $numerator_value_base + $value_adj;
		$$ratio{$denominator_timestamp_ms} = $numerator_value_interp/$$denominator{$denominator_timestamp_ms};
		# print "$$ratio{$denominator_timestamp_ms} :  $numerator_value_interp / $$denominator{$denominator_timestamp_ms}\n";
		$count++;
	}
}

sub calc_sum_series {
	# This takes the sum of two hashes (hash references $add_from_ref and $add_to_ref)
	# and stores the values in $add_to_hash.  This is essentially:
	# %add_to_hash = %add_from_hash + %add_to_hash
	# Each hash is a time series, with a value for each timestamp key
	# The timestamp keys do not need to match exactly.  Values are interrepted linearly
	
	# These hashes need to be used by reference in order to preserve the changes made
	my $params = shift;
	my $add_from_ref = $params;
	$params = shift;
	my $add_to_ref = $params;
	# This would be fairly trivial if the two hashes we are dealing with had the same keys (timestamps), but there
	# is no guarantee of that.  What we have to do is key off the timestamps of the second hash (where we store the sum)
	# and interpolate a value from the first hash.
	my $count = 0;
	my $prev_stat1_timestamp_ms = 0;
	my @stat1_timestamps = get_timestamps(\@{$add_from_ref});
	# print "stat1_timestamps: @stat1_timestamps\n";
	my @stat2_timestamps = get_timestamps(\@{$add_to_ref});
	# print "stat2_timestamps: @stat2_timestamps\n";
	# remove any "leading" timestamps: timestamps from stat2 that come before first timestamp in stat1
	# print "removing leading samples\n";
	while ($stat2_timestamps[0] < $stat1_timestamps[0]) {
		# print "stat2:$stat2_timestamps[0] < stat1:$stat1_timestamps[0]\n";
		my $unneeded_stat2_timestamp = shift(@stat2_timestamps);
		##delete $$add_to_ref{$unneeded_stat2_timestamp} || last;
		remove_timestamp (\@{ $add_to_ref}, $unneeded_stat2_timestamp) || last;
	}
	# remove any "trailing" timestamps: timestamps from stat2 that come after the last timestamp in stat1
	# print "removing trailing samples\n";
	while ($stat2_timestamps[-1] >= $stat1_timestamps[-1]) {
		my $unneeded_stat2_timestamp = pop(@stat2_timestamps);
		#printf "deleting this timestamp from stat2: $unneeded_stat2_timestamp value: $$add_to_ref{$unneeded_stat2_timestamp}\n";
		##delete $$add_to_ref{$unneeded_stat2_timestamp} || last;
		remove_timestamp(\@{ $add_to_ref}, $unneeded_stat2_timestamp) || last;
	}
	my $stat1_timestamp_ms = shift(@stat1_timestamps);
	my $stat2_timestamp_ms;
	for $stat2_timestamp_ms (@stat2_timestamps) {
		# find a pair of consecutive stat1 timestamps which are before & after the stat2 timestamp
		# these timestamps are ordered, so once the first stat1 timestamp is found that is >= stat2 timestamp,
		# the previous stat1 timestamp should be < stat2 timestamp.
		# print "looking for suitable pair of timestamps\n";
		while ($stat1_timestamp_ms <= $stat2_timestamp_ms) {
			# print "looking for a stat1_timestamp_ms:$stat1_timestamp_ms that is > $stat2_timestamp_ms\n";
			$prev_stat1_timestamp_ms = $stat1_timestamp_ms;
			$stat1_timestamp_ms = shift(@stat1_timestamps) || return;
		}
		# print "[$prev_stat1_timestamp_ms] - [$stat1_timestamp_ms]\n";
		##my $stat1_value_base = $$add_from_ref{$prev_stat1_timestamp_ms};
		my $stat1_value_base = get_value($add_from_ref, $prev_stat1_timestamp_ms);
		# if the stat2 timestamp is different from the first $stat1 timestamp, then adjust the value based on the difference of time and values
		my $stat2_prev_stat1_timestamp_diff_ms = ($stat2_timestamp_ms - $prev_stat1_timestamp_ms);
		my $value_adj = 0;
		if ($stat2_prev_stat1_timestamp_diff_ms != 0) {
			my $stat1_prev_stat1_timestamp_diff_ms = ($stat1_timestamp_ms - $prev_stat1_timestamp_ms);
			##my $value_diff = $$add_from_ref{$stat1_timestamp_ms} - $stat1_value_base;
			my $value_diff = get_value($add_from_ref, $stat1_timestamp_ms) - $stat1_value_base;
			$value_adj = $value_diff * $stat2_prev_stat1_timestamp_diff_ms/$stat1_prev_stat1_timestamp_diff_ms;
		}
		my $stat1_value_interp = $stat1_value_base + $value_adj;
		# if ($count == 0) {print "add_from: $stat1_value_interp  add_to(current): $$add_to_ref{$stat2_timestamp_ms}  ";}
		##$$add_to_ref{$stat2_timestamp_ms} = $$add_to_ref{$stat2_timestamp_ms} + $stat1_value_interp;
		put_value($add_to_ref, $stat2_timestamp_ms,  get_value($add_to_ref,$stat2_timestamp_ms) + $stat1_value_interp);
		# printf " timestamp: $stat2_timestamp_ms  value: $$add_to_ref{$stat2_timestamp_ms}\n";
		# if ($count  == 0) { print "add_to(new): $$add_to_ref{$stat2_timestamp_ms} ]\n";}
		$count++;
	}
}
sub div_series {
	my $params = shift;
	my $div_from_ref = $params;
	$params = shift;
	my $divisor = $params;
	if ( $divisor > 0 ) {
	my $i;
		for ($i=0; $i < scalar @{$div_from_ref}; $i++) {
			$$div_from_ref[$i]{'value'} /= $divisor;
		}
	}
}

1;
